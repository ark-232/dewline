import AppKit
import MdCore
import Testing
@testable import Dewline

/// What an open document adds to the footprint once idle, opened as the app opens it: through a change engine, with
/// its file's URL, in a tab of its own, idle once styled and its words counted. It waits by suspending, so the main
/// actor's tasks run as they do in the app. Runs only with `DEWLINE_PERF` set (`TEST_RUNNER_DEWLINE_PERF=1` through
/// xcodebuild); `DEWLINE_MEMORY_MB` picks one size, in a process of its own, since a closed document's text system
/// stays alive for a while; with `DEWLINE_MEMORY_HOLD` set to seconds, it prints the process and waits that long while
/// idle, for `footprint` or `vmmap`. The corpus is built once into the temporary folder: freed memory from building it
/// would otherwise be counted before the document opens, and malloc reuses it while the document opens.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["DEWLINE_PERF"] != nil))
struct MemoryMeasurements {
    nonisolated static let sizes = ProcessInfo.processInfo.environment["DEWLINE_MEMORY_MB"].flatMap(Int.init).map { [$0 << 20] } ?? [1 << 20, 10 << 20]

    @Test(arguments: sizes)
    func idle(bytes: Int) async throws {
        let corpus = FileManager.default.temporaryDirectory.appending(path: "dewline-memory-\(bytes).md")
        if !FileManager.default.fileExists(atPath: corpus.path) {
            try autoreleasepool { try Data(MarkdownCorpus.text(bytes: bytes).utf8).write(to: corpus) }
        }
        let folder = FileManager.default.temporaryDirectory.appending(path: "dewline-memory-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "corpus.md")
        try FileManager.default.copyItem(at: corpus, to: url)
        let engine = try ChangeEngine(store: folder.appending(path: "snapshots"))
        try await Task.sleep(for: .seconds(1))
        let before = SourceModeMeasurements.footprint()

        let document = MarkdownDocument()
        document.engine = engine
        try document.read(from: url, ofType: MarkdownDocument.type)
        document.fileURL = url
        document.makeWindowControllers()
        document.showWindows()
        let view = try #require(document.textView)
        let deadline = Date(timeIntervalSinceNow: 60)
        while (view.styler.hasUnstyledText || view.window?.subtitle.isEmpty == true) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!view.styler.hasUnstyledText)
        print(String(format: "MEMORY %d MB: styled and counted in %.1f s", bytes >> 20, 60 - deadline.timeIntervalSinceNow))
        try await Task.sleep(for: .seconds(3))
        let idle = SourceModeMeasurements.footprint()
        print(String(format: "MEMORY %d MB: phys_footprint %.1f MB before opening, %.1f MB idle, +%.1f MB", bytes >> 20, before, idle, idle - before))
        if let hold = ProcessInfo.processInfo.environment["DEWLINE_MEMORY_HOLD"].flatMap(Double.init), hold > 0 {
            print("MEMORY hold pid \(getpid()) for \(hold) s")
            try await Task.sleep(for: .seconds(hold))
        }
        document.close()
        try await Task.sleep(for: .seconds(1))
    }
}
