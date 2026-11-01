import AppKit
import SwiftUI

/// The Station chrome's colors and faces for the SwiftUI Settings panes.
@MainActor
enum Station {
    /// The theme's color for `token`. It reads both theme slots first, so a view that draws with it redraws when
    /// either slot changes.
    static func color(_ token: Token) -> Color {
        let store = ThemeStore.shared
        _ = (store.lightTheme, store.darkTheme)
        return Color(nsColor: store.color(token))
    }

    static var wash: Color {
        _ = (ThemeStore.shared.lightTheme, ThemeStore.shared.darkTheme)
        return Color(nsColor: Chrome.wash)
    }

    static var stroke: Color {
        _ = (ThemeStore.shared.lightTheme, ThemeStore.shared.darkTheme)
        return Color(nsColor: Chrome.strokeSubtle)
    }

    static func brand(_ size: CGFloat, weight: CGFloat = 450) -> Font {
        Font(Chrome.brand(size, weight: weight))
    }

    static func mono(_ size: CGFloat) -> Font {
        Font(Chrome.mono(size))
    }

    static var label: Font { Font(Chrome.label) }
    static var labelActive: Font { Font(Chrome.labelActive) }
    static var section: Font { Font(Chrome.section) }
    static var small: Font { Font(Chrome.small) }
}

/// A 1 px line in `hairline`, or `ink3` under Increase Contrast.
struct Hairline: View {
    @Environment(\.displayScale) private var scale

    var body: some View {
        Rectangle()
            .fill(Station.color(.hairline))
            .frame(height: 1 / scale)
    }
}

/// A rounded surface on the frame, as the main window's islands are: 10 pt corners and a 1 px edge.
struct Island: View {
    let fill: Token
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.displayScale) private var scale

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        shape.fill(Station.color(fill))
            .overlay(shape.strokeBorder(contrast == .increased ? Station.color(.ink3) : Station.stroke, lineWidth: 1 / scale))
    }
}

/// The horizon under a pane's title: the hairline across the island, lit in `signal` at its leading end with the
/// glow, fading out over its last part.
struct PaneHorizon: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack(alignment: .leading) {
            Hairline()
            LinearGradient(
                stops: [.init(color: Station.color(.signal), location: 0), .init(color: Station.color(.signal), location: 0.8),
                        .init(color: Station.color(.signal).opacity(0), location: 1)],
                startPoint: .leading, endPoint: .trailing
            )
            .frame(width: 128, height: 2)
            .shadow(color: Station.color(.glow).opacity(Double(Chrome.glowOpacity(dark: scheme == .dark))), radius: 3)
        }
        .frame(height: 3)
        .accessibilityHidden(true)
    }
}

/// A pane's sections down a scroll view.
struct SettingsPage<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                content
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A sentence-case label in Bricolage 11.5 / 600 `ink3`, a hairline over each row, and a note under the rows.
struct SettingsSection<Content: View>: View {
    var title: String?
    /// Mono `ink3` at the label's right, such as a count.
    var trailing: String?
    var note: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if title != nil || trailing != nil {
                HStack(alignment: .firstTextBaseline) {
                    if let title {
                        Text(title)
                            .font(Station.section)
                            .kerning(Chrome.sectionKern)
                            .foregroundStyle(Station.color(.ink3))
                            .accessibilityAddTraits(.isHeader)
                    }
                    Spacer()
                    if let trailing {
                        Text(trailing)
                            .font(Station.mono(11))
                            .foregroundStyle(Station.color(.ink3))
                    }
                }
                .padding(.bottom, 10)
            }
            content
            if let note {
                SettingsNote(note)
                    .padding(.top, 10)
            }
        }
    }
}

/// Explanation under a section: Bricolage 12 `ink3`, wrapping.
struct SettingsNote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(Station.small)
            .foregroundStyle(Station.color(.ink3))
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One setting: its name in a 190 pt column and its control after, with a hairline above.
struct SettingsRow<Control: View>: View {
    let label: String
    var detail: String?
    @ViewBuilder let control: Control

    var body: some View {
        VStack(spacing: 0) {
            Hairline()
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(Station.label)
                        .foregroundStyle(Station.color(.ink))
                    if let detail {
                        Text(detail)
                            .font(Station.small)
                            .foregroundStyle(Station.color(.ink3))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(width: 190, alignment: .leading)
                control
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .contain)
            .padding(.vertical, 9)
            .frame(minHeight: 44)
        }
    }
}

