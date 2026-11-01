import SwiftUI

struct EditorPane: View {
    @Bindable var store: ThemeStore
    @AppStorage("DewlineMotion") private var motion = Motion.calm

    var body: some View {
        Form {
            Section {
                Toggle("Vim mode", isOn: $store.vimMode)
            } footer: {
                Text("Normal, insert and visual modes, with the mode at the window's lower right. :w saves and :q closes. Source mode is View > Show Source (⌥⌘U); General sets which mode windows open in.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                Picker("Heading style", selection: $store.headingStyle) {
                    Text("Standard").tag(ThemeStore.HeadingStyle.standard)
                    Text("Editorial").tag(ThemeStore.HeadingStyle.editorial)
                }
                Picker("Motion", selection: $motion) {
                    Text("Off").tag(Motion.off)
                    Text("Calm").tag(Motion.calm)
                    Text("Lively").tag(Motion.lively)
                }
            } header: {
                Text("Live rendering")
            } footer: {
                Text("Editorial sets the first heading as a display title and section heads in small caps; the file stays plain Markdown. Calm streaks the caret to where a jump such as Find Next lands; Lively does it for clicks and long moves too. With Reduce Motion on, Dewline uses Off.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                Picker("Tab key inserts", selection: $store.tabWidth) {
                    Text("A tab").tag(0)
                    Text("2 spaces").tag(2)
                    Text("4 spaces").tag(4)
                }
            } header: {
                Text("Indentation")
            } footer: {
                Text("In a list, Tab and Shift-Tab indent and outdent the item either way.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                Toggle("Check spelling as you type", isOn: $store.spellCheck)
                Toggle("Smart Punctuation", isOn: $store.smartPunctuation)
            } footer: {
                Text("Smart Punctuation turns straight quotes into curly ones and double hyphens into dashes as you type. Code is left alone.")
                    .frame(maxWidth: .infinity, alignment: .leading)
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
