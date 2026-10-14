import Foundation

/// The things that can be blurred, each with its own switch and blur strength.
enum BlurCategory: String, CaseIterable, Identifiable {
    case messages, previews, media, gallery, composer, avatars, names

    var id: String { rawValue }

    var title: String {
        switch self {
        case .messages: "All messages in chat"
        case .previews: "Last messages preview"
        case .media: "Media preview"
        case .gallery: "Media gallery"
        case .composer: "Text input"
        case .avatars: "Profile pictures"
        case .names: "Group/Users names"
        }
    }

    var enabledKey: String { "blur.\(rawValue)" }
    var radiusKey: String { "radius.\(rawValue)" }

    var defaultEnabled: Bool {
        self != .media
    }

    /// The typing box has no strength setting, matching the extension.
    var hasStrength: Bool {
        self != .composer
    }

    init(_ kind: BlurKind) {
        switch kind {
        case .message: self = .messages
        case .chatPreview: self = .previews
        case .media: self = .media
        case .gallery: self = .gallery
        case .composer: self = .composer
        case .avatar: self = .avatars
        case .chatName, .header: self = .names
        }
    }
}

/// Backed by UserDefaults so the SwiftUI panel (via @AppStorage) and the overlay share the
/// same values without extra plumbing.
final class Settings {
    static let shared = Settings()

    enum Key {
        static let enabled = "enabled"
        static let noTransitionDelay = "noTransitionDelay"
        static let unblurOnAppHover = "unblurOnAppHover"
        static let blurOnIdle = "blurOnIdle"
        static let idleSeconds = "idleSeconds"
    }

    static let defaultRadius = 10.0
    static let defaultIdleSeconds = 60.0

    private let defaults = UserDefaults.standard

    private init() {
        var values: [String: Any] = [
            Key.enabled: true,
            Key.noTransitionDelay: false,
            Key.unblurOnAppHover: false,
            Key.blurOnIdle: false,
            Key.idleSeconds: Self.defaultIdleSeconds,
        ]
        for category in BlurCategory.allCases {
            values[category.enabledKey] = category.defaultEnabled
            values[category.radiusKey] = Self.defaultRadius
        }
        defaults.register(defaults: values)
    }

    var enabled: Bool {
        get { defaults.bool(forKey: Key.enabled) }
        set { defaults.set(newValue, forKey: Key.enabled) }
    }

    var noTransitionDelay: Bool { defaults.bool(forKey: Key.noTransitionDelay) }
    var unblurOnAppHover: Bool { defaults.bool(forKey: Key.unblurOnAppHover) }
    var blurOnIdle: Bool { defaults.bool(forKey: Key.blurOnIdle) }
    var idleSeconds: Double { defaults.double(forKey: Key.idleSeconds) }

    func isBlurred(_ kind: BlurKind) -> Bool {
        defaults.bool(forKey: BlurCategory(kind).enabledKey)
    }

    func radius(for kind: BlurKind) -> CGFloat {
        CGFloat(defaults.double(forKey: BlurCategory(kind).radiusKey))
    }
}
