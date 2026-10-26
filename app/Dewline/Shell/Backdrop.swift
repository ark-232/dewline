import AppKit

/// The theme behind the glass (synthesis 2.4): the sidebar tint fills the view, so the floating sidebar and the
/// toolbar and tab track take the theme's color from behind. Dusk and Nightwatch add their sky, zenith at the top and
/// horizon at the bottom of the toolbar and tab track, then a 24 pt fade into the tint. Content goes inside the safe
/// area, which keeps the page clear of the sidebar and below the tab track.
final class BackdropView: NSView {
    /// The page or pane on the backdrop; the owner lays it out.
    var contentView: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let contentView { addSubview(contentView) }
        }
    }

    /// Where the sky meets its horizon; the top of the safe area when nil.
    var horizon: NSLayoutYAxisAnchor? {
        didSet { horizonConstraint = makeHorizonConstraint() }
    }

    private let sky = SkyView()
    private var tint: CGColor?
    private var horizonConstraint: NSLayoutConstraint? {
        didSet {
            oldValue?.isActive = false
            horizonConstraint?.isActive = true
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        sky.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sky)
        NSLayoutConstraint.activate([
            sky.topAnchor.constraint(equalTo: topAnchor),
            sky.leadingAnchor.constraint(equalTo: leadingAnchor),
            sky.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        let horizon = makeHorizonConstraint()
        horizon.isActive = true
        horizonConstraint = horizon
        NotificationCenter.default.addObserver(self, selector: #selector(themeDidChange), name: ThemeStore.didChange, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(themeDidChange), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil
        )
        themeDidChange()
    }

    required init?(coder: NSCoder) {
        fatalError("BackdropView is built in code")
    }

    private func makeHorizonConstraint() -> NSLayoutConstraint {
        sky.bottomAnchor.constraint(equalTo: horizon ?? safeAreaLayoutGuide.topAnchor, constant: SkyView.fade)
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = tint
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        themeDidChange()
    }

    /// Takes the slot's backdrop for this view's appearance, crossfading in 300 ms (150 ms under Reduce Motion) once
    /// the window is on screen.
    @objc private func themeDidChange() {
        let backdrop = ThemeStore.shared.backdrop(dark: effectiveAppearance.isDark)
        tint = backdrop.tint.color.cgColor
        sky.colors = backdrop.sky.isEmpty ? [] : backdrop.sky.map(\.color) + [backdrop.tint.color]
        if window?.isVisible == true, let layer {
            let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.15 : 0.3
            let fill = CABasicAnimation(keyPath: "backgroundColor")
            fill.fromValue = layer.backgroundColor
            fill.duration = duration
            layer.add(fill, forKey: "theme")
            let fade = CATransition()
            fade.duration = duration
            sky.layer?.add(fade, forKey: "theme")
        }
        needsDisplay = true
    }
}

/// The sky's gradient: drawn once per theme and appearance, then stretched sideways as the window resizes.
private final class SkyView: NSView {
    /// The fade from the horizon into the tint, in points.
    static let fade: CGFloat = 24

    /// Zenith to horizon, then the tint; empty without a sky.
    var colors: [NSColor] = [] {
        didSet {
            isHidden = colors.isEmpty
            if colors != oldValue { needsDisplay = true }
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layerContentsPlacement = .scaleAxesIndependently
        isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("SkyView is built in code")
    }

    override func setFrameSize(_ newSize: NSSize) {
        if newSize.height != frame.height { needsDisplay = true }
        super.setFrameSize(newSize)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard colors.count > 2, bounds.height > Self.fade else { return }
        let horizon = (bounds.height - Self.fade) / bounds.height
        var locations = (0..<colors.count - 1).map { CGFloat($0) / CGFloat(colors.count - 2) * horizon } + [1]
        let gradient = NSGradient(colors: colors, atLocations: &locations, colorSpace: .displayP3)
        let top = NSPoint(x: 0, y: isFlipped ? bounds.minY : bounds.maxY)
        let bottom = NSPoint(x: 0, y: isFlipped ? bounds.maxY : bounds.minY)
        gradient?.draw(from: top, to: bottom, options: [])
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
