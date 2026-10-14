import AppKit

/// Plain Gaussian blur of whatever is on screen behind the view, without the tint and
/// saturation that NSVisualEffectView materials add.
///
/// Uses Core Animation's private backdrop layer (what NSVisualEffectView is built on). If the
/// private classes ever disappear, `make` falls back to an NSVisualEffectView so text never
/// ends up unblurred.
final class GaussianBlurView: NSView {
    private static let backdropLayerClass = NSClassFromString("CABackdropLayer") as? CALayer.Type
    private static let filterClass: AnyClass? = NSClassFromString("CAFilter")

    static func make(radius: CGFloat) -> NSView {
        guard backdropLayerClass != nil, filterClass != nil else {
            let view = NSVisualEffectView()
            view.blendingMode = .behindWindow
            view.material = .popover
            view.state = .active
            view.wantsLayer = true
            view.layer?.masksToBounds = true
            return view
        }
        return GaussianBlurView(radius: radius)
    }

    var radius: CGFloat {
        didSet {
            if radius != oldValue {
                applyFilter()
            }
        }
    }

    private init(radius: CGFloat) {
        self.radius = radius
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        applyFilter()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func makeBackingLayer() -> CALayer {
        let layer = Self.backdropLayerClass?.init() ?? CALayer()
        // Sample other apps' windows, not just this window's own content.
        layer.setValue(true, forKey: "windowServerAware")
        return layer
    }

    private func applyFilter() {
        guard
            let filterClass = Self.filterClass,
            let filter = (filterClass as AnyObject)
                .perform(NSSelectorFromString("filterWithType:"), with: "gaussianBlur")?
                .takeUnretainedValue() as? NSObject
        else {
            return
        }

        filter.setValue(radius, forKey: "inputRadius")
        filter.setValue(true, forKey: "inputNormalizeEdges")
        layer?.filters = [filter]
    }
}
