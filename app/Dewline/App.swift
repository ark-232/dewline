import AppKit

@main
@MainActor
enum DewlineApp {
    static func main() {
        // mermaid-rs-renderer copies a system font into XDG_CACHE_HOME, or into ~/.cache without it.
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        setenv("XDG_CACHE_HOME", caches.appending(path: "dev.arkwerx.dewline").path, 1)
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.mainMenu = MainMenu.build()
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
