use std::ffi::{CString, c_int, c_void};
use std::fmt;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::os::fd::AsRawFd;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::Path;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

pub use blake3::Hash;

use crate::store::Store;

/// The most swaps one save makes. Past the first, each puts back a version
/// another writer wrote during the save's own swaps.
const SWAPS: usize = 16;

/// The most times, a millisecond apart, a save looks for another process to
/// stop writing what its last swap took off.
const WAITS: usize = 200;

pub fn hash(bytes: &[u8]) -> Hash {
    blake3::hash(bytes)
}

#[derive(Debug)]
pub enum SaveError {
    /// The file no longer holds the bytes the save was based on, or is gone.
    Conflict,
    /// Another writer changed the file while the save swapped it in. The file
    /// holds their version, which this hashes, and the save wrote nothing.
    Raced(Hash),
    Io(io::Error),
}

impl From<io::Error> for SaveError {
    fn from(error: io::Error) -> Self {
        SaveError::Io(error)
    }
}

impl fmt::Display for SaveError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            SaveError::Conflict => f.write_str("the file changed after it was read"),
            SaveError::Raced(_) => f.write_str("another app wrote the file while it was saved"),
            SaveError::Io(error) => error.fmt(f),
        }
    }
}

/// A file that is gone was removed or renamed by someone else.
fn gone(error: io::Error) -> SaveError {
    match error.kind() {
        io::ErrorKind::NotFound => SaveError::Conflict,
        _ => SaveError::Io(error),
    }
}

/// Writes `bytes` to `path` if the file still holds the bytes `base` hashes,
/// and returns their hash. Bytes that hash to `base` write nothing. A symlink
/// keeps pointing where it did, at the file that now holds `bytes`.
///
/// A hidden sibling that takes the file's mode, owner, group, flags and
/// extended attributes swaps places with it. When what the swap takes off
/// the path is not `base`, another writer got in: their version goes back
/// and the save is refused. Every version a swap takes off the path, other
/// than `base` and `bytes`, goes into `store`.
///
/// The file is written in place instead, through the descriptor that was
/// hashed, when it has other hard links or an access control list, or a new
/// file beside it can't be made, can't take its owner and group, or can't
/// swap with it; a failed write in place puts the original bytes back.
pub fn save(path: &Path, base: &Hash, bytes: &[u8], store: &Store) -> Result<Hash, SaveError> {
    // Hashed first, so the check stays next to the write.
    let new = hash(bytes);
    let path = &fs::canonicalize(path).map_err(gone)?;
    let mut file = OpenOptions::new()
        .read(true)
        .write(true)
        .open(path)
        .map_err(gone)?;
    unchanged(&mut file, base)?;
    if new == *base {
        return Ok(new);
    }
    if file.metadata()?.nlink() > 1 || has_acl(&file)? || !replace(path, &file, base, bytes, store)?
    {
        // Checked again next to the write: a sibling that could not swap took time.
        step();
        let original = unchanged(&mut file, base)?;
        write_in_place(path, &mut file, &original, bytes)?;
    }
    Ok(new)
}

/// The bytes of `file` if they are the ones `base` hashes.
fn unchanged(file: &mut File, base: &Hash) -> Result<Vec<u8>, SaveError> {
    let mut bytes = Vec::new();
    file.seek(SeekFrom::Start(0))?;
    file.read_to_end(&mut bytes)?;
    if hash(&bytes) == *base {
        Ok(bytes)
    } else {
        Err(SaveError::Conflict)
    }
}

// libc has no ACL calls.
unsafe extern "C" {
    fn acl_get_fd_np(fd: c_int, kind: c_int) -> *mut c_void;
    fn acl_free(acl: *mut c_void) -> c_int;
}

const ACL_TYPE_EXTENDED: c_int = 0x100;

/// Whether `file` has an access control list. A sibling can't take one on
/// safely: a list that denies delete would also keep the sibling from being
/// removed when the save fails.
fn has_acl(file: &File) -> io::Result<bool> {
    // SAFETY: the descriptor is open, and a list it returns is freed once.
    unsafe {
        let acl = acl_get_fd_np(file.as_raw_fd(), ACL_TYPE_EXTENDED);
        if !acl.is_null() {
            acl_free(acl);
            return Ok(true);
        }
    }
    let error = io::Error::last_os_error();
    match error.raw_os_error() {
        Some(libc::ENOENT) => Ok(false),
        _ => Err(error),
    }
}

/// Writes `bytes` over `file`, which holds `original`, and puts `original`
/// back if the write fails or `path` no longer names the file.
fn write_in_place(
    path: &Path,
    file: &mut File,
    original: &[u8],
    bytes: &[u8],
) -> Result<(), SaveError> {
    let written = overwrite(file, bytes)
        .map_err(SaveError::Io)
        .and_then(|()| {
            // A replace that lands after the check takes the path from this file.
            let (named, written) = (fs::metadata(path).map_err(gone)?, file.metadata()?);
            if (named.dev(), named.ino()) == (written.dev(), written.ino()) {
                Ok(())
            } else {
                Err(SaveError::Conflict)
            }
        });
    if let Err(error) = &written
        && let Err(restore) = overwrite(file, original)
    {
        return Err(SaveError::Io(io::Error::new(
            restore.kind(),
            format!("{error}, and the original could not be put back: {restore}"),
        )));
    }
    written
}

