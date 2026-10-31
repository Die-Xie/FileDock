import AppKit
import QuartzCore

/// A passive native material behind the hosted browser. It inherits the window
/// appearance; the parent owns the reveal mask and leaves file content static.
@MainActor
final class HubGlassMaterialView: NSView {
    enum RenderingMode { case hidden, solid, nativeGlass, visualEffect }
    private static let lightTint = NSColor(calibratedWhite: 0.72, alpha: 0.22)
    private static let lightOpaque = NSColor(calibratedWhite: 0.88, alpha: 1)
    private(set) var renderingMode: RenderingMode = .hidden
    private var material: NSView?
    private var cornerRadius: CGFloat = 21
    private var topExtension: CGFloat = 0
    private var bottomExtension: CGFloat = 0
    private var sideExtension: CGFloat = 0

    override var isOpaque: Bool { renderingMode == .solid }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        isHidden = true
        setAccessibilityElement(false)
        setAccessibilityHidden(true)
    }

    required init?(coder: NSCoder) { nil }

    func configure(enabled: Bool, cornerRadius: CGFloat = 21, topExtension: CGFloat = 0,
                   bottomExtension: CGFloat = 0, sideExtension: CGFloat = 0,
                   reduceTransparency: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency) {
        self.cornerRadius = cornerRadius.isFinite ? max(0, cornerRadius) : 21
        self.topExtension = topExtension.isFinite ? max(0, min(64, topExtension)) : 0
        self.bottomExtension = bottomExtension.isFinite ? max(0, min(64, bottomExtension)) : 0
        self.sideExtension = sideExtension.isFinite ? max(0, min(64, sideExtension)) : 0
        if !enabled {
            renderingMode = .hidden
            isHidden = true
            material?.isHidden = true
        } else if reduceTransparency {
            renderingMode = .solid
            isHidden = false
            material?.isHidden = true
        } else {
            isHidden = false
            if material == nil { installMaterial() }
            material?.isHidden = false
            if #available(macOS 26.0, *), let glass = material as? NSGlassEffectView {
                renderingMode = .nativeGlass
                glass.cornerRadius = self.cornerRadius
            } else { renderingMode = .visualEffect }
        }
        updateMaterialAppearance()
        updateFill()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Extending the material beyond a connecting edge keeps its native rim
        // out of the shared seam. The parent contour still clips every pixel.
        material?.frame = NSRect(x: bounds.minX - sideExtension, y: bounds.minY - bottomExtension,
                                 width: bounds.width + sideExtension * 2, height: bounds.height + bottomExtension + topExtension)
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateMaterialAppearance()
        updateFill()
    }

    private func installMaterial() {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: bounds)
            glass.style = .regular
            glass.cornerRadius = cornerRadius
            glass.tintColor = nil
            // Use the supported contentView slot rather than inserting views
            // into the glass view's private effect hierarchy.
            glass.contentView = NSView(frame: bounds)
            material = glass
        } else {
            let blur = NSVisualEffectView(frame: bounds)
            blur.material = .hudWindow
            blur.blendingMode = .behindWindow
            blur.state = .active
            material = blur
        }
        if let material {
            material.setAccessibilityElement(false)
            material.setAccessibilityHidden(true)
            addSubview(material)
        }
    }

    private func updateFill() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if renderingMode == .solid {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                // Keep the accessible light fallback soft rather than pure
                // white. Text inherits the same window appearance as the glass.
                layer?.backgroundColor = isDark ? NSColor.windowBackgroundColor.cgColor : Self.lightOpaque.cgColor
            }
        } else { layer?.backgroundColor = NSColor.clear.cgColor }
        CATransaction.commit()
    }

    private func updateMaterialAppearance() {
        if #available(macOS 26.0, *), let glass = material as? NSGlassEffectView {
            // Tint only the material in light mode to soften its native white.
            // The hosted browser stays separate and fully opaque.
            if glass.style != .regular { glass.style = .regular }
            let tint: NSColor? = isDark ? nil : Self.lightTint
            if glass.tintColor != tint { glass.tintColor = tint }
        } else if let blur = material as? NSVisualEffectView {
            let desired: NSVisualEffectView.Material = isDark ? .hudWindow : .popover
            if blur.material != desired { blur.material = desired }
        }
    }

    private var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}