/// Words to pick one of, drawn as text: the chosen word in `ink` with the signal tick under it, the others in `ink3`.
/// No fill. VoiceOver reads it as a picker.
struct TextChoice<Value: Hashable>: View {
    let label: String
    @Binding var selection: Value
    let options: [(String, Value)]

    var body: some View {
        HStack(spacing: 20) {
            ForEach(options.indices, id: \.self) { index in
                Button(options[index].0) { selection = options[index].1 }
                    .buttonStyle(ChoiceStyle(selected: selection == options[index].1))
            }
        }
        .accessibilityRepresentation {
            Picker(label, selection: $selection) {
                ForEach(options.indices, id: \.self) { Text(options[$0].0).tag(options[$0].1) }
            }
        }
    }
}

/// On and Off as words, drawn like `TextChoice`. VoiceOver reads it as a switch.
struct OnOff: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 20) {
            Button("On") { isOn = true }
                .buttonStyle(ChoiceStyle(selected: isOn))
            Button("Off") { isOn = false }
                .buttonStyle(ChoiceStyle(selected: !isOn))
        }
        .accessibilityRepresentation {
            Toggle(label, isOn: $isOn)
        }
    }
}

private struct ChoiceStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        ChoiceLabel(configuration: configuration, selected: selected)
    }
}

private struct ChoiceLabel: View {
    let configuration: ButtonStyleConfiguration
    let selected: Bool
    @State private var hovering = false
    @Environment(\.isFocused) private var focused
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        configuration.label
            .font(selected ? Station.labelActive : Station.label)
            .foregroundStyle(Station.color(selected || configuration.isPressed ? .ink : hovering ? .ink2 : .ink3))
            .padding(.vertical, 4)
            .overlay(alignment: .bottom) {
                if selected {
                    Capsule()
                        .fill(Station.color(.signal))
                        .frame(height: contrast == .increased ? 3 : 2)
                        .offset(y: 3)
                }
            }
            .overlay { FocusRing(on: focused, radius: 4).padding(-4) }
            .opacity(enabled ? 1 : 0.45)
            .contentShape(.rect)
            .onHover { hovering = $0 }
            .focusEffectDisabled()
    }
}

/// The 1.5 pt signal ring Dewline draws around its own focused controls.
struct FocusRing: View {
    let on: Bool
    var radius: CGFloat = 6

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(on ? Station.color(.signal) : .clear, lineWidth: 1.5)
            .allowsHitTesting(false)
    }
}

/// Dewline's buttons. `quiet` sits on a keycap surface with a hairline edge; `text` is bare `ink2`; `filled` is `ink`
/// with the island's color for its text. Signal never fills one.
struct StationButtonStyle: ButtonStyle {
    enum Kind {
        case quiet, text, filled
    }

    var kind = Kind.quiet

    func makeBody(configuration: Configuration) -> some View {
        StationButtonLabel(configuration: configuration, kind: kind)
    }
}

extension ButtonStyle where Self == StationButtonStyle {
    static var station: StationButtonStyle { StationButtonStyle() }
    static func station(_ kind: StationButtonStyle.Kind) -> StationButtonStyle { StationButtonStyle(kind: kind) }
}

private struct StationButtonLabel: View {
    let configuration: ButtonStyleConfiguration
    let kind: StationButtonStyle.Kind
    @State private var hovering = false
    @Environment(\.isFocused) private var focused
    @Environment(\.isEnabled) private var enabled
    @Environment(\.displayScale) private var scale

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        configuration.label
            .font(kind == .filled ? Station.labelActive : Station.label)
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, kind == .text ? 6 : 11)
            .frame(height: kind == .text ? 24 : 26)
            .background {
                switch kind {
                case .quiet:
                    shape.fill(Station.color(.keycap).opacity(configuration.isPressed ? 0.7 : 1))
                        .overlay(shape.strokeBorder(Station.color(hovering && enabled ? .ink3 : .hairline), lineWidth: 1 / scale))
                case .filled:
                    shape.fill(Station.color(.ink).opacity(configuration.isPressed ? 0.82 : 1))
                case .text:
                    Color.clear
                }
            }
            .overlay { FocusRing(on: focused).padding(-2) }
            .opacity(enabled ? 1 : 0.45)
            .contentShape(.rect)
            .onHover { hovering = $0 }
            .focusEffectDisabled()
    }

    private var foreground: Color {
        switch kind {
        case .filled: Station.color(.islandEditor)
        case .quiet: Station.color(.ink)
        case .text: Station.color(hovering || configuration.isPressed ? .ink : .ink2)
        }
    }
}