fn overwrite(file: &mut File, bytes: &[u8]) -> io::Result<()> {
    file.seek(SeekFrom::Start(0))?;
    file.write_all(bytes)?;
    file.set_len(bytes.len() as u64)?;
    file.sync_all()
}

/// Writes `bytes` to a hidden sibling of `path` with `original`'s metadata
/// and swaps it in. Returns false, having written nothing, when the sibling
/// can't be made, can't take `original`'s owner and group, or can't swap.
fn replace(
    path: &Path,
    original: &File,
    base: &Hash,
    bytes: &[u8],
    store: &Store,
) -> Result<bool, SaveError> {
    let stamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    // Not derived from the file's name, which may already be at the 255-byte limit.
    let temp = path.with_file_name(format!(".dewline.{}.{stamp:x}.tmp", std::process::id()));
    let mut file = match OpenOptions::new().write(true).create_new(true).open(&temp) {
        // A folder that can't take a new file.
        Err(error) if error.kind() == io::ErrorKind::PermissionDenied => return Ok(false),
        file => file?,
    };
    let result = (|| {
        // Copying the metadata copies the old modification date too, so it
        // comes before the bytes, whose write sets the date to now.
        // SAFETY: both descriptors stay open for the call; copyfile accepts a null state.
        let copied = unsafe {
            libc::fcopyfile(
                original.as_raw_fd(),
                file.as_raw_fd(),
                std::ptr::null_mut(),
                libc::COPYFILE_STAT | libc::COPYFILE_XATTR,
            )
        };
        if copied != 0 {
            return Err(io::Error::last_os_error().into());
        }
        // fcopyfile succeeds even when it may not set the owner or group.
        let (copy, from) = (file.metadata()?, original.metadata()?);
        if (copy.uid(), copy.gid()) != (from.uid(), from.gid()) {
            return Ok(false);
        }
        file.write_all(bytes)?;
        file.sync_all()?;
        match swap(&temp, path) {
            Ok(()) => Ok(true),
            Err(error) if matches!(error.raw_os_error(), Some(libc::ENOTSUP | libc::EXDEV)) => {
                Ok(false)
            }
            Err(error) => Err(gone(error)),
        }
    })();
    if !matches!(result, Ok(true)) {
        if let Err(cleanup) = fs::remove_file(&temp) {
            let after = result
                .err()
                .map(|error| format!("{error}; "))
                .unwrap_or_default();
            return Err(SaveError::Io(io::Error::new(
                cleanup.kind(),
                format!("{after}{} could not be removed: {cleanup}", temp.display()),
            )));
        }
        return result;
    }
    settle(path, &temp, base, &hash(bytes), store).map(|()| true)
}

/// Finishes a save after the swap that put its bytes, which `new` hashes, at
/// `path` and moved the file there to `temp`. Each swap should take off what
/// the path held when the swap before it ran, `base` at first. When it takes
/// off something else, or another process still has it open for writing,
/// another writer got in, and the next swap puts their version back. Every
/// version a swap took off, other than `base` and the save's own, goes into
/// `store` before `temp` is removed.
fn settle(
    path: &Path,
    temp: &Path,
    base: &Hash,
    new: &Hash,
    store: &Store,
) -> Result<(), SaveError> {
    let (mut expected, mut put) = (*base, *new);
    let mut theirs: Vec<(Hash, Vec<u8>)> = Vec::new();
    let mut keep = |got: Hash, out: Vec<u8>| {
        if got != *base && got != *new && theirs.iter().all(|(kept, _)| *kept != got) {
            theirs.push((got, out));
        }
    };
    let (mut swaps, mut deleted, mut waits) = (1, false, 0);
    let busy = loop {
        let out = read(temp)?;
        let got = hash(&out);
        keep(got, out);
        let swappable = !deleted && swaps < SWAPS;
        if got == expected || !swappable {
            // A writer that opened the file before a swap writes into it
            // wherever it is. Once no process has it open for writing, what
            // it holds is final, and is read once more.
            if !held(temp)? {
                let last = read(temp)?;
                if hash(&last) == got {
                    break false;
                }
                keep(hash(&last), last);
                continue;
            }
            if !swappable {
                waits += 1;
                if waits == WAITS {
                    break true;
                }
                std::thread::sleep(Duration::from_millis(1));
                continue;
            }
        }
        match swap(temp, path) {
            Ok(()) => (expected, put, swaps) = (put, got, swaps + 1),
            Err(error) if error.kind() == io::ErrorKind::NotFound => deleted = true,
            Err(error) => return Err(error.into()),
        }
    };
    let now = SystemTime::now();
    for (_, bytes) in &theirs {
        store.put(path, bytes, "Unknown app", now)?;
    }
    if busy {
        return Err(SaveError::Io(io::Error::new(
            io::ErrorKind::ResourceBusy,
            format!(
                "another app still has {} open for writing, so it stays",
                temp.display()
            ),
        )));
    }
    fs::remove_file(temp)?;
    match (deleted, swaps) {
        (true, _) => Err(SaveError::Conflict),
        (false, 1) => Ok(()),
        _ => Err(SaveError::Raced(put)),
    }
}

/// Swaps the files at `a` and `b`, both of which must exist.
fn swap(a: &Path, b: &Path) -> io::Result<()> {
    step();
    let c = |path: &Path| {
        CString::new(path.as_os_str().as_bytes()).map_err(|_| io::ErrorKind::InvalidInput)
    };
    let (a, b) = (c(a)?, c(b)?);
    // SAFETY: both strings outlive the call.
    if unsafe { libc::renamex_np(a.as_ptr(), b.as_ptr(), libc::RENAME_SWAP) } == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}

