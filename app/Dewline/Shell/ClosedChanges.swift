import Foundation
import MdCore
import os

/// Files an agent wrote while no tab had them open (B5). Opening one lands the write as marked changes against the
/// bytes it replaced, so it reviews like a change to an open file.
@MainActor
enum ClosedChanges {
    /// The engine the app's documents open through; tests pass their own.
    static var engine: ChangeEngine? = MarkdownDocument.sharedEngine

    /// `writer` is about to write the file at `url`, which holds `before`: the agent panel calls this before its write
    /// to a closed note; hooked agents' writes are kept from their PreToolUse claims.
    static func record(path url: URL, writer: ChangeEngine.Origin, before: Data) {
        do throws(ChangeEngine.Failure) {
            try engine?.closedWrite(url, origin: writer, before: before)
        } catch {
            Logger(subsystem: "dev.arkwerx.dewline", category: "engine")
                .error("A closed file's write was not kept: \(String(describing: error), privacy: .public)")
        }
    }

    /// Changed while closed, oldest first: each file, who wrote it, and when.
    static var all: [ChangeEngine.ClosedChange] {
        engine?.closedChanges() ?? []
    }
}
