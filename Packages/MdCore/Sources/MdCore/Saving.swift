internal import DewlineFFIBindings
import Foundation

/// Why a save wrote nothing.
public enum SaveFailure: Error, Sendable, Equatable {
    /// The file no longer holds the bytes the save was based on, or is gone.
    case conflict
    case io(String)
}

/// The BLAKE3 hash of `bytes`, which a save compares with the file's.
public func contentHash(_ bytes: Data) -> Data {
    hash(bytes: bytes)
}

/// Writes `bytes` to the file at `url` if it still holds the bytes `base` hashes, and returns
/// their hash. Bytes that hash to `base` write nothing. Another app's version that the save
/// takes off the disk goes into the snapshot store at `snapshots`.
public func saveFile(_ bytes: Data, to url: URL, base: Data, snapshots: URL) throws(SaveFailure) -> Data {
    do {
        return try save(path: url.path, base: base, bytes: bytes, snapshots: snapshots.path)
    } catch SaveError.Conflict {
        throw .conflict
    } catch SaveError.Io(let message) {
        throw .io(message)
    } catch {
        throw .io("\(error)")
    }
}
