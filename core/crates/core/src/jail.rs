//! Files under one root folder and nowhere else. A path is resolved with realpath and must lie inside the root; it is
//! then opened from the root's descriptor with no symlink anywhere on the way, and the opened file's own path must
//! still lie inside the root, so a link or folder swapped in between the two steps opens nothing.

use std::ffi::CString;
use std::fmt;
use std::fs::{self, File};
use std::io;
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};

pub struct Jail {
    root: PathBuf,
    dir: File,
}

#[derive(Debug)]
pub enum JailError {
    /// The path lies outside the root, or something on its way changed while it was opened.
    Outside,
    /// A root an agent is never given, and why.
    Root(&'static str),
    Io(io::Error),
}

impl From<io::Error> for JailError {
    fn from(error: io::Error) -> Self {
        JailError::Io(error)
    }
}

impl fmt::Display for JailError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            JailError::Outside => f.write_str("it is outside the folder"),
            JailError::Root(why) => f.write_str(why),
            JailError::Io(error) => error.fmt(f),
        }
    }
}

impl Jail {
    pub fn new(root: &Path) -> io::Result<Jail> {
        let dir = open_at(libc::AT_FDCWD, root, libc::O_DIRECTORY)?;
        let root = fd_path(&dir)?;
        Ok(Jail { root, dir })
    }

    /// A jail for an agent: never a root at or above `home`, inside `~/Library`, or holding `.ssh`.
    pub fn for_agents(root: &Path, home: &Path) -> Result<Jail, JailError> {
        let jail = Jail::new(root)?;
        let home = fs::canonicalize(home)?;
        // Case-folded, so a differently cased name on a case-insensitive volume is refused too.
        let fold = |path: &Path| PathBuf::from(path.to_string_lossy().to_lowercase());
        let (root, home) = (fold(&jail.root), fold(&home));
        if home.starts_with(&root) {
            return Err(JailError::Root(
                "the folder is your home folder or holds it",
            ));
        }
        if root.starts_with(home.join("library")) {
            return Err(JailError::Root("the folder is inside ~/Library"));
        }
        if root.iter().any(|part| part == ".ssh")
            || fs::symlink_metadata(jail.root.join(".ssh")).is_ok()
        {
            return Err(JailError::Root("the folder holds .ssh"));
        }
        Ok(jail)
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    /// `path`, absolute or relative to the root, as the root-relative path of the file it resolves to.
    pub fn resolve(&self, path: &Path) -> Result<PathBuf, JailError> {
        let real = fs::canonicalize(self.root.join(path))?;
        self.inside(&real)
    }

    /// Opens `path` for reading, and returns it with its root-relative path. Opening never blocks, so a pipe opens
    /// as one, not as a wait for a writer.
    pub fn open(&self, path: &Path) -> Result<(File, PathBuf), JailError> {
        let relative = self.resolve(path)?;
        let name = if relative.as_os_str().is_empty() {
            Path::new(".")
        } else {
            &relative
        };
        let file = match open_at(
            self.dir.as_raw_fd(),
            name,
            libc::O_NOFOLLOW_ANY | libc::O_NONBLOCK,
        ) {
            Err(error) if error.raw_os_error() == Some(libc::ELOOP) => {
                return Err(JailError::Outside);
            }
            result => result?,
        };
        let relative = self.inside(&fd_path(&file)?)?;
        Ok((file, relative))
    }

    fn inside(&self, real: &Path) -> Result<PathBuf, JailError> {
        real.strip_prefix(&self.root)
            .map(Path::to_path_buf)
            .map_err(|_| JailError::Outside)
    }
}

fn open_at(dir: libc::c_int, path: &Path, flags: libc::c_int) -> io::Result<File> {
    let name =
        CString::new(path.as_os_str().as_bytes()).map_err(|_| io::ErrorKind::InvalidInput)?;
    // SAFETY: `name` is a NUL-terminated string that outlives the call.
    let fd = unsafe { libc::openat(dir, name.as_ptr(), flags | libc::O_RDONLY | libc::O_CLOEXEC) };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: `fd` was just opened and nothing else owns it.
    Ok(unsafe { File::from_raw_fd(fd) })
}

/// The path the kernel has for an open file.
fn fd_path(file: &File) -> io::Result<PathBuf> {
    let mut buffer = [0u8; libc::PATH_MAX as usize];
    // SAFETY: F_GETPATH writes at most PATH_MAX bytes, NUL included, into `buffer`.
    if unsafe { libc::fcntl(file.as_raw_fd(), libc::F_GETPATH, buffer.as_mut_ptr()) } < 0 {
        return Err(io::Error::last_os_error());
    }
    let length = buffer
        .iter()
        .position(|&byte| byte == 0)
        .unwrap_or(buffer.len());
    Ok(PathBuf::from(std::ffi::OsStr::from_bytes(
        &buffer[..length],
    )))
}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;
    use std::io::Read;
    use std::os::unix::fs::symlink;

    /// `base/root` holding notes and every kind of link out, beside `base/outside` holding the secret.
    fn fixture() -> (tempfile::TempDir, PathBuf) {
        let base = tempfile::tempdir().unwrap();
        let root = base.path().join("root");
        let outside = base.path().join("outside");
        fs::create_dir_all(root.join("a/b")).unwrap();
        fs::create_dir_all(&outside).unwrap();
        fs::write(root.join("a/b/note.md"), "inside").unwrap();
        fs::write(root.join("top.md"), "inside").unwrap();
        fs::write(outside.join("secret.md"), "secret").unwrap();
        fs::write(base.path().join("rootish.md"), "secret").unwrap();
        fs::create_dir_all(base.path().join("rootx")).unwrap();
        fs::write(base.path().join("rootx/top.md"), "secret").unwrap();
        symlink(&outside, root.join("out")).unwrap();
        symlink(outside.join("secret.md"), root.join("secret.md")).unwrap();
        symlink("..", root.join("up")).unwrap();
        symlink("loop2", root.join("loop1")).unwrap();
        symlink("loop1", root.join("loop2")).unwrap();
        symlink("a/b/note.md", root.join("alias.md")).unwrap();
        (base, root)
    }

