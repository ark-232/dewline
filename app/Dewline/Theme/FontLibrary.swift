import AppKit
import CoreText
import CryptoKit
import Observation

/// Dewline's own fonts (synthesis 2.9): catalog families in `<folder>/<family>/` and dropped files in
/// `<folder>/Added/`, registered for this process only. Nothing here writes to the system's font folders; Install for
/// All Apps hands the files to Font Book, which shows them and asks before installing.
@MainActor @Observable
final class FontLibrary {
    typealias Fetch = @Sendable (URL, Int, @escaping @MainActor @Sendable (Int) -> Void) async throws -> Data

    enum Failure: LocalizedError, Equatable {
        case mismatch
        case notFontFile(String)
        case notFont(String)
        case tooLarge(String)
        case wrongFamily(String)

        var errorDescription: String? {
            switch self {
            case .mismatch: "The download didn't match the catalog, so nothing was installed."
            case .notFontFile(let name): "\(name) isn't a .ttf, .otf or .ttc file."
            case .notFont(let name): "\(name) isn't a font Dewline can read."
            case .tooLarge(let name): "\(name) is over 50 MB."
            case .wrongFamily(let name): "\(name) isn't the family the catalog names, so nothing was installed."
            }
        }
    }

    /// What happened to one dropped file.
    enum Outcome: Equatable {
        case added(String)
        case alreadyAdded(String)
        case refused(String)
    }

    struct Added: Hashable {
        let url: URL
        let family: String
        let monospaced: Bool
    }

    static let shared = FontLibrary(folder: folder)

    /// ~/Library/Application Support/<bundle id>/Fonts.
    nonisolated static var folder: URL {
        URL.applicationSupportDirectory.appending(path: Bundle.main.bundleIdentifier ?? "dev.arkwerx.dewline").appending(path: "Fonts")
    }

    let folder: URL
    @ObservationIgnored private let fetch: Fetch
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    /// Catalog families on disk.
    private(set) var installed: Set<String> = []
    private(set) var added: [Added] = []
    /// Bytes received so far, by family, while its download runs.
    private(set) var progress: [String: Int] = [:]
    private(set) var failures: [String: String] = [:]

    init(folder: URL, fetch: @escaping Fetch = FontLibrary.download) {
        self.folder = folder
        self.fetch = fetch
        reload()
    }

    /// Families on this Mac apart from those only Dewline has, all and fixed-pitch; read once, for the pickers.
    @ObservationIgnored private(set) lazy var macFamilies: (all: [String], monospaced: [String]) = {
        let ours = Set(FontCatalog.families.map(\.name) + added.map(\.family)).filter { ownsEveryFace(of: $0) }
        return (Faces.installed(monospaced: false).filter { !ours.contains($0) }, Faces.installed(monospaced: true).filter { !ours.contains($0) })
    }()

    var addedFamilies: [String] {
        Array(Set(added.map(\.family))).sorted()
    }

    /// The font files Dewline keeps for `family`, from the catalog or dropped in.
    func fonts(of family: String) -> [URL] {
        installed.contains(family) ? Self.fontFiles(in: folder.appending(path: family)) : added.filter { $0.family == family }.map(\.url)
    }

