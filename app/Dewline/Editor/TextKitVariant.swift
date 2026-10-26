import Foundation

/// The M0 spike's switch between the two TextKit stacks.
enum TextKitVariant: String, CaseIterable, Sendable {
    case textKit1 = "1"
    case textKit2 = "2"

    static var current: TextKitVariant {
        UserDefaults.standard.string(forKey: "DewlineTextKit").flatMap(TextKitVariant.init) ?? .textKit2
    }
}
