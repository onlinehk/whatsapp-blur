import AppKit
import ApplicationServices

enum BlurKind {
    case avatar, chatName, chatPreview, message, media, gallery, header, composer
}

/// All rects are in Accessibility coordinates (global, origin at top-left of the primary screen).
struct BlurItem {
    let kind: BlurKind
    let rect: CGRect
    /// Hovering anywhere in here reveals the item (e.g. the whole chat row for its preview line).
    let hoverRect: CGRect
}

struct Snapshot {
    let windowID: CGWindowID
    let windowFrame: CGRect
    /// The window minus the left sidebar.
    let contentArea: CGRect
    let chatListArea: CGRect?
    let messagesArea: CGRect?
    let galleryArea: CGRect?
    let items: [BlurItem]
    /// No other normal-level window overlaps WhatsApp's main window from above.
    let isTopmost: Bool
    /// Our overlay is already ordered directly above WhatsApp's main window.
    let overlayIsDirectlyAbove: Bool
}

/// Reads WhatsApp's accessibility tree on a background queue and publishes where its text is.
///
/// Container elements (chat list, message table, header, composer) are found by their stable
/// accessibility identifiers and cached; each tick only reads their visible children.
final class AXScanner {
    static let bundleID = "net.whatsapp.WhatsApp"

    private enum ID {
        static let chatList = "ChatListView_TableView"
        static let messages = "ChatMessagesTableView"
        static let header = "NavigationBar_HeaderViewButton"
        static let composer = "ChatBar_ComposerTextView"
        static let navigationBar = "WDSNavigationBar"
        static let sidebarChats = "SidebarButton_Chats"
        static let gallery = "MediaGalleryCollectionView"
    }

    /// Words WhatsApp puts in the VoiceOver description of photo/video/sticker/GIF bubbles.
    private static let mediaKeywords = [
        "相片", "影片", "貼圖", "照片", "视频", "贴纸", "圖片", "图片", "GIF",
        "Photo", "Video", "Sticker", "Image",
    ]

