internal import DewlineFFIBindings
import Foundation

/// One instruction file an agent loads in a folder, with a bytes/4 token estimate.
public struct LoadedAgentFile: Sendable {
    public let agent: String
    public let path: String
    /// "walk", "@import from CLAUDE.md", or a Cursor rule's trigger.
    public let how: String
    public let tokens: UInt64
    public let limit: UInt64?
}

/// What Claude Code, Codex and Cursor load for a session started in `folder`.
public func agentFilesLoaded(in folder: String, home: String?) -> [LoadedAgentFile] {
    whatLoads(folder: folder, home: home).map {
        LoadedAgentFile(agent: $0.agent, path: $0.path, how: $0.how, tokens: $0.tokens, limit: $0.limit)
    }
}

/// The day the agents' load limits were last checked, YYYY-MM-DD.
public func agentLoadLimitsDate() -> String {
    loadLimitsDate()
}

/// A sibling instruction file whose sections differ from `other`'s.
public struct SiblingDifference: Sendable {
    public let path: String
    public let other: String
    public let sections: [String]
}

public func siblingDifferences(in folder: String) -> [SiblingDifference] {
    siblingDivergence(folder: folder).map { SiblingDifference(path: $0.path, other: $0.other, sections: $0.sections) }
}

/// Agent-written memory and plan files, newest first, with when each changed in seconds since 1970.
public func agentReviewFiles(home: String?, folder: String?) -> [(path: String, modified: Double)] {
    reviewFiles(home: home, folder: folder).map { ($0.path, $0.modified) }
}

/// A broken link or import, in UTF-16 offsets.
public struct BrokenTarget: Sendable {
    public let range: NSRange
    public let target: String
    public let problem: String
}

/// The broken relative links and CLAUDE.md `@imports` of `text`, the file at `path`.
public func brokenTargets(in text: String, path: String, home: String?) -> [BrokenTarget] {
    brokenLinks(path: path, text: text, home: home).map {
        BrokenTarget(range: NSRange(location: Int($0.location), length: Int($0.length)), target: $0.target, problem: $0.problem)
    }
}
