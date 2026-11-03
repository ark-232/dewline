import AppKit
import CryptoKit
import ImageIO
import LinkPresentation
import UniformTypeIdentifiers

/// What a web page says about itself for a preview: its title, its picture and its icon, each picture downscaled and
/// encoded as JPEG or PNG. Empty when the fetch failed.
struct LinkPage: Codable, Equatable, Sendable {
    var title: String?
    var image: Data?
    var icon: Data?
}

/// Where pages come from: LinkPresentation in the app, a stub in tests.
protocol LinkPageFetching: Sendable {
    /// The page at `url`, or nil when it cannot be read within the timeout.
    func fetch(_ url: URL) async -> LinkPage?
}

/// A link's card: the page's title, picture and icon, or the host alone while the page loads or after it fails.
struct LinkPreview {
    let url: URL
    let title: String?
    let image: NSImage?
    let icon: NSImage?

    init(url: URL, page: LinkPage = LinkPage()) {
        self.url = url
        title = page.title.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        image = page.image.flatMap(NSImage.init(data:))
        icon = page.icon.flatMap(NSImage.init(data:))
    }

    /// The host without `www.`.
    var host: String {
        let host = url.host(percentEncoded: false) ?? url.absoluteString
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    var isLoaded: Bool {
        title != nil || image != nil || icon != nil
    }
}

/// Link previews: which addresses may be fetched, the fetches themselves, one at a time per address, and the cache,
/// kept for the session in memory and for 7 days on disk. Off in Settings > Editor > Link previews, nothing is
/// fetched or shown and the disk cache goes.
@MainActor
final class LinkPreviews {
    static let shared: LinkPreviews = {
        // The test host never reaches the network or the user's cache.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
            return LinkPreviews(defaults: .standard, folder: nil, fetcher: nil)
        }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return LinkPreviews(
            defaults: .standard, folder: caches.appending(path: "dev.arkwerx.dewline/LinkPreviews", directoryHint: .isDirectory),
            fetcher: LinkPresentationFetcher()
        )
    }()

    /// The Settings switch, on unless set false.
    static let defaultsKey = "DewlineLinkPreviews"
    /// Posted when previews turn on or off, and when a page arrives (`object` is its URL).
    static let didChange = Notification.Name("DewlineLinkPreviewsDidChange")
    static let lifetime: TimeInterval = 7 * 24 * 3600
    static let diskBudget = 50 << 20
    private static let sessionLimit = 256

    let folder: URL?
    private let defaults: UserDefaults
    private let fetcher: (any LinkPageFetching)?
    private var loaded: [URL: LinkPreview] = [:]
    private var loading: Set<URL> = []
    private(set) var isOn: Bool

    init(defaults: UserDefaults, folder: URL?, fetcher: (any LinkPageFetching)?) {
        self.defaults = defaults
        self.folder = folder
        self.fetcher = fetcher
        isOn = Self.isOn(defaults)
        NotificationCenter.default.addObserver(self, selector: #selector(defaultsDidChange), name: UserDefaults.didChangeNotification, object: defaults)
    }

    static func isOn(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: defaultsKey) as? Bool ?? true
    }

    @objc private func defaultsDidChange() {
        let on = Self.isOn(defaults)
        guard on != isOn else { return }
        isOn = on
        if !on {
            loaded = [:]
            loading = []
            if let folder { try? FileManager.default.removeItem(at: folder) }
        }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// The preview already in hand for `url`, without fetching.
    func cached(_ url: URL) -> LinkPreview? {
        isOn ? loaded[url] : nil
    }

    /// The preview for `url`: from memory, from disk, or nil while a fetch runs, which posts `didChange` when it ends.
    /// Nil for an address previews never fetch.
    @discardableResult
    func metadata(for url: URL) -> LinkPreview? {
        guard isOn, Self.allows(url) else { return nil }
        if let preview = loaded[url] { return preview }
        guard !loading.contains(url) else { return nil }
        if let page = read(url) {
            keep(LinkPreview(url: url, page: page))
            return loaded[url]
        }
        guard let fetcher else {
            keep(LinkPreview(url: url))
            return loaded[url]
        }
        loading.insert(url)
        Task { [weak self] in
            let page = await fetcher.fetch(url)
            self?.received(page, for: url)
        }
        return nil
    }

    private func received(_ page: LinkPage?, for url: URL) {
        guard loading.remove(url) != nil, isOn else { return }
        keep(LinkPreview(url: url, page: page ?? LinkPage()))
        if let page { write(page, for: url) }
        NotificationCenter.default.post(name: Self.didChange, object: url)
    }

    private func keep(_ preview: LinkPreview) {
        if loaded.count >= Self.sessionLimit { loaded = [:] }
        loaded[preview.url] = preview
    }
}

extension LinkPreviews {
    /// The cache file for `url`: the SHA-256 of its address.
    func file(for url: URL) -> URL? {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return folder?.appending(path: digest + ".plist")
    }