/// A button that draws only its label, dimmed while pressed, with the signal ring while it has focus.
struct BareButtonStyle: ButtonStyle {
    var radius: CGFloat = 6

    func makeBody(configuration: Configuration) -> some View {
        BareLabel(configuration: configuration, radius: radius)
    }
}

private struct BareLabel: View {
    let configuration: ButtonStyleConfiguration
    let radius: CGFloat
    @Environment(\.isFocused) private var focused
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.8 : enabled ? 1 : 0.45)
            .overlay { FocusRing(on: focused, radius: radius) }
            .contentShape(.rect)
            .focusEffectDisabled()
    }
}

/// `- 17 pt +`: the value in mono between two keycap buttons. VoiceOver adjusts it with the usual swipes.
struct KeyStepper: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let text: (Double) -> String
    var spoken: ((Double) -> String)?

    var body: some View {
        HStack(spacing: 10) {
            Button("\u{2212}") { set(value - step) }
                .buttonStyle(KeyStyle())
                .disabled(value <= range.lowerBound)
            Text(text(value))
                .font(Station.mono(12.5))
                .monospacedDigit()
                .foregroundStyle(Station.color(.ink))
                .fixedSize()
            Button("+") { set(value + step) }
                .buttonStyle(KeyStyle())
                .disabled(value >= range.upperBound)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue((spoken ?? text)(value))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: set(value + step)
            case .decrement: set(value - step)
            @unknown default: break
            }
        }
    }

    /// Rounds to hundredths, so steps of 0.02 never drift, and keeps to the range.
    private func set(_ next: Double) {
        value = min(max((next * 100).rounded() / 100, range.lowerBound), range.upperBound)
    }
}

/// A keycap as a button: 20 pt square, `keycap` fill, a hairline edge, the key in mono 11 `ink2`.
private struct KeyStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        KeyLabel(configuration: configuration)
    }
}

private struct KeyLabel: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isFocused) private var focused
    @Environment(\.isEnabled) private var enabled
    @Environment(\.displayScale) private var scale

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        configuration.label
            .font(Station.mono(11))
            .foregroundStyle(Station.color(configuration.isPressed ? .ink : .ink2))
            .frame(width: 20, height: 20)
            .background(shape.fill(Station.color(.keycap)))
            .overlay(shape.strokeBorder(Station.color(.hairline), lineWidth: 1 / scale))
            .overlay(alignment: .bottom) {
                Rectangle().fill(Station.color(.ink3).opacity(0.35)).frame(height: 1 / scale).padding(.horizontal, 4)
            }
            .overlay { FocusRing(on: focused, radius: 5).padding(-2) }
            .opacity(enabled ? 1 : 0.4)
            .contentShape(.rect)
            .focusEffectDisabled()
    }
}

/// The last row of every pane: puts that pane's settings, and no others, back as a fresh install has them.
struct RestoreDefaults: View {
    let restore: () -> Void

    var body: some View {
        HStack {
            Spacer()
            Button("Restore Defaults", action: restore)
                .buttonStyle(.station(.text))
        }
    }
}

/// A path in mono `ink3` with a Choose… button that asks for a folder.
struct FolderField: View {
    let url: URL
    let chose: (URL) -> Void

    var body: some View {
        PathField(url: url) {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.directoryURL = url
            if panel.runModal() == .OK, let chosen = panel.url { chose(chosen) }
        }
    }
}

/// A path in mono `ink3`, its full path in the tooltip, and a Choose… button.
struct PathField: View {
    let url: URL
    let choose: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(abbreviatedPath(url))
                .font(Station.mono(12))
                .foregroundStyle(Station.color(.ink2))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(url.path)
                .accessibilityLabel(url.path)
            Button("Choose\u{2026}", action: choose)
                .buttonStyle(.station)
                .fixedSize()
        }
    }
}

