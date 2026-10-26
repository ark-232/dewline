use std::ffi::OsStr;
use std::fs;
use std::io;
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};

/// A file to open and where to put the caret. Lines and columns count from 1.
#[derive(Debug, PartialEq)]
pub struct Target {
    /// Absolute, with every symlink resolved, naming a regular file.
    pub path: String,
    pub line: Option<u32>,
    pub column: Option<u32>,
}

/// Reads `FILE[:LINE[:COLUMN]]`. A file that exists under the whole argument
/// opens as itself, so a colon in a name stays part of the name; otherwise a
/// trailing `:LINE` or `:LINE:COLUMN` of positive numbers is the position.
/// Relative paths start at `cwd`; a leading `~` is `home`.
pub fn resolve(arg: &OsStr, cwd: &Path, home: Option<&Path>) -> Result<Target, String> {
    let shown = arg.to_string_lossy();
    let (path, line, column) = candidates(arg.as_bytes())
        .map(|(name, line, column)| (absolute(name, cwd, home), line, column))
        .find(|(path, _, _)| exists(path))
        .ok_or_else(|| format!("{shown}: no such file"))?;
    let path = fs::canonicalize(path).map_err(|error| format!("{shown}: {error}"))?;
    let metadata = fs::metadata(&path).map_err(|error| format!("{shown}: {error}"))?;
    if metadata.is_dir() {
        return Err(format!("{shown}: is a folder; dewline open takes files"));
    }
    if !metadata.is_file() {
        return Err(format!("{shown}: not a regular file"));
    }
    let path = path
        .into_os_string()
        .into_string()
        .map_err(|_| format!("{shown}: the path is not UTF-8"))?;
    Ok(Target { path, line, column })
}

type Candidate<'a> = (&'a [u8], Option<u32>, Option<u32>);

/// The readings of `arg`, keeping the most of it as the name first.
fn candidates(arg: &[u8]) -> impl Iterator<Item = Candidate<'_>> {
    let one = split_number(arg);
    let two = one.and_then(|(rest, column)| {
        split_number(rest).map(|(name, line)| (name, Some(line), Some(column)))
    });
    [
        Some((arg, None, None)),
        one.map(|(name, line)| (name, Some(line), None)),
        two,
    ]
    .into_iter()
    .flatten()
}

/// `name:12` as (`name`, 12), for a non-empty name and a number from 1 to u32::MAX.
fn split_number(arg: &[u8]) -> Option<(&[u8], u32)> {
    let colon = arg.iter().rposition(|&byte| byte == b':')?;
    let digits = &arg[colon + 1..];
    if colon == 0 || digits.is_empty() || !digits.iter().all(u8::is_ascii_digit) {
        return None;
    }
    let number: u32 = std::str::from_utf8(digits).ok()?.parse().ok()?;
    (number > 0).then_some((&arg[..colon], number))
}

fn absolute(name: &[u8], cwd: &Path, home: Option<&Path>) -> PathBuf {
    let path = Path::new(OsStr::from_bytes(name));
    match (path.strip_prefix("~"), home) {
        (Ok(rest), Some(home)) => home.join(rest),
        _ => cwd.join(path),
    }
}