    private let queue = DispatchQueue(label: "WhatsAppBlur.AXScanner", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private let onSnapshot: (Snapshot?) -> Void

    private var pid: pid_t = 0
    private var appElement: AXUIElement?
    private var window: AXUIElement?
    private var chatList: AXUIElement?
    private var chatListBar: AXUIElement?
    private var messages: AXUIElement?
    private var messagesBar: AXUIElement?
    private var header: AXUIElement?
    private var composer: AXUIElement?
    private var sidebar: AXUIElement?
    private var gallery: AXUIElement?
    private var lastDiscovery = Date.distantPast
    private var needsDiscovery = true

    init(onSnapshot: @escaping (Snapshot?) -> Void) {
        self.onSnapshot = onSnapshot
    }

    func start(interval: TimeInterval = 1.0 / 15) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in self?.scanAndPublish() }
        timer.resume()
        self.timer = timer
    }

    /// Schedules an extra scan, e.g. right after a click that may have switched chats.
    func refreshSoon(after delay: TimeInterval = 0, rediscover: Bool = false) {
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            if rediscover {
                self.needsDiscovery = true
            }
            self.scanAndPublish()
        }
    }

    private func scanAndPublish() {
        let snapshot = scan()
        DispatchQueue.main.async { self.onSnapshot(snapshot) }
    }

    // MARK: - Scanning

    private func scan() -> Snapshot? {
        guard AXIsProcessTrusted(), ensureApp() else {
            return nil
        }

        if needsDiscovery || window == nil || Date().timeIntervalSince(lastDiscovery) > 1 {
            discover()
        }

        guard let window, let windowFrame = frame(of: window), windowFrame.width > 50 else {
            needsDiscovery = true
            return nil
        }

        guard let cgWindow = cgWindowInfo(matching: windowFrame) else {
            return nil
        }

        var items: [BlurItem] = []
        var chatListArea: CGRect?
        var messagesArea: CGRect?
        var galleryArea: CGRect?

        // On macOS 26 the sidebar floats over the content, and lists run underneath it.
        var contentArea = windowFrame
        if let sidebar, let sidebarFrame = frame(of: sidebar), sidebarFrame.intersects(windowFrame) {
            contentArea = CGRect(x: sidebarFrame.maxX, y: windowFrame.minY, width: windowFrame.maxX - sidebarFrame.maxX, height: windowFrame.height)
        }

        if let chatList {
            if let listFrame = frame(of: chatList) {
                let leading = max(listFrame.minX, contentArea.minX) + 16

                var area = listFrame.intersection(windowFrame)
                area = CGRect(x: leading, y: area.minY, width: max(0, area.maxX - 16 - leading), height: area.height)
                if let bar = chatListBar, let barFrame = frame(of: bar) {
                    area = area.croppingTop(to: barFrame.minY)
                }

                if area.height > 0 && area.width > 0 {
                    chatListArea = area
                    for child in childFrames(of: chatList) where child.frame.height >= 30 {
                        let row = CGRect(x: leading, y: child.frame.minY, width: child.frame.maxX - 16 - leading, height: child.frame.height)
                        let hoverRect = row.intersection(area)
                        guard !hoverRect.isEmpty else { continue }

                        for (kind, rect) in Self.chatRowParts(row) {
                            let visible = rect.intersection(area)
                            if visible.width >= 8 && visible.height >= 4 {
                                items.append(BlurItem(kind: kind, rect: visible, hoverRect: hoverRect))
                            }
                        }
                    }
                }
            } else {
                needsDiscovery = true
            }
        }

        let composerFrame = composer.flatMap { frame(of: $0) }

        if let messages {
            if let tableFrame = frame(of: messages) {
                var area = tableFrame.intersection(windowFrame)
                // Messages stay legible under the translucent header, so blur them there too.
                if let bar = messagesBar, let barFrame = frame(of: bar) {
                    area = area.croppingTop(to: barFrame.minY)
                }
                if let composerFrame {
                    area = area.croppingBottom(to: composerFrame.minY - 10)
                }

                if area.height > 0 {
                    messagesArea = area
                    // Headings are the date separators ("Today", "Yesterday").
                    let bubbles = childFrames(of: messages, withDescription: true)
                        .filter { $0.role != kAXHeadingRole && $0.frame.height >= 8 }
                    for bubble in bubbles {
                        let rect = bubble.frame.intersection(area)
                        if rect.width >= 8 && rect.height >= 6 {
                            let kind: BlurKind = Self.isMedia(bubble.description) ? .media : .message
                            items.append(BlurItem(kind: kind, rect: rect, hoverRect: rect))
                        }
                    }
                    items += Self.groupAvatars(for: bubbles.map(\.frame), in: area)
                }
            } else {
                needsDiscovery = true
            }
        }

        if let gallery {
            if let galleryFrame = frame(of: gallery) {
                let area = galleryFrame.intersection(contentArea)
                if area.height > 0 && area.width > 0 {
                    galleryArea = area
                    for cell in childFrames(of: gallery) {
                        let rect = cell.frame.intersection(area)
                        if rect.width >= 8 && rect.height >= 8 {
                            items.append(BlurItem(kind: .gallery, rect: rect, hoverRect: rect))
                        }
                    }
                }
            } else {
                needsDiscovery = true
            }
        }

        if let header, let headerFrame = frame(of: header) {
            let rect = headerFrame.intersection(windowFrame)
            if !rect.isEmpty {
                items.append(BlurItem(kind: .header, rect: rect, hoverRect: rect))
            }
            // The chat photo sits just left of the header button.
            let avatar = CGRect(x: headerFrame.minX - 38, y: headerFrame.midY - 19, width: 38, height: 38).intersection(windowFrame)
            if !avatar.isEmpty {
                items.append(BlurItem(kind: .avatar, rect: avatar, hoverRect: avatar))
            }
        }

        if let composerFrame {
            let rect = composerFrame.insetBy(dx: -4, dy: -6).intersection(windowFrame)
            if !rect.isEmpty {
                items.append(BlurItem(kind: .composer, rect: rect, hoverRect: rect))
            }
        }

        return Snapshot(
            windowID: cgWindow.id,
            windowFrame: windowFrame,
            contentArea: contentArea,
            chatListArea: chatListArea,
            messagesArea: messagesArea,
            galleryArea: galleryArea,
            items: items,
            isTopmost: cgWindow.isTopmost,
            overlayIsDirectlyAbove: cgWindow.overlayIsDirectlyAbove
        )
    }

    /// Chat rows expose no children, so the parts are placed by WhatsApp's row layout:
    /// a 50pt avatar, then the name on the upper line and the last message below it.
    /// The time and unread count on the right are left visible.
    private static func chatRowParts(_ row: CGRect) -> [(BlurKind, CGRect)] {
        let height = row.height
        let textLeft = row.minX + 64
        return [
            (.avatar, CGRect(x: row.minX + 8, y: row.midY - 25, width: 50, height: 50)),
            (.chatName, CGRect(x: textLeft, y: row.minY + height * 0.17, width: row.maxX - 80 - textLeft, height: height * 0.33)),
            (.chatPreview, CGRect(x: textLeft, y: row.minY + height * 0.5, width: row.maxX - 36 - textLeft, height: height * 0.33)),
        ]
    }

    private static func isMedia(_ description: String) -> Bool {
        // The first fields say what the bubble is ("你嘅相片", "回覆…, 來自…的相片"); later
        // fields are the message text, which may mention these words too.
        let leading = description
            .split(whereSeparator: { $0 == "," || $0 == "，" })
            .prefix(2)
            .joined(separator: ",")
        return mediaKeywords.contains { leading.localizedCaseInsensitiveContains($0) }
    }

    /// Group chats show the sender's photo left of the last bubble in each run of incoming
    /// bubbles. The photos aren't accessibility elements, so they're placed by that layout.
    private static func groupAvatars(for bubbles: [CGRect], in area: CGRect) -> [BlurItem] {
        // Incoming bubbles hug the left edge; in group chats they leave a gutter for the photo.
        let incoming = bubbles
            .filter { $0.minX - area.minX >= 40 && $0.minX - area.minX < 90 }
            .sorted { $0.minY < $1.minY }

        var avatars: [BlurItem] = []
        for (index, bubble) in incoming.enumerated() {
            if index + 1 < incoming.count && incoming[index + 1].minY - bubble.maxY < 6 {
                continue
            }
            let rect = CGRect(x: bubble.minX - 40, y: bubble.maxY - 33, width: 34, height: 34).intersection(area)
            if rect.width >= 8 && rect.height >= 8 {
                avatars.append(BlurItem(kind: .avatar, rect: rect, hoverRect: rect))
            }
        }
        return avatars
    }

    private func ensureApp() -> Bool {
        if pid != 0 && kill(pid, 0) == 0 {
            return true
        }

        reset()
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID)
            .first(where: { !$0.isTerminated }) else {
            return false
        }

        pid = running.processIdentifier
        let app = AXUIElementCreateApplication(pid)
        // Never let a busy WhatsApp stall the scanner for long.
        AXUIElementSetMessagingTimeout(app, 0.3)
        appElement = app
        return true
    }

    private func reset() {
        pid = 0
        appElement = nil
        window = nil
        chatList = nil
        chatListBar = nil
        messages = nil
        messagesBar = nil
        header = nil
        composer = nil
        sidebar = nil
        gallery = nil
        needsDiscovery = true
    }

    private func discover() {
        needsDiscovery = false
        lastDiscovery = Date()
        window = nil
        chatList = nil
        chatListBar = nil
        messages = nil
        messagesBar = nil
        header = nil
        composer = nil
        sidebar = nil
        gallery = nil

        guard let appElement else {
            return
        }

        for candidate in elements(appElement, kAXWindowsAttribute) {
            guard let windowFrame = frame(of: candidate) else {
                continue
            }

            let found = findIdentifiedElements(in: candidate)
            let list = largestVisible(found[ID.chatList], in: windowFrame)
            let table = largestVisible(found[ID.messages], in: windowFrame)
            let mediaGrid = largestVisible(found[ID.gallery], in: windowFrame)
            guard list != nil || table != nil || mediaGrid != nil else {
                continue
            }

            let bars = found[ID.navigationBar] ?? []
            window = candidate
            chatList = list
            messages = table
            chatListBar = bar(above: list, from: bars)
            messagesBar = bar(above: table, from: bars)
            header = largestVisible(found[ID.header], in: windowFrame)
            composer = largestVisible(found[ID.composer], in: windowFrame)
            gallery = mediaGrid
            sidebar = found[ID.sidebarChats]?.first.flatMap { element(of: $0, kAXParentAttribute) }
            return
        }
    }

    private func findIdentifiedElements(in root: AXUIElement) -> [String: [AXUIElement]] {
        let wanted: Set<String> = [ID.chatList, ID.messages, ID.header, ID.composer, ID.navigationBar, ID.sidebarChats, ID.gallery]
        var found: [String: [AXUIElement]] = [:]

        func visit(_ element: AXUIElement, depth: Int) {
            guard depth < 18 else {
                return
            }

            let identifier = string(element, "AXIdentifier") ?? ""
            if wanted.contains(identifier) {
                found[identifier, default: []].append(element)
            }

            // Rows are read on every tick; no need to walk into them here.
            if identifier == ID.chatList || identifier == ID.messages || identifier == ID.gallery {
                return
            }

            for child in elements(element, kAXChildrenAttribute) {
                visit(child, depth: depth + 1)
            }
        }

        visit(root, depth: 0)
        return found
    }

    private func largestVisible(_ candidates: [AXUIElement]?, in windowFrame: CGRect) -> AXUIElement? {
        var best: (element: AXUIElement, area: CGFloat)?
        for element in candidates ?? [] {
            guard let rect = frame(of: element)?.intersection(windowFrame), !rect.isEmpty else {
                continue
            }

            let area = rect.width * rect.height
            if area > (best?.area ?? 0) {
                best = (element, area)
            }
        }
        return best?.element
    }

    /// The navigation bar that sits on top of a scroll view spans the same columns.
    private func bar(above element: AXUIElement?, from bars: [AXUIElement]) -> AXUIElement? {
        guard let element, let target = frame(of: element) else {
            return nil
        }

        return bars.first { bar in
            guard let barFrame = frame(of: bar) else {
                return false
            }
            return abs(barFrame.minX - target.minX) <= 2 && abs(barFrame.width - target.width) <= 2
        }
    }

    // MARK: - Window server

    private struct CGWindowMatch {
        let id: CGWindowID
        let isTopmost: Bool
        let overlayIsDirectlyAbove: Bool
    }

    private func cgWindowInfo(matching axFrame: CGRect) -> CGWindowMatch? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        let ownPID = getpid()
        var isTopmost = true
        var previousWasOverlay = false

        // The list is ordered front to back.
        for info in list {
            guard
                let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                let layer = info[kCGWindowLayer as String] as? Int,
                let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                let bounds = CGRect(dictionaryRepresentation: boundsDictionary)
            else {
                continue
            }

            if ownerPID == ownPID {
                previousWasOverlay = true
                continue
            }

            if ownerPID == pid, layer == 0, bounds.isNearlyEqual(to: axFrame),
               let id = info[kCGWindowNumber as String] as? CGWindowID {
                return CGWindowMatch(id: id, isTopmost: isTopmost, overlayIsDirectlyAbove: previousWasOverlay)
            }

            let alpha = info[kCGWindowAlpha as String] as? Double ?? 1
            if layer == 0 && alpha > 0 && bounds.intersects(axFrame) {
                isTopmost = false
            }
            previousWasOverlay = false
        }

        return nil
    }

    // MARK: - AX helpers

    private struct ChildFrame {
        let role: String
        let frame: CGRect
        let description: String
    }

    private func childFrames(of element: AXUIElement, withDescription: Bool = false) -> [ChildFrame] {
        var attributeNames = [kAXRoleAttribute, kAXPositionAttribute, kAXSizeAttribute]
        if withDescription {
            attributeNames.append(kAXDescriptionAttribute)
        }
        let names = attributeNames as CFArray

        return elements(element, kAXChildrenAttribute).compactMap { child in
            var values: CFArray?
            guard
                AXUIElementCopyMultipleAttributeValues(child, names, AXCopyMultipleAttributeOptions(rawValue: 0), &values) == .success,
                let array = values as? [AnyObject], array.count == attributeNames.count,
                let origin = axValue(array[1], as: CGPoint.self, type: .cgPoint),
                let size = axValue(array[2], as: CGSize.self, type: .cgSize)
            else {
                return nil
            }
            return ChildFrame(
                role: array[0] as? String ?? "",
                frame: CGRect(origin: origin, size: size),
                description: withDescription ? array[3] as? String ?? "" : ""
            )
        }
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        let names = [kAXPositionAttribute, kAXSizeAttribute] as CFArray
        var values: CFArray?
        guard
            AXUIElementCopyMultipleAttributeValues(element, names, AXCopyMultipleAttributeOptions(rawValue: 0), &values) == .success,
            let array = values as? [AnyObject], array.count == 2,
            let origin = axValue(array[0], as: CGPoint.self, type: .cgPoint),
            let size = axValue(array[1], as: CGSize.self, type: .cgSize)
        else {
            return nil
        }
        return CGRect(origin: origin, size: size)
    }

    private func axValue<T>(_ object: AnyObject, as _: T.Type, type: AXValueType) -> T? {
        guard CFGetTypeID(object) == AXValueGetTypeID() else {
            return nil
        }

        let value = object as! AXValue
        guard AXValueGetType(value) == type else {
            return nil
        }

        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        guard AXValueGetValue(value, type, pointer) else {
            return nil
        }
        return pointer.pointee
    }

    private func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return []
        }
        return value as? [AXUIElement] ?? []
    }

    private func element(of element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }
}

extension CGRect {
    func isNearlyEqual(to other: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(minX - other.minX) <= tolerance &&
            abs(minY - other.minY) <= tolerance &&
            abs(width - other.width) <= tolerance &&
            abs(height - other.height) <= tolerance
    }

    /// Top-left coordinates: drops everything above `y`.
    func croppingTop(to y: CGFloat) -> CGRect {
        guard y > minY else { return self }
        return CGRect(x: minX, y: y, width: width, height: max(0, maxY - y))
    }

    /// Top-left coordinates: drops everything below `y`.
    func croppingBottom(to y: CGFloat) -> CGRect {
        guard y < maxY else { return self }
        return CGRect(x: minX, y: minY, width: width, height: max(0, y - minY))
    }
}
