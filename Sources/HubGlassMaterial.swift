import AppKit
import QuartzCore

/// A fixed dark, passive native material behind the hosted browser. The parent
/// owns the animated reveal mask, so glass never moves or scales file content.
@MainActor
final class HubGlassMaterialView: NSView {
    enum RenderingMode { case hidden, solid, nativeGlass, visualEffect }
    private(set) var renderingMode: RenderingMode = .hidden
    private var material: NSView?
    private var cornerRadius: CGFloat = 21
    private var topExtension: CGFloat = 0
    private var bottomExtension: CGFloat = 0

    override var isOpaque: Bool { renderingMode == .solid }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        appearance = NSAppearance(named: .darkAqua)
        isHidden = true
        setAccessibilityElement(false)
        setAccessibilityHidden(true)
    }

    required init?(coder: NSCoder) { nil }

    func configure(enabled: Bool, cornerRadius: CGFloat = 21, topExtension: CGFloat = 0,
                   bottomExtension: CGFloat = 0,
                   reduceTransparency: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency) {
        // Glass keeps its Control Center-like dark appearance independently of
        // the system and the appearance preference used by the solid theme.
        if appearance?.name != .darkAqua { appearance = NSAppearance(named: .darkAqua) }
        self.cornerRadius = cornerRadius.isFinite ? max(0, cornerRadius) : 21
        self.topExtension = topExtension.isFinite ? max(0, min(64, topExtension)) : 0
        self.bottomExtension = bottomExtension.isFinite ? max(0, min(64, bottomExtension)) : 0
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
        material?.frame = NSRect(x: bounds.minX, y: bounds.minY - bottomExtension,
                                 width: bounds.width, height: bounds.height + bottomExtension + topExtension)
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
                layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            }
        } else { layer?.backgroundColor = NSColor.clear.cgColor }
        CATransaction.commit()
    }

    private func updateMaterialAppearance() {
        if #available(macOS 26.0, *), let glass = material as? NSGlassEffectView {
            // Keep the native dark glass and full content opacity; tinting or
            // fading the entire view would also wash out file text and previews.
            if glass.style != .regular { glass.style = .regular }
            if glass.tintColor != nil { glass.tintColor = nil }
        }
    }
}