/// A file the user can't read still exists, so its error names the real problem.
fn exists(path: &Path) -> bool {
    match fs::metadata(path) {
        Ok(_) => true,
        Err(error) => error.kind() == io::ErrorKind::PermissionDenied,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CString;
    use std::os::unix::fs::symlink;

    fn folder(files: &[&str]) -> tempfile::TempDir {
        let dir = tempfile::tempdir().unwrap();
        for file in files {
            let path = dir.path().join(file);
            fs::create_dir_all(path.parent().unwrap()).unwrap();
            fs::write(path, "# Plan\n").unwrap();
        }
        dir
    }

    fn real(path: &Path) -> String {
        fs::canonicalize(path)
            .unwrap()
            .into_os_string()
            .into_string()
            .unwrap()
    }

    fn at(arg: &str, cwd: &Path) -> Result<Target, String> {
        resolve(OsStr::new(arg), cwd, None)
    }

    fn target(path: &Path, line: Option<u32>, column: Option<u32>) -> Target {
        Target {
            path: real(path),
            line,
            column,
        }
    }

    #[test]
    fn relative_paths_start_at_the_current_folder() {
        let dir = folder(&["notes/plan.md"]);
        let file = dir.path().join("notes/plan.md");
        assert_eq!(
            at("notes/plan.md", dir.path()),
            Ok(target(&file, None, None))
        );
        assert_eq!(
            at("./notes/../notes/plan.md:3", dir.path()),
            Ok(target(&file, Some(3), None))
        );
        assert_eq!(
            at(&real(&file), Path::new("/")),
            Ok(target(&file, None, None))
        );
    }

    #[test]
    fn a_leading_tilde_is_home() {
        let dir = folder(&["plan.md", "~/plan.md"]);
        let plan = dir.path().join("plan.md");
        let from_home = |arg: &str| resolve(OsStr::new(arg), Path::new("/"), Some(dir.path()));
        assert_eq!(
            from_home("~/plan.md:2:5"),
            Ok(target(&plan, Some(2), Some(5)))
        );
        assert_eq!(
            from_home("~"),
            Err("~: is a folder; dewline open takes files".into())
        );
        // Only a whole first component is home; without a home the tilde is a name.
        assert_eq!(from_home("~plan.md"), Err("~plan.md: no such file".into()));
        let literal = resolve(OsStr::new("~/plan.md"), dir.path(), None);
        assert_eq!(
            literal,
            Ok(target(&dir.path().join("~/plan.md"), None, None))
        );
    }

    #[test]
    fn symlinks_open_their_target() {
        let dir = folder(&["real/plan.md"]);
        let plan = dir.path().join("real/plan.md");
        symlink(&plan, dir.path().join("link.md")).unwrap();
        symlink(dir.path().join("real"), dir.path().join("linked folder")).unwrap();
        assert_eq!(
            at("link.md:4", dir.path()),
            Ok(target(&plan, Some(4), None))
        );
        assert_eq!(
            at("linked folder/plan.md", dir.path()),
            Ok(target(&plan, None, None))
        );
        symlink("missing.md", dir.path().join("dangling.md")).unwrap();
        assert_eq!(
            at("dangling.md", dir.path()),
            Err("dangling.md: no such file".into())
        );
        symlink("loop.md", dir.path().join("loop.md")).unwrap();
        assert!(at("loop.md", dir.path()).is_err());
    }

    #[test]
    fn spaces_are_part_of_the_name() {
        let dir = folder(&["launch notes/my plan.md"]);
        let plan = dir.path().join("launch notes/my plan.md");
        assert_eq!(
            at("launch notes/my plan.md:12:3", dir.path()),
            Ok(target(&plan, Some(12), Some(3)))
        );
    }

    #[test]
    fn a_colon_in_a_name_wins_over_a_position() {
        let dir = folder(&["standup 10:30.md", "notes:12", "notes", "a:3"]);
        let standup = dir.path().join("standup 10:30.md");
        assert_eq!(
            at("standup 10:30.md", dir.path()),
            Ok(target(&standup, None, None))
        );
        assert_eq!(
            at("standup 10:30.md:7", dir.path()),
            Ok(target(&standup, Some(7), None))
        );
        assert_eq!(
            at("standup 10:30.md:7:2", dir.path()),
            Ok(target(&standup, Some(7), Some(2)))
        );
        assert_eq!(
            at("notes:12", dir.path()),
            Ok(target(&dir.path().join("notes:12"), None, None))
        );
        assert_eq!(
            at("notes:13", dir.path()),
            Ok(target(&dir.path().join("notes"), Some(13), None))
        );
        assert_eq!(
            at("a:3:4", dir.path()),
            Ok(target(&dir.path().join("a:3"), Some(4), None))
        );
    }

    #[test]
    fn positions_are_numbers_from_one() {
        let dir = folder(&["plan.md"]);
        for arg in [
            "plan.md:0",
            "plan.md:-1",
            "plan.md:+2",
            "plan.md:x",
            "plan.md:4294967296",
            "plan.md:",
        ] {
            assert_eq!(at(arg, dir.path()), Err(format!("{arg}: no such file")));
        }
        assert_eq!(
            at("plan.md:4294967295:1", dir.path()),
            Ok(target(&dir.path().join("plan.md"), Some(u32::MAX), Some(1)))
        );
        assert_eq!(at(":3", dir.path()), Err(":3: no such file".into()));
    }

    #[test]
    fn folders_and_special_files_are_refused() {
        let dir = folder(&["notes/plan.md"]);
        assert_eq!(
            at("notes", dir.path()),
            Err("notes: is a folder; dewline open takes files".into())
        );
        assert_eq!(
            at("missing.md:3", dir.path()),
            Err("missing.md:3: no such file".into())
        );
        let fifo = CString::new(
            dir.path()
                .join("pipe")
                .into_os_string()
                .into_string()
                .unwrap(),
        )
        .unwrap();
        // SAFETY: the path is a valid C string that outlives the call.
        assert_eq!(unsafe { libc::mkfifo(fifo.as_ptr(), 0o600) }, 0);
        assert_eq!(
            at("pipe", dir.path()),
            Err("pipe: not a regular file".into())
        );
        assert_eq!(
            at("/dev/null", dir.path()),
            Err("/dev/null: not a regular file".into())
        );
    }
}
