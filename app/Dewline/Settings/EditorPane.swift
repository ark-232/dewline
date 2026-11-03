import SwiftUI

struct EditorPane: View {
    @Bindable var store: ThemeStore
    @Bindable var preferences: Preferences = .shared
    @AppStorage("DewlineMotion") private var motion = Motion.calm

    var body: some View {
        SettingsPage {
            SettingsSection {
                SettingsRow(label: "Link previews", detail: "Fetches a page's title and picture when a link is shown.") {
                    OnOff(label: "Link previews", isOn: $preferences.linkPreviews)
                }
                SettingsRow(label: "Vim mode") {
                    OnOff(label: "Vim mode", isOn: $store.vimMode)
                }
            }
            SettingsSection(title: "Live rendering") {
                SettingsRow(label: "Heading style", detail: "Editorial sets section heads in small caps.") {
                    TextChoice(label: "Heading style", selection: $store.headingStyle, options: [("Standard", .standard), ("Editorial", .editorial)])
                }
                SettingsRow(label: "Motion", detail: "Reduce Motion in System Settings turns it off.") {
                    TextChoice(label: "Motion", selection: $motion, options: [("Off", .off), ("Calm", .calm), ("Lively", .lively)])
                }
                SettingsRow(label: "Tab key inserts") {
                    TextChoice(label: "Tab key inserts", selection: $store.tabWidth, options: [("A tab", 0), ("2 spaces", 2), ("4 spaces", 4)])
                }
            }
            SettingsSection(title: "Typing") {
                SettingsRow(label: "Check spelling as you type") {
                    OnOff(label: "Check spelling as you type", isOn: $store.spellCheck)
                }
                SettingsRow(label: "Smart Punctuation", detail: "Curly quotes and dashes as you type, outside code.") {
                    OnOff(label: "Smart Punctuation", isOn: $store.smartPunctuation)
                }
            }
            RestoreDefaults {
                let factory = ThemeStore.factory
                store.vimMode = factory.vimMode
                store.headingStyle = factory.headingStyle
                store.tabWidth = factory.tabWidth
                store.spellCheck = factory.spellCheck
                store.smartPunctuation = factory.smartPunctuation
                preferences.linkPreviews = Preferences.factory.linkPreviews
                motion = .calm
            }
        }
    }
}
