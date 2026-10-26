import AppKit
import MdCore
import Testing
@testable import Dewline

/// Renders `corpus/mermaid` and `corpus/math` through the editor's renderers, both math engines included. Runs
/// only with `DEWLINE_CORPUS_OUT` set (`TEST_RUNNER_DEWLINE_CORPUS_OUT` through xcodebuild) and writes every
/// picture there with `mermaid.json` and `math-<engine>.json`. Timings mean something in a Release build.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["DEWLINE_CORPUS_OUT"] != nil))
struct BlockCorpusTests {
    static let corpus = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "corpus")
    static let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DEWLINE_CORPUS_OUT"] ?? "")

    /// Milliseconds to the finished picture, and the picture or why there is none.
    static func render(_ request: PictureRequest) -> (milliseconds: Double, picture: Result<BlockPicture, RenderFailure>) {
        let start = ContinuousClock.now
        let picture = request.render(width: 702)
        return ((ContinuousClock.now - start) / .milliseconds(1), picture)
    }

    static func save(_ picture: BlockPicture, as name: String) throws {
        let file: URL = out.appending(path: name)
        let destination = try #require(CGImageDestinationCreateWithURL(file as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, picture.image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    static func save(_ json: Any, as name: String) throws {
        try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(to: out.appending(path: name))
    }

    @Test func mermaid() throws {
        let files = try FileManager.default.contentsOfDirectory(at: Self.corpus.appending(path: "mermaid"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "mmd" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        #expect(files.count == 50)
        var results: [[String: Any]] = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            var frontmatter = false
            let header = source.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { line in
                frontmatter = frontmatter != (line == "---")
                return !frontmatter && !line.isEmpty && line != "---" && !line.hasPrefix("%%")
            }
            let name = file.deletingPathExtension().lastPathComponent
            let (milliseconds, picture) = Self.render(PictureRequest(kind: .mermaid, source: source, scale: 2, color: 0, engine: .raTeX))
            var result: [String: Any] = ["file": name, "header": header ?? "", "ms": milliseconds]
            switch picture {
            case .success(let picture):
                try Self.save(picture, as: "\(name).png")
                result["points"] = [picture.size.width, picture.size.height]
            case .failure(let failure):
                result["error"] = failure.reason
            }
            results.append(result)
        }
        try Self.save(results, as: "mermaid.json")
    }

    @Test(arguments: MathEngine.allCases)
    func math(_ engine: MathEngine) throws {
        let formulas = try String(contentsOf: Self.corpus.appending(path: "math/formulas.tex"), encoding: .utf8)
            .split(whereSeparator: \.isNewline).map(String.init)
        #expect(formulas.count == 50)
        let request = { (tex: String) in PictureRequest(kind: .math, source: tex, scale: 2, color: 0x0000_00FF, engine: engine) }
        let cold = Self.render(request("x")).milliseconds
        var results: [[String: Any]] = []
        var times: [Double] = []
        for (index, tex) in formulas.enumerated() {
            let runs = (0..<5).map { _ in Self.render(request(tex)) }
            let milliseconds = runs.map(\.milliseconds).sorted()[2]
            var result: [String: Any] = ["line": index + 1, "tex": tex, "ms": milliseconds]
            switch runs[0].picture {
            case .success(let picture):
                try Self.save(picture, as: "math-\(engine.rawValue)-\(index + 1).png")
                result["points"] = [picture.size.width, picture.size.height]
                times.append(milliseconds)
            case .failure(let failure):
                result["error"] = failure.reason
            }
            results.append(result)
        }
        times.sort()
        try Self.save([
            "engine": engine.rawValue, "coldMs": cold, "failures": formulas.count - times.count,
            "p50Ms": times.isEmpty ? 0 : times[(times.count + 1) / 2 - 1], "maxMs": times.last ?? 0, "formulas": results,
        ] as [String: Any], as: "math-\(engine.rawValue).json")
    }
}