    fn read(jail: &Jail, path: &str) -> Result<String, JailError> {
        let (mut file, _) = jail.open(Path::new(path))?;
        let mut text = String::new();
        file.read_to_string(&mut text)?;
        Ok(text)
    }

    #[test]
    fn opens_inside_and_refuses_every_way_out() {
        let (base, root) = fixture();
        let jail = Jail::new(&root).unwrap();
        assert_eq!(read(&jail, "a/b/note.md").unwrap(), "inside");
        assert_eq!(read(&jail, "a/../top.md").unwrap(), "inside");
        assert_eq!(read(&jail, "alias.md").unwrap(), "inside");
        assert_eq!(
            jail.open(Path::new("alias.md")).unwrap().1,
            Path::new("a/b/note.md")
        );
        let absolute = root.join("top.md");
        assert_eq!(read(&jail, absolute.to_str().unwrap()).unwrap(), "inside");
        for path in [
            "../outside/secret.md",
            "out/secret.md",
            "secret.md",
            "up/outside/secret.md",
            "up/rootish.md",
            "../rootx/top.md",
            "a/b/../../../rootish.md",
            base.path().join("outside/secret.md").to_str().unwrap(),
            "/etc/hosts",
        ] {
            assert!(
                matches!(jail.open(Path::new(path)), Err(JailError::Outside)),
                "{path}"
            );
        }
        assert!(matches!(
            jail.open(Path::new("loop1")),
            Err(JailError::Io(_))
        ));
        assert!(matches!(
            jail.open(Path::new("top.md\0x")),
            Err(JailError::Io(_))
        ));
    }

    #[test]
    fn a_folder_swapped_for_a_link_after_resolving_opens_nothing() {
        let (base, root) = fixture();
        let jail = Jail::new(&root).unwrap();
        let relative = jail.resolve(Path::new("a/b/note.md")).unwrap();
        fs::rename(root.join("a"), base.path().join("moved")).unwrap();
        fs::create_dir_all(base.path().join("outside/b")).unwrap();
        fs::write(base.path().join("outside/b/note.md"), "secret").unwrap();
        symlink(base.path().join("outside"), root.join("a")).unwrap();
        let opened = open_at(jail.dir.as_raw_fd(), &relative, libc::O_NOFOLLOW_ANY);
        assert_eq!(opened.unwrap_err().raw_os_error(), Some(libc::ELOOP));
        assert!(jail.open(Path::new("a/b/note.md")).is_err());
    }

    #[test]
    fn agents_never_get_home_its_parents_library_or_ssh() {
        let base = tempfile::tempdir().unwrap();
        let home = base.path().join("home");
        for folder in [
            "notes/deep",
            "Library/Notes",
            "keys/.ssh",
            "dotted",
            "Notes",
        ] {
            fs::create_dir_all(home.join(folder)).unwrap();
        }
        fs::create_dir_all(home.join("dotted/.ssh")).unwrap();
        let refused =
            |folder: &Path| matches!(Jail::for_agents(folder, &home), Err(JailError::Root(_)));
        assert!(refused(&home));
        assert!(refused(base.path()));
        assert!(refused(Path::new("/")));
        assert!(refused(&home.join("Library/Notes")));
        assert!(refused(&home.join("library/notes")));
        assert!(refused(&home.join("keys/.ssh")));
        assert!(refused(&home.join("dotted")));
        assert!(refused(&home.join("notes/..")));
        assert!(Jail::for_agents(&home.join("notes"), &home).is_ok());
        assert!(Jail::for_agents(&home.join("notes/deep"), &home).is_ok());
    }

    proptest! {
        /// Any mix of names, dots, links and loops either opens a file inside the root or nothing.
        #[test]
        fn nothing_outside_ever_opens(
            parts in prop::collection::vec(
                prop::sample::select(vec![
                    "a", "A", "b", "B", "..", ".", "", "a.", "a..", "note.md", "NOTE.MD", "note.md.", "top.md",
                    "out", "up", "loop1", "secret.md", "alias.md", "outside", "rootx", "rootish.md",
                ]),
                0..8,
            ),
            absolute in any::<bool>(),
        ) {
            let (_base, root) = fixture();
            let jail = Jail::new(&root).unwrap();
            let joined = parts.join("/");
            let path = if absolute { root.join(&joined) } else { PathBuf::from(&joined) };
            let real = fs::canonicalize(jail.root().join(&path));
            match jail.open(&path) {
                Ok((mut file, relative)) => {
                    prop_assert!(fd_path(&file).unwrap().starts_with(jail.root()));
                    prop_assert_eq!(jail.root().join(&relative), real.unwrap());
                    if file.metadata().unwrap().is_file() {
                        let mut text = String::new();
                        file.read_to_string(&mut text).unwrap();
                        prop_assert_eq!(text, "inside");
                    }
                }
                // Whatever resolves inside opens.
                Err(_) => prop_assert!(!real.is_ok_and(|real| real.starts_with(jail.root()))),
            }
        }
    }
}
