import AppKit

/// Draws blur patches over WhatsApp's text in a click-through window kept just above WhatsApp.
///
/// The accessibility scan lags the screen by up to one tick, so while something is moving
/// (scrolling, switching chats, dragging the window) whole areas are blurred instead of rows.
final class OverlayController {
    var requestScan: ((_ delay: TimeInterval, _ rediscover: Bool) -> Void)?

    private let window = OverlayWindow()
    /// Patch views by patch key, so a patch keeps its view (and can fade) between frames.
    private var activeViews: [String: NSView] = [:]
    private var spareViews: [NSView] = []
    private var snapshot: Snapshot?
    private var renderTimer: Timer?
    private var monitors: [Any] = []
    private let settings = Settings.shared

    private var chatListScrollUntil = Date.distantPast
    private var messagesScrollUntil = Date.distantPast
    private var galleryScrollUntil = Date.distantPast
    private var chatSwitchUntil = Date.distantPast
    private var tabSwitchUntil = Date.distantPast
    private var windowMoveUntil = Date.distantPast

    private static let fadeDuration: TimeInterval = 0.2
    private static let idleBlurRadius: CGFloat = 24

    init() {
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            self?.render()
        }
        RunLoop.main.add(timer, forMode: .common)
        renderTimer = timer

        installEventMonitors()
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(applicationActivated),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    func update(_ newSnapshot: Snapshot?) {
        if let newSnapshot, let old = snapshot, !old.windowFrame.isNearlyEqual(to: newSnapshot.windowFrame, tolerance: 0.5) {
            windowMoveUntil = Date().addingTimeInterval(0.25)
        }

        snapshot = newSnapshot
        if let newSnapshot, settings.enabled {
            order(for: newSnapshot)
        }
        render()
    }

    // MARK: - Rendering

    func render() {
        guard settings.enabled, let snapshot else {
            if window.isVisible {
                window.orderOut(nil)
            }
            return
        }

        let now = Date()
        let mouse = axPoint(fromScreen: NSEvent.mouseLocation)
        let isMoving = now < windowMoveUntil
        let revealAll = settings.unblurOnAppHover && snapshot.windowFrame.contains(mouse)
        var patches: [Patch] = []

        // While content moves, item positions lag, so whole areas are blurred instead.
        func busyArea(_ key: String, _ area: CGRect?, until: Date, kinds: [BlurKind]) -> Bool {
            guard let area, isMoving || now < until || now < tabSwitchUntil else {
                return false
            }
            let enabled = kinds.filter(settings.isBlurred)
            guard !enabled.isEmpty else {
                return false
            }
            if !revealAll {
                let radius = enabled.map(settings.radius(for:)).max() ?? CGFloat(Settings.defaultRadius)
                patches.append(Patch(key: key, rect: area, cornerRadius: 0, blurRadius: radius, revealed: false))
            }
            return true
        }

        var busyKinds: Set<BlurKind> = []
        let chatListKinds: [BlurKind] = [.avatar, .chatName, .chatPreview]
        if busyArea("area.chatList", snapshot.chatListArea, until: chatListScrollUntil, kinds: chatListKinds) {
            busyKinds.formUnion([.chatName, .chatPreview])
        }
        if busyArea("area.messages", snapshot.messagesArea, until: max(messagesScrollUntil, chatSwitchUntil), kinds: [.message, .media]) {
            busyKinds.formUnion([.message, .media])
        }
        if busyArea("area.gallery", snapshot.galleryArea, until: galleryScrollUntil, kinds: [.gallery]) {
            busyKinds.insert(.gallery)
        }
        // Switching sidebar tabs swaps the whole content; cover it until the next scan lands.
        if now < tabSwitchUntil && !revealAll {
            patches.append(Patch(key: "area.content", rect: snapshot.contentArea, cornerRadius: 0, blurRadius: CGFloat(Settings.defaultRadius), revealed: false))
        }

        for item in snapshot.items where settings.isBlurred(item.kind) && !busyKinds.contains(item.kind) {
            let revealed = revealAll || item.hoverRect.contains(mouse)
            patches.append(Patch(item, blurRadius: settings.radius(for: item.kind), revealed: revealed))
        }

        if settings.blurOnIdle && Self.secondsSinceLastInput() >= settings.idleSeconds {
            patches.append(Patch(key: "idle", rect: snapshot.windowFrame, cornerRadius: 12, blurRadius: Self.idleBlurRadius, revealed: false))
        }

        layout(patches, in: snapshot.windowFrame)

        if !window.isVisible {
            order(for: snapshot)
        }
    }

