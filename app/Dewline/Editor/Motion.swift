import AppKit

/// The Motion setting, the user default `DewlineMotion`. Reduce Motion runs Off; Low Power Mode runs Lively as Calm.
enum Motion: String {
    case off, calm, lively

    /// Read when an effect starts, so a change to the setting or to the system applies without a relaunch.
    @MainActor
    static var current: Motion {
        resolve(
            UserDefaults.standard.string(forKey: "DewlineMotion").flatMap(Motion.init) ?? .calm,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
    }

    static func resolve(_ setting: Motion, reduceMotion: Bool, lowPower: Bool) -> Motion {
        if reduceMotion { return .off }
        return setting == .lively && lowPower ? .calm : setting
    }
}
