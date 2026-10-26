use std::path::Path;

use dewline_core::file;
use dewline_core::store::Store;

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum SaveError {
    #[error("the file changed after it was read")]
    Conflict,
    #[error("{message}")]
    Io { message: String },
}

/// The BLAKE3 hash of `bytes`.
#[uniffi::export]
pub fn hash(bytes: Vec<u8>) -> Vec<u8> {
    file::hash(&bytes).as_bytes().to_vec()
}

/// Writes `bytes` to `path` if the file still holds the bytes `base` hashes,
/// and returns their hash. Bytes that hash to `base` write nothing. Another
/// app's version that the save takes off the disk goes into the snapshot
/// store at `snapshots`.
#[uniffi::export]
pub fn save(
    path: String,
    base: Vec<u8>,
    bytes: Vec<u8>,
    snapshots: String,
) -> Result<Vec<u8>, SaveError> {
    // A base that is not a hash matches no file.
    let base = file::Hash::from_slice(&base).map_err(|_| SaveError::Conflict)?;
    let io = |error: std::io::Error| SaveError::Io {
        message: error.to_string(),
    };
    let store = Store::open(Path::new(&snapshots)).map_err(io)?;
    match file::save(Path::new(&path), &base, &bytes, &store) {
        Ok(hash) => Ok(hash.as_bytes().to_vec()),
        Err(file::SaveError::Conflict | file::SaveError::Raced(_)) => Err(SaveError::Conflict),
        Err(file::SaveError::Io(error)) => Err(io(error)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn saves_against_a_hash_and_refuses_a_stale_one() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("notes.md");
        std::fs::write(&path, "# Notes\r\n").unwrap();
        let base = hash(b"# Notes\r\n".to_vec());
        let path = path.to_str().unwrap().to_owned();
        let snapshots = dir.path().join("snapshots").to_str().unwrap().to_owned();
        let new = save(
            path.clone(),
            base.clone(),
            b"# My notes\r\n".to_vec(),
            snapshots.clone(),
        )
        .unwrap();
        assert_eq!(new, hash(b"# My notes\r\n".to_vec()));
        assert!(matches!(
            save(
                path.clone(),
                base,
                b"# Ours\r\n".to_vec(),
                snapshots.clone()
            ),
            Err(SaveError::Conflict)
        ));
        assert!(matches!(
            save(path, vec![0; 3], b"# Ours\r\n".to_vec(), snapshots),
            Err(SaveError::Conflict)
        ));
    }
}