    /// The page cached for `url` within the last 7 days; an older file is removed.
    private func read(_ url: URL) -> LinkPage? {
        guard let file = file(for: url), let written = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        else { return nil }
        guard Date().timeIntervalSince(written) < Self.lifetime else {
            try? FileManager.default.removeItem(at: file)
            return nil
        }
        return (try? Data(contentsOf: file)).flatMap { try? PropertyListDecoder().decode(LinkPage.self, from: $0) }
    }

    /// Writes `page`, then removes expired files and the oldest ones past 50 MB.
    private func write(_ page: LinkPage, for url: URL) {
        guard let folder, let file = file(for: url), let data = try? PropertyListEncoder().encode(page) else { return }
        let manager = FileManager.default
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? data.write(to: file, options: .atomic)
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        let files = ((try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys))) ?? []).compactMap { file in
            (try? file.resourceValues(forKeys: keys)).map { (file, $0.contentModificationDate ?? .distantPast, $0.fileSize ?? 0) }
        }.sorted { $0.1 > $1.1 }
        var total = 0
        for (file, written, size) in files {
            total += size
            if total > Self.diskBudget || Date().timeIntervalSince(written) >= Self.lifetime { try? manager.removeItem(at: file) }
        }
    }
}

extension LinkPreviews {
    /// Whether previews may fetch `url`: an http or https address with a public host and no user or password. Refused:
    /// `localhost`, names under `.localhost` or `.local`, names with no dot, and loopback, private, link-local,
    /// shared and multicast IP addresses, IPv4 in any of the forms a browser reads (`127.1`, `0x7f000001`).
    nonisolated static func allows(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.user == nil, url.password == nil,
            var host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty
        else { return false }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        while host.hasSuffix(".") { host.removeLast() }
        if host.contains(":") { return isPublic(ipv6: host) }
        var ipv4 = in_addr()
        if inet_aton(host, &ipv4) != 0 { return isPublic(ipv4: UInt32(bigEndian: ipv4.s_addr)) }
        // A name of digits and dots that is no address is still read as one by some resolvers.
        if host.allSatisfy({ $0.isNumber || $0 == "." || $0 == "x" }) { return false }
        return host.contains(".") && host != "localhost" && !host.hasSuffix(".localhost") && !host.hasSuffix(".local")
    }

    private nonisolated static func isPublic(ipv4 address: UInt32) -> Bool {
        let refused: [(UInt32, UInt32)] = [
            (0x0000_0000, 8), (0x0A00_0000, 8), (0x6440_0000, 10), (0x7F00_0000, 8), (0xA9FE_0000, 16),
            (0xAC10_0000, 12), (0xC000_0000, 24), (0xC0A8_0000, 16), (0xC612_0000, 15), (0xE000_0000, 3),
        ]
        return !refused.contains { network, bits in address >> (32 - bits) == network >> (32 - bits) }
    }

    private nonisolated static func isPublic(ipv6 host: String) -> Bool {
        var address = in6_addr()
        guard inet_pton(AF_INET6, host, &address) == 1 else { return false }
        let bytes = withUnsafeBytes(of: &address) { Array($0) }
        let v4 = bytes[12...].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        // IPv4-mapped, IPv4-compatible and NAT64 addresses carry an IPv4 address in their last four bytes.
        if bytes[..<10].allSatisfy({ $0 == 0 }) && (bytes[10..<12].allSatisfy { $0 == 0xFF } || bytes[10..<12].allSatisfy { $0 == 0 }) {
            return isPublic(ipv4: v4)
        }
        if bytes[..<12] == [0, 0x64, 0xFF, 0x9B, 0, 0, 0, 0, 0, 0, 0, 0] { return isPublic(ipv4: v4) }
        // Unique local fc00::/7, link-local and site-local fe80::/9, multicast ff00::/8.
        return bytes[0] & 0xFE != 0xFC && !(bytes[0] == 0xFE && bytes[1] & 0x80 == 0x80) && bytes[0] != 0xFF
    }
}

/// Reads pages with LinkPresentation, 10 seconds at most, and keeps the picture at 960 pixels wide or less and the icon
/// at 64.
struct LinkPresentationFetcher: LinkPageFetching {
    func fetch(_ url: URL) async -> LinkPage? {
        let provider = LPMetadataProvider()
        provider.timeout = 10
        guard let metadata = try? await provider.startFetchingMetadata(for: url) else { return nil }
        let image = await Self.data(metadata.imageProvider, longest: 960, as: .jpeg)
        let icon = await Self.data(metadata.iconProvider, longest: 64, as: .png)
        return LinkPage(title: metadata.title, image: image, icon: icon)
    }

    private static func data(_ provider: NSItemProvider?, longest: Int, as type: UTType) async -> Data? {
        guard let provider, provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) else { return nil }
        let data: Data? = await withCheckedContinuation { done in
            _ = provider.loadDataRepresentation(for: .image) { data, _ in done.resume(returning: data) }
        }
        guard let data, let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: longest,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ] as CFDictionary)
        else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}