/// A menu of choices as Dewline draws it: the choice in Bricolage `ink`, a drawn chevron after it, no bezel. The menu
/// itself is the system's.
struct MenuField<Value: Hashable>: NSViewRepresentable {
    let label: String
    @Binding var selection: Value
    /// Groups of choices, each with an optional header.
    let sections: [(String?, [(String, Value)])]

    init(_ label: String, selection: Binding<Value>, sections: [(String?, [(String, Value)])]) {
        self.label = label
        _selection = selection
        self.sections = sections
    }

    init(_ label: String, selection: Binding<Value>, options: [(String, Value)]) {
        self.init(label, selection: selection, sections: [(nil, options)])
    }

    func makeNSView(context: Context) -> MenuFieldView {
        let view = MenuFieldView()
        view.setContentHuggingPriority(.required, for: .horizontal)
        return view
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MenuFieldView, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }

    func updateNSView(_ view: MenuFieldView, context: Context) {
        let flat = sections.flatMap(\.1)
        let binding = $selection
        view.label = label
        view.sections = sections.map { ($0.0, $0.1.map(\.0)) }
        view.selected = flat.firstIndex { $0.1 == selection }
        view.chose = { binding.wrappedValue = flat[$0].1 }
    }
}

/// The AppKit half of `MenuField`: draws the choice and its chevron, and opens the menu on a click, Space, Return or
/// the down arrow.
final class MenuFieldView: NSView {
    var label = "" {
        didSet { setAccessibilityLabel(label) }
    }
    var sections: [(String?, [String])] = [] {
        didSet { changed() }
    }
    var selected: Int? {
        didSet { changed() }
    }
    var chose: (Int) -> Void = { _ in }
    private var hovering = false {
        didSet { needsDisplay = true }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.popUpButton)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
        NotificationCenter.default.addObserver(self, selector: #selector(themeDidChange), name: ThemeStore.didChange, object: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("MenuFieldView is built in code")
    }

    override var isFlipped: Bool { true }

    private var title: String {
        let flat = sections.flatMap(\.1)
        return selected.map { flat[$0] } ?? ""
    }

    private func changed() {
        setAccessibilityValue(title)
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil((title as NSString).size(withAttributes: [.font: Chrome.label]).width) + 8 + 12 + 4, height: 24)
    }

    override func draw(_ dirtyRect: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [.font: Chrome.label, .foregroundColor: Chrome.color(.ink)]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: NSPoint(x: 2, y: bounds.midY - size.height / 2), withAttributes: attributes)
        let glyph = Glyph.down.image
        let tint = Chrome.color(hovering ? .ink2 : .ink3)
        let rect = NSRect(x: 2 + ceil(size.width) + 8, y: bounds.midY - 6, width: 12, height: 12)
        let tinted = NSImage(size: glyph.size, flipped: false) { frame in
            glyph.draw(in: frame)
            tint.set()
            frame.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: rect)
        if window?.firstResponder === self {
            Chrome.color(.signal).setStroke()
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75).insetBy(dx: -2, dy: 0), xRadius: 5, yRadius: 5)
            ring.lineWidth = 1.5
            ring.stroke()
        }
    }

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { NSApp.isFullKeyboardAccessEnabled }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return super.resignFirstResponder()
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
    }

    override func mouseDown(with event: NSEvent) {
        popUp()
    }

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case " ", "\r", String(UnicodeScalar(NSDownArrowFunctionKey)!): popUp()
        default: super.keyDown(with: event)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        popUp()
        return true
    }

    private func popUp() {
        let menu = NSMenu()
        var index = 0
        var current: NSMenuItem?
        for (header, options) in sections where !options.isEmpty {
            if let header {
                if !menu.items.isEmpty { menu.addItem(.separator()) }
                menu.addItem(.sectionHeader(title: header))
            }
            for option in options {
                let item = NSMenuItem(title: option, action: #selector(pick(_:)), keyEquivalent: "")
                item.target = self
                item.tag = index
                if index == selected {
                    item.state = .on
                    current = item
                }
                menu.addItem(item)
                index += 1
            }
        }
        menu.popUp(positioning: current, at: NSPoint(x: -14, y: bounds.height - 4), in: self)
    }

    @objc private func pick(_ item: NSMenuItem) {
        chose(item.tag)
    }

    @objc private func themeDidChange() {
        needsDisplay = true
    }
}