    private static func secondsSinceLastInput() -> TimeInterval {
        let anyInput = CGEventType(rawValue: ~0)!
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }

    private func layout(_ patches: [Patch], in windowFrame: CGRect) {
        let frame = cocoaRect(fromAX: windowFrame)
        if window.frame != frame {
            window.setFrame(frame, display: false)
        }

        var nextViews: [String: NSView] = [:]
        var fades: [(NSView, CGFloat)] = []

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        for patch in patches where nextViews[patch.key] == nil {
            let alpha: CGFloat = patch.revealed ? 0 : 1
            let view: NSView
            if let existing = activeViews.removeValue(forKey: patch.key) {
                view = existing
                if view.alphaValue != alpha {
                    fades.append((view, alpha))
                }
            } else {
                view = spareViews.popLast() ?? makeView(radius: patch.blurRadius)
                view.alphaValue = alpha
            }

            // The content view is flipped, so AX offsets map directly.
            let rect = patch.rect.offsetBy(dx: -windowFrame.minX, dy: -windowFrame.minY).integral
            if view.frame != rect {
                view.frame = rect
            }
            let cornerRadius = min(patch.cornerRadius, rect.height / 2, rect.width / 2)
            if view.layer?.cornerRadius != cornerRadius {
                view.layer?.cornerRadius = cornerRadius
            }
            (view as? GaussianBlurView)?.radius = patch.blurRadius
            if view.isHidden {
                view.isHidden = false
            }
            nextViews[patch.key] = view
        }

        for view in activeViews.values {
            view.isHidden = true
            spareViews.append(view)
        }
        activeViews = nextViews

        CATransaction.commit()

        guard !fades.isEmpty else {
            return
        }
        if settings.noTransitionDelay {
            fades.forEach { $0.0.alphaValue = $0.1 }
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.fadeDuration
                fades.forEach { $0.0.animator().alphaValue = $0.1 }
            }
        }
    }

    private func makeView(radius: CGFloat) -> NSView {
        let view = GaussianBlurView.make(radius: radius)
        window.contentView?.addSubview(view)
        return view
    }

    // MARK: - Window ordering

    /// Floating while WhatsApp is in front (no flicker when it's clicked); otherwise ordered
    /// directly above WhatsApp's window so other apps' windows still cover the overlay.
    private func order(for snapshot: Snapshot) {
        let whatsAppIsFrontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == AXScanner.bundleID
        if whatsAppIsFrontmost && snapshot.isTopmost {
            if window.level != .floating {
                window.level = .floating
            }
            if !window.isVisible {
                window.orderFrontRegardless()
            }
        } else {
            if window.level != .normal {
                window.level = .normal
            }
            if !snapshot.overlayIsDirectlyAbove || !window.isVisible {
                window.order(.above, relativeTo: Int(snapshot.windowID))
            }
        }
    }

    @objc private func applicationActivated(_ notification: Notification) {
        guard settings.enabled, let snapshot else {
            return
        }

        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        if app?.bundleIdentifier == AXScanner.bundleID {
            window.level = .floating
            window.orderFrontRegardless()
        } else {
            window.level = .normal
            window.order(.above, relativeTo: Int(snapshot.windowID))
        }
        requestScan?(0, false)
    }

    // MARK: - Input

    private func installEventMonitors() {
        let handlers: [(NSEvent.EventTypeMask, (NSEvent) -> Void)] = [
            (.scrollWheel, { [weak self] _ in self?.handleScroll() }),
            (.leftMouseDown, { [weak self] _ in self?.handleClick() }),
            (.keyDown, { [weak self] event in self?.handleKey(event) }),
        ]

        for (mask, handler) in handlers {
            if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler) {
                monitors.append(monitor)
            }
        }
    }

    private func handleScroll() {
        guard let snapshot else {
            return
        }

        let mouse = axPoint(fromScreen: NSEvent.mouseLocation)
        let until = Date().addingTimeInterval(0.4)
        if snapshot.chatListArea?.contains(mouse) == true {
            chatListScrollUntil = until
        } else if snapshot.messagesArea?.contains(mouse) == true {
            messagesScrollUntil = until
        } else if snapshot.galleryArea?.contains(mouse) == true {
            galleryScrollUntil = until
        } else {
            return
        }
        render()
    }

    private func handleClick() {
        guard let snapshot else {
            return
        }

        let mouse = axPoint(fromScreen: NSEvent.mouseLocation)
        guard snapshot.windowFrame.contains(mouse) else {
            return
        }

        if mouse.x < snapshot.contentArea.minX {
            // Sidebar tabs (Chats, Updates, Media…) replace the whole content.
            tabSwitchUntil = Date().addingTimeInterval(0.5)
            render()
        } else if mouse.x < (snapshot.messagesArea?.minX ?? snapshot.windowFrame.maxX) {
            // A click in the chat list may open a different chat.
            chatSwitchUntil = Date().addingTimeInterval(0.5)
            render()
        }
        requestScan?(0.12, true)
        requestScan?(0.5, true)
    }

    private func handleKey(_ event: NSEvent) {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == AXScanner.bundleID else {
            return
        }

        // Shortcuts like ⌘↑/⌘↓ or ⌃Tab switch chats; plain typing does not.
        if !event.modifierFlags.intersection([.command, .control]).isEmpty {
            chatSwitchUntil = Date().addingTimeInterval(0.4)
            render()
            requestScan?(0.12, true)
        }
    }

    // MARK: - Coordinates

    private var primaryScreenHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    private func cocoaRect(fromAX rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryScreenHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    private func axPoint(fromScreen point: NSPoint) -> CGPoint {
        CGPoint(x: point.x, y: primaryScreenHeight - point.y)
    }
}