// libc has no vnode_fdinfo.
#[repr(C)]
struct VnodeFdInfo {
    file: ProcFileInfo,
    vnode: libc::vnode_info,
}

#[repr(C)]
struct ProcFileInfo {
    open_flags: u32,
    status: u32,
    offset: libc::off_t,
    kind: i32,
    guard_flags: u32,
}

const PROC_PIDFDVNODEINFO: c_int = 1;
const FWRITE: u32 = 2;

/// Whether a process other than this one has the file at `path` open for
/// writing. Processes this user can't inspect are not seen.
fn held(path: &Path) -> io::Result<bool> {
    let file = fs::symlink_metadata(path)?;
    let me = std::process::id() as c_int;
    let size = |count: usize, of: usize| {
        c_int::try_from(count * of).map_err(|_| io::Error::from(io::ErrorKind::InvalidInput))
    };
    // SAFETY: each buffer holds the bytes its size says, and libproc writes no more.
    unsafe {
        let mut pids =
            vec![0 as c_int; libc::proc_listallpids(std::ptr::null_mut(), 0).max(0) as usize + 64];
        let count = libc::proc_listallpids(pids.as_mut_ptr().cast(), size(pids.len(), 4)?);
        if count < 0 {
            return Err(io::Error::last_os_error());
        }
        let mut fds = Vec::new();
        for &pid in pids.iter().take(count as usize).filter(|&&pid| pid != me) {
            let needed = libc::proc_pidinfo(pid, libc::PROC_PIDLISTFDS, 0, std::ptr::null_mut(), 0);
            // Gone, or another user's.
            if needed <= 0 {
                continue;
            }
            fds.resize(
                needed as usize / size_of::<libc::proc_fdinfo>(),
                libc::proc_fdinfo {
                    proc_fd: 0,
                    proc_fdtype: 0,
                },
            );
            let listed = libc::proc_pidinfo(
                pid,
                libc::PROC_PIDLISTFDS,
                0,
                fds.as_mut_ptr().cast(),
                size(fds.len(), size_of::<libc::proc_fdinfo>())?,
            );
            for fd in fds
                .iter()
                .take(listed.max(0) as usize / size_of::<libc::proc_fdinfo>())
            {
                if fd.proc_fdtype != libc::PROX_FDTYPE_VNODE as u32 {
                    continue;
                }
                let mut info = std::mem::MaybeUninit::<VnodeFdInfo>::zeroed();
                let wrote = libc::proc_pidfdinfo(
                    pid,
                    fd.proc_fd,
                    PROC_PIDFDVNODEINFO,
                    info.as_mut_ptr().cast(),
                    size(1, size_of::<VnodeFdInfo>())?,
                );
                if wrote as usize != size_of::<VnodeFdInfo>() {
                    continue;
                }
                let info = info.assume_init();
                let stat = &info.vnode.vi_stat;
                // dev_t is 32 bits here.
                if (stat.vst_dev, stat.vst_ino) == (file.dev() as u32, file.ino())
                    && info.file.open_flags & FWRITE != 0
                {
                    return Ok(true);
                }
            }
        }
    }
    Ok(false)
}

/// Reads what a swap took off the path, without waiting on a pipe put there.
fn read(path: &Path) -> io::Result<Vec<u8>> {
    let mut bytes = Vec::new();
    OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NONBLOCK)
        .open(path)?
        .read_to_end(&mut bytes)?;
    Ok(bytes)
}

#[cfg(test)]
thread_local! {
    static HOOK: std::cell::RefCell<Option<Box<dyn FnMut()>>> =
        const { std::cell::RefCell::new(None) };
}

/// Test builds run the hook a test sets before each swap and each write in
/// place, standing in for another writer.
#[cfg(test)]
fn step() {
    HOOK.with_borrow_mut(|hook| {
        if let Some(hook) = hook {
            hook();
        }
    });
}