    func reload() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        installed = Set(names.filter { $0 != "Added" && !$0.hasPrefix(".") })
        added = Self.fontFiles(in: folder.appending(path: "Added")).compactMap { url in
            guard let descriptor = (CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor])?.first,
                  let family = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String
            else { return nil }
            let traits = CTFontDescriptorCopyAttribute(descriptor, kCTFontTraitsAttribute) as? [String: Any]
            let symbolic = traits?[kCTFontSymbolicTrait as String] as? UInt32 ?? 0
            return Added(url: url, family: family, monospaced: symbolic & CTFontSymbolicTraits.traitMonoSpace.rawValue != 0)
        }
    }

    // MARK: Catalog

    /// Starts installing `family`, or returns the install already running; the row shows its progress and Stop.
    @discardableResult
    func startInstall(_ family: FontCatalog.Family) -> Task<Void, Never> {
        if let task = tasks[family.name] { return task }
        failures[family.name] = nil
        let task = Task {
            do {
                try await install(family)
            } catch is CancellationError {
            } catch let error as URLError where error.code == .cancelled {
            } catch let failure as Failure {
                failures[family.name] = failure.localizedDescription
            } catch {
                failures[family.name] = "The download failed. \(error.localizedDescription)"
            }
            tasks[family.name] = nil
        }
        tasks[family.name] = task
        return task
    }

    func stopInstall(_ family: FontCatalog.Family) {
        tasks[family.name]?.cancel()
    }

    /// Downloads every file of `family` into memory and checks its size and SHA-256 against the catalog; only when all
    /// match do the files reach the disk, in a temporary folder where CoreText must read each as the catalog's family,
    /// and from there they move into place in one step and register for this process.
    func install(_ family: FontCatalog.Family) async throws {
        progress[family.name] = 0
        defer { progress[family.name] = nil }
        var verified: [(name: String, data: Data)] = []
        var done = 0
        for file in family.files {
            let base = done
            let data = try await fetch(family.url(file), file.size) { [weak self] received in
                self?.progress[family.name] = base + received
            }
            try Task.checkCancellation()
            try Self.verify(data, against: file)
            verified.append((file.name, data))
            done += file.size
        }
        let manager = FileManager.default
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let staging = try manager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: folder, create: true)
        defer { try? manager.removeItem(at: staging) }
        let staged = staging.appending(path: family.name)
        try manager.createDirectory(at: staged, withIntermediateDirectories: false)
        for file in verified {
            try file.data.write(to: staged.appending(path: file.name))
        }
        for font in Self.fontFiles(in: staged) where Self.families(in: font) != [family.name] {
            throw Failure.wrongFamily(font.lastPathComponent)
        }
        let destination = folder.appending(path: family.name)
        if manager.fileExists(atPath: destination.path) {
            Self.unregister(Self.fontFiles(in: destination))
            try manager.removeItem(at: destination)
        }
        try manager.moveItem(at: staged, to: destination)
        Self.register(Self.fontFiles(in: destination))
        installed.insert(family.name)
    }

    /// Unregisters and deletes a catalog family or every dropped file of a family.
    func remove(_ family: String) throws {
        let fonts = fonts(of: family)
        Self.unregister(fonts)
        if installed.contains(family) {
            try FileManager.default.removeItem(at: folder.appending(path: family))
        } else {
            for font in fonts {
                try FileManager.default.removeItem(at: font)
            }
        }
        reload()
    }

    /// Hands the files to Font Book, which shows them and asks before installing them for every app.
    func installForAllApps(_ family: String) {
        guard let fontBook = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.FontBook") else { return }
        NSWorkspace.shared.open(fonts(of: family), withApplicationAt: fontBook, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: Dropped files

    /// Copies each font file into Added and registers it, skipping files already added; anything that isn't a font is
    /// refused with its name.
    func add(_ urls: [URL]) -> [Outcome] {
        let manager = FileManager.default
        let destinationFolder = folder.appending(path: "Added")
        var known = Dictionary(added.compactMap { font in (try? Data(contentsOf: font.url)).map { (Self.sha256($0), font.family) } }) { first, _ in first }
        var outcomes: [Outcome] = []
        for url in urls {
            do {
                let families = try Self.validate(url)
                let data = try Data(contentsOf: url)
                let hash = Self.sha256(data)
                if let family = known[hash] {
                    outcomes.append(.alreadyAdded(family))
                    continue
                }
                try manager.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
                var destination = destinationFolder.appending(path: url.lastPathComponent)
                var copy = 2
                while manager.fileExists(atPath: destination.path) {
                    destination = destinationFolder.appending(path: "\(url.deletingPathExtension().lastPathComponent) \(copy).\(url.pathExtension)")
                    copy += 1
                }
                try data.write(to: destination)
                Self.register([destination])
                known[hash] = families[0]
                outcomes.append(.added(families.joined(separator: ", ")))
            } catch {
                outcomes.append(.refused(error.localizedDescription))
            }
        }
        reload()
        return outcomes
    }

    /// The family names in a dropped file, or why it can't be added: not .ttf, .otf or .ttc, over 50 MB, no sfnt or
    /// collection header, or nothing CoreText can read.
    nonisolated static func validate(_ url: URL) throws -> [String] {
        let name = url.lastPathComponent
        guard isFontFile(url) else { throw Failure.notFontFile(name) }
        guard try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 <= 50 << 20 else { throw Failure.tooLarge(name) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let magic = try handle.read(upToCount: 4).map { Array($0) } ?? []
        let headers: [[UInt8]] = [[0, 1, 0, 0], Array("OTTO".utf8), Array("true".utf8), Array("ttcf".utf8)]
        let families = families(in: url)
        guard headers.contains(magic), !families.isEmpty else { throw Failure.notFont(name) }
        return families
    }

    // MARK: Files and registration

    /// Throws unless `data` is exactly the catalog's file.
    nonisolated static func verify(_ data: Data, against file: FontCatalog.File) throws {
        guard data.count == file.size, sha256(data) == file.sha256 else { throw Failure.mismatch }
    }

    nonisolated static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// An ephemeral session (no cookies, no cache) reading into memory, so nothing touches the disk before the hash is
    /// checked; a body longer than the catalog's size stops the download.
    nonisolated static func download(_ url: URL, size: Int, progress: @escaping @MainActor @Sendable (Int) -> Void) async throws -> Data {
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (bytes, response) = try await session.bytes(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        var data = Data(capacity: size)
        for try await byte in bytes {
            data.append(byte)
            guard data.count <= size else { throw Failure.mismatch }
            if data.count % 65_536 == 0 { await progress(data.count) }
        }
        await progress(data.count)
        return data
    }

    nonisolated static func isFontFile(_ url: URL) -> Bool {
        ["ttf", "otf", "ttc"].contains(url.pathExtension.lowercased())
    }

    nonisolated static func fontFiles(in folder: URL) -> [URL] {
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
        return files.filter(isFontFile).sorted { $0.path < $1.path }
    }

    nonisolated static func families(in font: URL) -> [String] {
        var names: [String] = []
        for descriptor in CTFontManagerCreateFontDescriptorsFromURL(font as CFURL) as? [CTFontDescriptor] ?? [] {
            if let name = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String, !names.contains(name) {
                names.append(name)
            }
        }
        return names
    }

    /// Whether every face CoreText has for `family` comes from this library's folder.
    func ownsEveryFace(of family: String) -> Bool {
        let root = folder.resolvingSymlinksInPath().path + "/"
        return Faces.faces(of: family).allSatisfy {
            (CTFontDescriptorCopyAttribute($0, kCTFontURLAttribute) as? URL)?.resolvingSymlinksInPath().path.hasPrefix(root) == true
        }
    }

    nonisolated static func register(_ fonts: [URL]) {
        guard !fonts.isEmpty else { return }
        CTFontManagerRegisterFontURLs(fonts as CFArray, .process, true) { _, _ in true }
    }

    nonisolated static func unregister(_ fonts: [URL]) {
        guard !fonts.isEmpty else { return }
        CTFontManagerUnregisterFontURLs(fonts as CFArray, .process) { _, _ in true }
    }

    // MARK: Launch

    nonisolated private static let launch = DispatchGroup()

    /// Registers the folder's fonts for this process on a background queue, from main(). The test host skips it, so
    /// tests never read the real folder.
    nonisolated static func registerAtLaunch() {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        launch.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            register(fontFiles(in: folder))
            launch.leave()
        }
    }

    /// Returns once the launch registration is done, so the saved faces resolve; it has usually finished by the time
    /// the first window asks.
    nonisolated static func waitForLaunchRegistration() {
        launch.wait()
    }
}
