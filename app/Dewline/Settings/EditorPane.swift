import SwiftUI

struct EditorPane: View {
    @Bindable var store: ThemeStore
    @AppStorage("DewlineMotion") private var motion = Motion.calm

    var body: some View {
        SettingsPage {
            SettingsSection(note: "Normal, insert and visual modes, with the mode at the window's lower right. :w saves and :q closes. Source mode is View > Show Source (⌥⌘U); General sets which mode windows open in.") {
                SettingsRow(label: "Vim mode") {
                    OnOff(label: "Vim mode", isOn: $store.vimMode)
                }
            }
            SettingsSection(title: "Live rendering", note: "Editorial sets the first heading as a display title and section heads in small caps; the file stays plain Markdown. Calm streaks the caret to where a jump such as Find Next lands; Lively does it for clicks and long moves too. With Reduce Motion on, Dewline uses Off.") {
                SettingsRow(label: "Heading style") {
                    TextChoice(label: "Heading style", selection: $store.headingStyle, options: [("Standard", .standard), ("Editorial", .editorial)])
                }
                SettingsRow(label: "Motion") {
                    TextChoice(label: "Motion", selection: $motion, options: [("Off", .off), ("Calm", .calm), ("Lively", .lively)])
                }
            }
            SettingsSection(title: "Indentation", note: "In a list, Tab and Shift-Tab indent and outdent the item either way.") {
                SettingsRow(label: "Tab key inserts") {
                    TextChoice(label: "Tab key inserts", selection: $store.tabWidth, options: [("A tab", 0), ("2 spaces", 2), ("4 spaces", 4)])
                }
            }
            SettingsSection(title: "Typing", note: "Smart Punctuation turns straight quotes into curly ones and double hyphens into dashes as you type. Code is left alone.") {
                SettingsRow(label: "Check spelling as you type") {
                    OnOff(label: "Check spelling as you type", isOn: $store.spellCheck)
                }
                SettingsRow(label: "Smart Punctuation") {
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
                motion = .calm
            }
        }
    }
}