#[cfg(not(test))]
fn step() {}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;
    use std::collections::HashSet;
    use std::ffi::{CString, OsString};
    use std::os::unix::ffi::OsStrExt;
    use std::os::unix::fs::{PermissionsExt, symlink};
    use std::path::PathBuf;
    use std::process::Stdio;
    use std::time::Duration;

    /// Saves with a store of its own, for tests that never look in one.
    fn save(path: &Path, base: &Hash, bytes: &[u8]) -> Result<Hash, SaveError> {
        let snapshots = tempfile::tempdir().unwrap();
        super::save(path, base, bytes, &Store::open(snapshots.path()).unwrap())
    }

    fn file(bytes: &[u8]) -> (tempfile::TempDir, PathBuf) {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("launch-plan.md");
        fs::write(&path, bytes).unwrap();
        (dir, path)
    }

    fn names(dir: &Path) -> Vec<OsString> {
        let mut names: Vec<_> = fs::read_dir(dir)
            .unwrap()
            .map(|entry| entry.unwrap().file_name())
            .collect();
        names.sort();
        names
    }

    fn set_modified(path: &Path, time: SystemTime) {
        File::options()
            .write(true)
            .open(path)
            .unwrap()
            .set_modified(time)
            .unwrap();
    }

    fn c_path(path: &Path) -> CString {
        CString::new(path.as_os_str().as_bytes()).unwrap()
    }

    fn set_xattr(path: &Path, name: &str, value: &[u8]) {
        let name = CString::new(name).unwrap();
        // SAFETY: the strings and the value outlive the call.
        let status = unsafe {
            libc::setxattr(
                c_path(path).as_ptr(),
                name.as_ptr(),
                value.as_ptr().cast(),
                value.len(),
                0,
                0,
            )
        };
        assert_eq!(status, 0, "{}", io::Error::last_os_error());
    }

    fn xattr(path: &Path, name: &str) -> Option<Vec<u8>> {
        let name = CString::new(name).unwrap();
        let mut value = vec![0u8; 256];
        // SAFETY: the strings outlive the call and the buffer holds `value.len()` bytes.
        let size = unsafe {
            libc::getxattr(
                c_path(path).as_ptr(),
                name.as_ptr(),
                value.as_mut_ptr().cast(),
                value.len(),
                0,
                0,
            )
        };
        (size >= 0).then(|| {
            value.truncate(size as usize);
            value
        })
    }

    const OLD: Duration = Duration::from_secs(1_000_000_000);

    #[test]
    fn hash_is_blake3() {
        assert_eq!(
            hash(b"").to_hex().as_str(),
            "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262"
        );
    }

    #[test]
    fn edits_change_only_their_bytes() {
        let original =
            b"\xEF\xBB\xBF# Launch plan\r\n\r\nShip the b\xC3\xA9ta on Friday.\nThen \xE2\x80\x9Crest\xE2\x80\x9D.\rLast line";
        let edited =
            b"\xEF\xBB\xBF# Launch plan\r\n\r\nShip the b\xC3\xA9ta on Monday.\nThen \xE2\x80\x9Crest\xE2\x80\x9D.\rLast line";
        let (_dir, path) = file(original);
        let new = save(&path, &hash(original), edited).unwrap();
        assert_eq!(fs::read(&path).unwrap(), edited);
        assert_eq!(new, hash(edited));
    }

    #[test]
    fn no_edits_write_nothing() {
        let (dir, path) = file(b"# Notes\r\n");
        set_modified(&path, UNIX_EPOCH + OLD);
        let before = fs::metadata(&path).unwrap();
        let base = hash(b"# Notes\r\n");
        assert_eq!(save(&path, &base, b"# Notes\r\n").unwrap(), base);
        let after = fs::metadata(&path).unwrap();
        assert_eq!(after.ino(), before.ino());
        assert_eq!(after.modified().unwrap(), UNIX_EPOCH + OLD);
        assert_eq!(names(dir.path()), ["launch-plan.md"]);
    }

    #[test]
    fn a_change_on_disk_is_a_conflict_and_stays() {
        let (dir, path) = file(b"# Notes\n");
        let base = hash(b"# Notes\n");
        fs::write(&path, b"# Notes\nAn agent wrote this.\n").unwrap();
        assert!(matches!(
            save(&path, &base, b"# My notes\n"),
            Err(SaveError::Conflict)
        ));
        assert_eq!(fs::read(&path).unwrap(), b"# Notes\nAn agent wrote this.\n");
        assert!(matches!(
            save(&path, &base, b"# Notes\n"),
            Err(SaveError::Conflict)
        ));
        fs::remove_file(&path).unwrap();
        assert!(matches!(
            save(&path, &base, b"# My notes\n"),
            Err(SaveError::Conflict)
        ));
        assert!(names(dir.path()).is_empty());
    }

    #[test]
    fn a_touch_alone_is_no_conflict() {
        let (_dir, path) = file(b"# Notes\n");
        set_modified(&path, UNIX_EPOCH + OLD);
        save(&path, &hash(b"# Notes\n"), b"# My notes\n").unwrap();
        assert_eq!(fs::read(&path).unwrap(), b"# My notes\n");
    }

    #[test]
    fn a_replaced_file_keeps_mode_and_xattrs_and_gets_a_new_date() {
        let (dir, path) = file(b"# Notes\n");
        fs::set_permissions(&path, fs::Permissions::from_mode(0o640)).unwrap();
        set_xattr(&path, "dev.arkwerx.dewline.test", b"kept");
        set_modified(&path, UNIX_EPOCH + OLD);
        let before = fs::metadata(&path).unwrap();
        save(&path, &hash(b"# Notes\n"), b"# My notes\n").unwrap();
        let after = fs::metadata(&path).unwrap();
        assert_ne!(after.ino(), before.ino(), "the sibling replaced the file");
        assert_eq!(after.permissions().mode() & 0o7777, 0o640);
        assert_eq!(
            xattr(&path, "dev.arkwerx.dewline.test").as_deref(),
            Some(&b"kept"[..])
        );
        assert!(after.modified().unwrap() > UNIX_EPOCH + OLD);
        assert_eq!(fs::read(&path).unwrap(), b"# My notes\n");
        assert_eq!(names(dir.path()), ["launch-plan.md"]);
    }

    #[test]
    fn a_name_at_the_length_limit_saves() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join(format!("{}.md", "n".repeat(252)));
        fs::write(&path, b"# Notes\n").unwrap();
        save(&path, &hash(b"# Notes\n"), b"# My notes\n").unwrap();
        assert_eq!(fs::read(&path).unwrap(), b"# My notes\n");
    }

    #[test]
    fn a_symlink_is_written_through() {
        let (dir, target) = file(b"# Notes\n");
        let link = dir.path().join("link.md");
        symlink(&target, &link).unwrap();
        fs::set_permissions(&target, fs::Permissions::from_mode(0o600)).unwrap();
        set_xattr(&target, "dev.arkwerx.dewline.test", b"kept");
        save(&link, &hash(b"# Notes\n"), b"# My notes\n").unwrap();
        assert!(fs::symlink_metadata(&link).unwrap().is_symlink());
        assert_eq!(fs::read_link(&link).unwrap(), target);
        assert_eq!(fs::read(&target).unwrap(), b"# My notes\n");
        assert_eq!(
            fs::metadata(&target).unwrap().permissions().mode() & 0o7777,
            0o600
        );
        assert_eq!(
            xattr(&target, "dev.arkwerx.dewline.test").as_deref(),
            Some(&b"kept"[..])
        );
        assert_eq!(names(dir.path()), ["launch-plan.md", "link.md"]);
    }

    #[test]
    fn an_acl_keeps_the_file_in_place_and_leaves_nothing_behind() {
        let (dir, path) = file(b"# Notes\n");
        let chmod = |args: &[&str]| {
            let status = std::process::Command::new("/bin/chmod")
                .args(args)
                .arg(&path)
                .status()
                .unwrap();
            assert!(status.success());
        };
        chmod(&["+a", "everyone deny delete"]);
        let before = fs::metadata(&path).unwrap();
        let saves = [
            save(&path, &hash(b"# Notes\n"), b"# My notes\n"),
            save(&path, &hash(b"# My notes\n"), b"# Our notes\n"),
        ];
        let acl = has_acl(&File::open(&path).unwrap()).unwrap();
        // Lifted before asserting, so the folder can always be removed.
        chmod(&["-N"]);
        assert!(saves.iter().all(Result::is_ok), "{saves:?}");
        assert!(acl);
        assert_eq!(fs::read(&path).unwrap(), b"# Our notes\n");
        assert_eq!(fs::metadata(&path).unwrap().ino(), before.ino());
        assert_eq!(names(dir.path()), ["launch-plan.md"]);
    }

    #[test]
    fn a_failed_write_in_place_puts_the_original_back() {
        // The file size limit holds for the whole process, so this runs alone in a child.
        let name = "file::tests::a_failed_write_in_place_puts_the_original_back";
        if std::env::var_os("DEWLINE_TEST_FSIZE").is_none() {
            let child = std::process::Command::new(std::env::current_exe().unwrap())
                .args(["--exact", name])
                .env("DEWLINE_TEST_FSIZE", "1")
                .output()
                .unwrap();
            let report = String::from_utf8_lossy(&child.stdout);
            assert!(
                child.status.success() && report.contains("1 passed"),
                "{report}"
            );
            return;
        }
        let (dir, path) = file(b"# Notes\n");
        fs::hard_link(&path, dir.path().join("other.md")).unwrap();
        // SAFETY: this child process runs only this test.
        unsafe {
            libc::signal(libc::SIGXFSZ, libc::SIG_IGN);
            let mut limit = std::mem::zeroed::<libc::rlimit>();
            assert_eq!(libc::getrlimit(libc::RLIMIT_FSIZE, &mut limit), 0);
            limit.rlim_cur = 4096;
            assert_eq!(libc::setrlimit(libc::RLIMIT_FSIZE, &limit), 0);
        }
        let result = save(&path, &hash(b"# Notes\n"), &[b'x'; 65536]);
        assert!(matches!(result, Err(SaveError::Io(_))), "{result:?}");
        assert_eq!(fs::read(&path).unwrap(), b"# Notes\n");
        let retry = save(&path, &hash(b"# Notes\n"), b"# My notes\n");
        assert!(retry.is_ok(), "{retry:?}");
    }

    #[test]
    fn a_group_the_sibling_cannot_take_stays() {
        // Files made in /private/tmp take its group, wheel, which a sibling
        // made elsewhere can't be given by a user outside wheel.
        let wheel = tempfile::tempdir_in("/private/tmp").unwrap();
        let (dir, path) = file(b"");
        fs::remove_file(&path).unwrap();
        fs::write(wheel.path().join("launch-plan.md"), b"# Notes\n").unwrap();
        fs::rename(wheel.path().join("launch-plan.md"), &path).unwrap();
        let before = fs::metadata(&path).unwrap();
        assert_ne!(before.gid(), fs::metadata(dir.path()).unwrap().gid());
        save(&path, &hash(b"# Notes\n"), b"# My notes\n").unwrap();
        let after = fs::metadata(&path).unwrap();
        assert_eq!((after.uid(), after.gid()), (before.uid(), before.gid()));
        assert_eq!(fs::read(&path).unwrap(), b"# My notes\n");
        assert_eq!(names(dir.path()), ["launch-plan.md"]);
    }

    #[test]
    fn a_hard_link_stays_linked() {
        let (dir, path) = file(b"# Notes, a longer first line\n");
        let other = dir.path().join("other.md");
        fs::hard_link(&path, &other).unwrap();
        save(
            &path,
            &hash(b"# Notes, a longer first line\n"),
            b"# Short\n",
        )
        .unwrap();
        let (one, two) = (fs::metadata(&path).unwrap(), fs::metadata(&other).unwrap());
        assert_eq!((one.ino(), one.nlink()), (two.ino(), 2));
        assert_eq!(fs::read(&other).unwrap(), b"# Short\n");
        assert_eq!(names(dir.path()), ["launch-plan.md", "other.md"]);
    }

    #[test]
    fn a_write_just_before_a_write_in_place_is_a_conflict_and_stays() {
        let (dir, path) = file(b"# Notes\n");
        fs::hard_link(&path, dir.path().join("other.md")).unwrap();
        let at = path.clone();
        let saved = hooked(
            move |_| append(&at, b"Codex wrote this.\n"),
            || save(&path, &hash(b"# Notes\n"), b"# My notes\n"),
        );
        assert!(matches!(saved, Err(SaveError::Conflict)), "{saved:?}");
        assert_eq!(fs::read(&path).unwrap(), b"# Notes\nCodex wrote this.\n");
    }

    #[test]
    fn a_symlink_swaps_its_target_beside_it() {
        let (dir, target) = file(b"# Notes\n");
        let links = tempfile::tempdir().unwrap();
        let link = links.path().join("link.md");
        symlink(&target, &link).unwrap();
        // A sibling of the link could not be made here; one of the target can.
        fs::set_permissions(links.path(), fs::Permissions::from_mode(0o555)).unwrap();
        let before = fs::metadata(&target).unwrap();
        let saved = save(&link, &hash(b"# Notes\n"), b"# My notes\n");
        fs::set_permissions(links.path(), fs::Permissions::from_mode(0o755)).unwrap();
        saved.unwrap();
        assert_eq!(fs::read_link(&link).unwrap(), target);
        assert_ne!(fs::metadata(&target).unwrap().ino(), before.ino());
        assert_eq!(fs::read(&link).unwrap(), b"# My notes\n");
        assert_eq!(names(dir.path()), ["launch-plan.md"]);
    }

    #[test]
    fn a_read_only_folder_writes_in_place() {
        let (dir, path) = file(b"# Notes\n");
        fs::set_permissions(dir.path(), fs::Permissions::from_mode(0o555)).unwrap();
        let before = fs::metadata(&path).unwrap();
        let saved = save(&path, &hash(b"# Notes\n"), b"# My notes\n");
        fs::set_permissions(dir.path(), fs::Permissions::from_mode(0o755)).unwrap();
        saved.unwrap();
        assert_eq!(fs::read(&path).unwrap(), b"# My notes\n");
        assert_eq!(fs::metadata(&path).unwrap().ino(), before.ino());
        assert_eq!(names(dir.path()), ["launch-plan.md"]);
    }

    /// Runs `run` with `hook` called before each of its swaps, given the swap's number.
    fn hooked<T>(mut hook: impl FnMut(usize) + 'static, run: impl FnOnce() -> T) -> T {
        let mut swaps = 0;
        HOOK.set(Some(Box::new(move || {
            swaps += 1;
            hook(swaps);
        })));
        let result = run();
        HOOK.set(None);
        result
    }

    fn rename_over(path: &Path, bytes: &[u8]) {
        let temp = path.with_file_name("writer.tmp");
        fs::write(&temp, bytes).unwrap();
        fs::rename(&temp, path).unwrap();
    }

    fn append(path: &Path, bytes: &[u8]) {
        let mut file = OpenOptions::new().append(true).open(path).unwrap();
        file.write_all(bytes).unwrap();
    }

    /// The snapshots `store` holds for `path`, oldest first.
    fn kept(store: &Store, path: &Path) -> Vec<Vec<u8>> {
        let history = store.list(&fs::canonicalize(path).unwrap()).unwrap();
        history
            .iter()
            .rev()
            .map(|s| store.get(&s.hash).unwrap())
            .collect()
    }

    #[test]
    fn a_write_before_the_swap_is_put_back_and_the_save_refused() {
        type Write = fn(&Path, &[u8]);
        let theirs = b"# Notes\nClaude wrote this.\n";
        let writes: [(Write, &[u8], &[u8]); 3] = [
            (rename_over, theirs, theirs),
            (
                |path, bytes| fs::write(path, bytes).unwrap(),
                theirs,
                theirs,
            ),
            (
                append,
                b"Codex wrote this.\n",
                b"# Notes\nCodex wrote this.\n",
            ),
        ];
        for (write, written, on_disk) in writes {
            let (dir, path) = file(b"# Notes\n");
            let snapshots = tempfile::tempdir().unwrap();
            let store = Store::open(snapshots.path()).unwrap();
            let (at, written) = (path.clone(), written.to_vec());
            let saved = hooked(
                move |swap| {
                    if swap == 1 {
                        write(&at, &written);
                    }
                },
                || super::save(&path, &hash(b"# Notes\n"), b"# My notes\n", &store),
            );
            assert!(
                matches!(saved, Err(SaveError::Raced(on)) if on == hash(on_disk)),
                "{saved:?}"
            );
            assert_eq!(fs::read(&path).unwrap(), on_disk);
            assert_eq!(kept(&store, &path), [on_disk]);
            assert_eq!(names(dir.path()), ["launch-plan.md"]);
        }
    }

    #[test]
    fn a_write_between_swaps_ends_on_disk_and_what_it_replaced_in_the_store() {
        let (dir, path) = file(b"# Notes\n");
        let snapshots = tempfile::tempdir().unwrap();
        let store = Store::open(snapshots.path()).unwrap();
        let at = path.clone();
        let saved = hooked(
            move |swap| match swap {
                1 => rename_over(&at, b"# Notes\nFirst.\n"),
                2 => rename_over(&at, b"# Notes\nSecond.\n"),
                _ => {}
            },
            || super::save(&path, &hash(b"# Notes\n"), b"# My notes\n", &store),
        );
        assert!(
            matches!(saved, Err(SaveError::Raced(on)) if on == hash(b"# Notes\nSecond.\n")),
            "{saved:?}"
        );
        assert_eq!(fs::read(&path).unwrap(), b"# Notes\nSecond.\n");
        assert_eq!(
            kept(&store, &path),
            [&b"# Notes\nFirst.\n"[..], b"# Notes\nSecond.\n"]
        );
        assert_eq!(names(dir.path()), ["launch-plan.md"]);
    }

    #[test]
    fn a_write_in_place_on_the_saved_file_between_swaps_ends_on_disk() {
        let (dir, path) = file(b"# Notes\n");
        let snapshots = tempfile::tempdir().unwrap();
        let store = Store::open(snapshots.path()).unwrap();
        let at = path.clone();
        let saved = hooked(
            move |swap| match swap {
                1 => rename_over(&at, b"# Notes\nFirst.\n"),
                // The path holds the save's file now.
                2 => append(&at, b"Appended.\n"),
                _ => {}
            },
            || super::save(&path, &hash(b"# Notes\n"), b"# My notes\n", &store),
        );
        let on_disk = b"# My notes\nAppended.\n";
        assert!(
            matches!(saved, Err(SaveError::Raced(on)) if on == hash(on_disk)),
            "{saved:?}"
        );
        assert_eq!(fs::read(&path).unwrap(), on_disk);
        assert_eq!(kept(&store, &path), [&b"# Notes\nFirst.\n"[..], on_disk]);
        assert_eq!(names(dir.path()), ["launch-plan.md"]);
    }

    #[test]
    fn a_file_deleted_during_the_save_stays_deleted() {
        for deleted_at in [1, 2] {
            let (dir, path) = file(b"# Notes\n");
            let snapshots = tempfile::tempdir().unwrap();
            let store = Store::open(snapshots.path()).unwrap();
            let at = path.clone();
            let saved = hooked(
                move |swap| {
                    if swap == 1 {
                        rename_over(&at, b"# Notes\nFirst.\n");
                    }
                    if swap == deleted_at {
                        fs::remove_file(&at).unwrap();
                    }
                },
                || super::save(&path, &hash(b"# Notes\n"), b"# My notes\n", &store),
            );
            assert!(matches!(saved, Err(SaveError::Conflict)), "{saved:?}");
            assert!(names(dir.path()).is_empty());
            let history = store.list(&fs::canonicalize(dir.path()).unwrap().join("launch-plan.md"));
            let expected: &[&[u8]] = if deleted_at == 1 {
                &[]
            } else {
                &[b"# Notes\nFirst.\n"]
            };
            let history: Vec<_> = history
                .unwrap()
                .iter()
                .map(|s| store.get(&s.hash).unwrap())
                .collect();
            assert_eq!(history, expected, "deleted at swap {deleted_at}");
        }
    }

    #[test]
    fn a_writer_at_every_swap_stops_the_save_after_sixteen() {
        let (dir, path) = file(b"# Notes\n");
        let snapshots = tempfile::tempdir().unwrap();
        let store = Store::open(snapshots.path()).unwrap();
        let version = |n: usize| format!("# Notes\nVersion {n}.\n").into_bytes();
        let at = path.clone();
        let saved = hooked(
            move |swap| rename_over(&at, &version(swap)),
            || super::save(&path, &hash(b"# Notes\n"), b"# My notes\n", &store),
        );
        // The newest stays off the disk, in the store with every other version.
        assert!(
            matches!(saved, Err(SaveError::Raced(on)) if on == hash(&version(SWAPS - 1))),
            "{saved:?}"
        );
        assert_eq!(fs::read(&path).unwrap(), version(SWAPS - 1));
        assert_eq!(
            kept(&store, &path),
            (1..=SWAPS).map(version).collect::<Vec<_>>()
        );
        assert_eq!(names(dir.path()), ["launch-plan.md"]);
    }

    #[test]
    fn a_writer_holding_the_file_open_keeps_what_it_writes_after_the_save() {
        let test =
            "file::tests::a_writer_holding_the_file_open_keeps_what_it_writes_after_the_save";
        let signals = |folder: &Path| (folder.join("open"), folder.join("write"));
        if let Some(path) = std::env::var_os("DEWLINE_TEST_HOLDER") {
            let (open, write) = signals(Path::new(
                &std::env::var_os("DEWLINE_TEST_SIGNALS").unwrap(),
            ));
            let mut file = OpenOptions::new().append(true).open(path).unwrap();
            File::create(open).unwrap();
            while !write.exists() {
                std::thread::sleep(Duration::from_millis(1));
            }
            file.write_all(b"Appended late.\n").unwrap();
            return;
        }
        let (dir, path) = file(b"# Notes\n");
        let other = tempfile::tempdir().unwrap();
        let store = Store::open(&other.path().join("snapshots")).unwrap();
        let (open, write) = signals(other.path());
        let mut holder = std::process::Command::new(std::env::current_exe().unwrap())
            .args(["--exact", test])
            .env("DEWLINE_TEST_HOLDER", &path)
            .env("DEWLINE_TEST_SIGNALS", other.path())
            .stdout(Stdio::null())
            .spawn()
            .unwrap();
        while !open.exists() {
            std::thread::sleep(Duration::from_millis(1));
        }
        let saved = super::save(&path, &hash(b"# Notes\n"), b"# My notes\n", &store);
        File::create(&write).unwrap();
        assert!(holder.wait().unwrap().success());
        assert!(
            matches!(saved, Err(SaveError::Raced(on)) if on == hash(b"# Notes\n")),
            "{saved:?}"
        );
        assert_eq!(fs::read(&path).unwrap(), b"# Notes\nAppended late.\n");
        assert_eq!(names(dir.path()), ["launch-plan.md"]);
    }

    /// Writes versions of `path` until `stop` exists, in bursts with rests
    /// between them. Each adds a line naming it: version n renames over the
    /// file when n % 3 is 0, truncates and writes it when 1, appends when 2.
    /// Returns how many it wrote.
    fn write_until(path: &Path, stop: &Path) -> u64 {
        let mut x = u64::from(std::process::id()) | 1;
        let mut random = move || {
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
            x
        };
        let mut written = 0;
        while !stop.exists() {
            for _ in 0..=random() % 64 {
                let line = format!("w{written:09}\n");
                match written % 3 {
                    0 => rename_over(path, &[fs::read(path).unwrap(), line.into_bytes()].concat()),
                    1 => fs::write(path, [fs::read(path).unwrap(), line.into_bytes()].concat())
                        .unwrap(),
                    _ => append(path, line.as_bytes()),
                }
                written += 1;
            }
            // Mostly short rests, and now and then one long enough for a save to land.
            let rest = if random() % 8 == 0 { 200_000 } else { 2_000 };
            std::thread::sleep(Duration::from_micros(random() % rest));
        }
        written
    }

    fn lines(bytes: &[u8]) -> impl Iterator<Item = Vec<u8>> {
        bytes
            .split_inclusive(|&byte| byte == b'\n')
            .map(<[u8]>::to_vec)
    }

    /// The writer is another process. DEWLINE_RACING_SAVES sets how many
    /// saves race it, 500 unless set.
    #[test]
    fn a_racing_writer_loses_nothing() {
        let test = "file::tests::a_racing_writer_loses_nothing";
        if let Some(path) = std::env::var_os("DEWLINE_TEST_WRITER") {
            let stop = std::env::var_os("DEWLINE_TEST_STOP").unwrap();
            println!("wrote {}", write_until(Path::new(&path), Path::new(&stop)));
            return;
        }
        let (dir, path) = file(b"# Notes\n");
        let other = tempfile::tempdir().unwrap();
        let store = Store::open(&other.path().join("snapshots")).unwrap();
        let stop = other.path().join("stop");
        let writer = std::process::Command::new(std::env::current_exe().unwrap())
            .args(["--exact", test, "--nocapture"])
            .env("DEWLINE_TEST_WRITER", &path)
            .env("DEWLINE_TEST_STOP", &stop)
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        let saves: u32 = std::env::var("DEWLINE_RACING_SAVES").map_or(500, |n| n.parse().unwrap());
        // Every line of every version a save wrote.
        let mut mine = HashSet::new();
        let (mut saved, mut stale, mut raced) = (0, 0, 0);
        for n in 0..saves {
            let observed = fs::read(&path).unwrap();
            let bytes: Vec<u8> = lines(&observed)
                .filter(|line| !mine.contains(line))
                .chain([format!("s{n:09}\n").into_bytes()])
                .flatten()
                .collect();
            match super::save(&path, &hash(&observed), &bytes, &store) {
                Ok(_) => {
                    saved += 1;
                    mine.extend(lines(&bytes));
                }
                Err(SaveError::Conflict) => stale += 1,
                Err(SaveError::Raced(_)) => raced += 1,
                Err(SaveError::Io(error)) => panic!("{error}"),
            }
        }
        File::create(&stop).unwrap();
        let output = writer.wait_with_output().unwrap();
        let report = String::from_utf8_lossy(&output.stdout);
        assert!(output.status.success(), "{report}");
        let written: u64 = report
            .lines()
            .find_map(|line| line.strip_prefix("wrote "))
            .unwrap()
            .parse()
            .unwrap();
        let snapshots = kept(&store, &path);
        let mut found = mine;
        found.extend(lines(&fs::read(&path).unwrap()));
        found.extend(snapshots.iter().flat_map(|bytes| lines(bytes)));
        let lost: Vec<_> = (0..written)
            .filter(|n| !found.contains(format!("w{n:09}\n").as_bytes()))
            .collect();
        println!(
            "{saves} saves: {saved} saved, {stale} refused before the swap, {raced} raced; \
             {written} versions written, {} snapshots",
            snapshots.len()
        );
        assert!(lost.is_empty(), "lost {} versions: {lost:?}", lost.len());
        assert_eq!(names(dir.path()), ["launch-plan.md"]);
    }

    proptest! {
        #![proptest_config(ProptestConfig::with_cases(64))]

        #[test]
        fn saves_are_byte_identical(
            original in proptest::collection::vec(any::<u8>(), 0..2048),
            insert in proptest::collection::vec(any::<u8>(), 0..64),
            a in any::<prop::sample::Index>(),
            b in any::<prop::sample::Index>(),
        ) {
            let (_dir, path) = file(&original);
            let base = hash(&original);
            prop_assert_eq!(save(&path, &base, &original).unwrap(), base);
            prop_assert_eq!(&fs::read(&path).unwrap(), &original);
            let (start, end) = {
                let (a, b) = (a.index(original.len() + 1), b.index(original.len() + 1));
                (a.min(b), a.max(b))
            };
            let edited = [&original[..start], &insert, &original[end..]].concat();
            save(&path, &base, &edited).unwrap();
            prop_assert_eq!(fs::read(&path).unwrap(), edited);
        }
    }
}
