use std::fs::{self, File, OpenOptions};
use std::io::{self, Seek, SeekFrom, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::MetadataExt;
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

pub use blake3::Hash;

pub fn hash(bytes: &[u8]) -> Hash {
    blake3::hash(bytes)
}

#[derive(Debug)]
pub enum SaveError {
    /// The file no longer holds the bytes the save was based on, or is gone.
    Conflict,
    Io(io::Error),
}

impl From<io::Error> for SaveError {
    fn from(error: io::Error) -> Self {
        SaveError::Io(error)
    }
}

/// Writes `bytes` to `path` if the file still holds the bytes `base` hashes,
/// and returns their hash. Bytes that hash to `base` write nothing.
///
/// A symlink, or a file with other hard links, is written in place so its
/// links survive. Any other file is replaced by a sibling that carries its
/// mode, flags, ACL and extended attributes.
pub fn save(path: &Path, base: &Hash, bytes: &[u8]) -> Result<Hash, SaveError> {
    // Hashed first, so the check stays next to the write.
    let new = hash(bytes);
    let mut file = unchanged(path, base)?;
    if new == *base {
        return Ok(new);
    }
    let link = fs::symlink_metadata(path)?;
    if link.is_symlink() || link.nlink() > 1 {
        file.seek(SeekFrom::Start(0))?;
        file.write_all(bytes)?;
        file.set_len(bytes.len() as u64)?;
        file.sync_all()?;
    } else {
        replace(path, &file, base, bytes)?;
    }
    Ok(new)
}

/// Opens `path` for writing if it still holds the bytes `base` hashes.
fn unchanged(path: &Path, base: &Hash) -> Result<File, SaveError> {
    let mut file = OpenOptions::new()
        .read(true)
        .write(true)
        .open(path)
        .map_err(|error| match error.kind() {
            io::ErrorKind::NotFound => SaveError::Conflict,
            _ => SaveError::Io(error),
        })?;
    let mut hasher = blake3::Hasher::new();
    io::copy(&mut file, &mut hasher)?;
    if hasher.finalize() == *base {
        Ok(file)
    } else {
        Err(SaveError::Conflict)
    }
}

/// Writes `bytes` to a hidden sibling of `path` with `original`'s metadata,
/// then renames it over `path` if the file still holds `base`.
fn replace(path: &Path, original: &File, base: &Hash, bytes: &[u8]) -> Result<(), SaveError> {
    let stamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    // Not derived from the file's name, which may already be at the 255-byte limit.
    let temp = path.with_file_name(format!(".dewline.{}.{stamp:x}.tmp", std::process::id()));
    let result = (|| {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temp)?;
        // Copying the metadata copies the old modification date too, so it
        // comes before the bytes, whose write sets the date to now.
        // SAFETY: both descriptors stay open for the call; copyfile accepts a null state.
        let copied = unsafe {
            libc::fcopyfile(
                original.as_raw_fd(),
                file.as_raw_fd(),
                std::ptr::null_mut(),
                libc::COPYFILE_METADATA,
            )
        };
        if copied != 0 {
            return Err(io::Error::last_os_error().into());
        }
        file.write_all(bytes)?;
        file.sync_all()?;
        // Another writer may have landed while the copy was written.
        unchanged(path, base)?;
        fs::rename(&temp, path)?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temp);
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;
    use std::ffi::{CString, OsString};
    use std::os::unix::ffi::OsStrExt;
    use std::os::unix::fs::{PermissionsExt, symlink};
    use std::path::PathBuf;
    use std::time::Duration;

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