private struct Patch {
    /// Identifies the same patch across frames so hover reveals can fade.
    let key: String
    let rect: CGRect
    let cornerRadius: CGFloat
    let blurRadius: CGFloat
    let revealed: Bool

    init(key: String, rect: CGRect, cornerRadius: CGFloat, blurRadius: CGFloat, revealed: Bool) {
        self.key = key
        self.rect = rect
        self.cornerRadius = cornerRadius
        self.blurRadius = blurRadius
        self.revealed = revealed
    }

    init(_ item: BlurItem, blurRadius: CGFloat, revealed: Bool) {
        switch item.kind {
        case .message, .media:
            // Stay inside the bubble so its outline and colour remain crisp; only the content blurs.
            rect = item.rect.insetBy(dx: 4, dy: 3)
            cornerRadius = 10
        case .gallery:
            rect = item.rect
            cornerRadius = 4
        case .avatar:
            rect = item.rect
            cornerRadius = item.rect.width / 2
        case .chatName, .chatPreview, .header, .composer:
            rect = item.rect
            cornerRadius = 6
        }
        let r = item.rect
        key = "\(item.kind)-\(Int(r.minX))-\(Int(r.minY))-\(Int(r.width))-\(Int(r.height))"
        self.blurRadius = blurRadius
        self.revealed = revealed
    }
}

private final class OverlayWindow: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = FlippedView()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
