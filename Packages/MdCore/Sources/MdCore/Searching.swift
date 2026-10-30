internal import DewlineFFIBindings
import Foundation

/// A match of a plain-text search. Ranges count UTF-16 code units, as NSString does: `range` in the file's text after
/// any byte-order mark, `previewRange` in `preview`.
public struct TextMatch: Sendable, Equatable {
    /// Counted from 1.
    public let line: Int
    public let range: NSRange
    /// The line around the match, with "…" where it was cut.
    public let preview: String
    public let previewRange: NSRange
}

public struct FileMatches: Sendable {
    public let url: URL
    public let matches: [TextMatch]
}

public struct SearchOptions: Sendable, Equatable {
    public var matchCase: Bool
    public var wholeWord: Bool

    public init(matchCase: Bool = false, wholeWord: Bool = false) {
        self.matchCase = matchCase
        self.wholeWord = wholeWord
    }
}

/// The matches of `query` in `files`, searched in order, for each file that has one. The search stops after `limit`
/// matches, and `stopped` says matches were left. Without `matchCase` letters match in any case; with `wholeWord` a
/// match starts and ends at word boundaries, and Han and kana characters are words on their own. Files over 64 MB,
/// files that aren't UTF-8 and files that can't be read are skipped.
public func textMatches(of query: String, in files: [URL], options: SearchOptions, limit: Int)
    -> (files: [FileMatches], stopped: Bool)
{
    let found = searchFiles(
        paths: files.map(\.path), query: query, matchCase: options.matchCase, wholeWord: options.wholeWord,
        limit: UInt32(clamping: limit)
    )
    let matches = found.files.map { file in
        FileMatches(url: files[Int(file.file)], matches: file.matches.map { match in
            TextMatch(
                line: Int(match.line),
                range: NSRange(location: Int(match.start), length: Int(match.end - match.start)),
                preview: match.preview,
                previewRange: NSRange(location: Int(match.previewStart), length: Int(match.previewEnd - match.previewStart))
            )
        })
    }
    return (matches, found.stopped)
}
