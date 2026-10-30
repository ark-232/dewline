import SwiftUI

struct EditorPane: View {
    @Bindable var store: ThemeStore

    var body: some View {
        Form {
            Section {
                LabeledContent("Text size") {
                    Stepper(value: $store.bodySize, in: ThemeStore.bodySizes, step: 1) {
                        Text("\(Int(store.bodySize)) pt").monospacedDigit()
                    }
                    .accessibilityLabel("Text size")
                    .accessibilityValue("\(Int(store.bodySize)) points")
                }
                LabeledContent("Line height") {
                    HStack(spacing: 10) {
                        Slider(value: Binding { store.lineHeight } set: { store.lineHeight = ($0 * 100).rounded() / 100 }, in: ThemeStore.lineHeights) {
                            EmptyView()
                        } minimumValueLabel: {
                            Text("Tight")
                        } maximumValueLabel: {
                            Text("Loose")
                        }
                        .accessibilityLabel("Line height")
                        .accessibilityValue(store.lineHeight.formatted(.number.precision(.fractionLength(2))))
                        Text(store.lineHeight, format: .number.precision(.fractionLength(2)))
                            .monospacedDigit()
                            .frame(width: 34, alignment: .trailing)
                    }
                    .frame(width: 300)
                }
                LabeledContent("Line width") {
                    HStack(spacing: 10) {
                        Slider(value: Binding { store.columnWidth } set: { store.columnWidth = $0.rounded() }, in: ThemeStore.columnWidths) {
                            EmptyView()
                        } minimumValueLabel: {
                            Text("50")
                        } maximumValueLabel: {
                            Text("90")
                        }
                        .accessibilityLabel("Line width")
                        .accessibilityValue("\(Int(store.columnWidth)) characters")
                        Text("\(Int(store.columnWidth)) characters")
                            .monospacedDigit()
                            .frame(width: 92, alignment: .trailing)
                    }
                    .frame(width: 358)
                }
            } footer: {
                Text("Line width counts characters per line at this size; a narrower window fills its width.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                Picker("Heading style", selection: $store.headingStyle) {
                    Text("Standard").tag(ThemeStore.HeadingStyle.standard)
                    Text("Editorial").tag(ThemeStore.HeadingStyle.editorial)
                }
            } footer: {
                Text("Editorial sets the first heading as a display title and section heads in small caps. The file stays plain Markdown.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                Toggle("Smart Punctuation", isOn: $store.smartPunctuation)
            } footer: {
                Text("Turns straight quotes into curly ones and double hyphens into dashes as you type. Code is left alone.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
