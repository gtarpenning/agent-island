//
//  Settings.swift
//  AgentIsland
//
//  App settings manager using UserDefaults
//

import Foundation

/// Available notification sounds
enum NotificationSound: String, CaseIterable {
    case none = "None"
    case pop = "Pop"
    case ping = "Ping"
    case tink = "Tink"
    case glass = "Glass"
    case blow = "Blow"
    case bottle = "Bottle"
    case frog = "Frog"
    case funk = "Funk"
    case hero = "Hero"
    case morse = "Morse"
    case purr = "Purr"
    case sosumi = "Sosumi"
    case submarine = "Submarine"
    case basso = "Basso"

    /// The system sound name to use with NSSound, or nil for no sound
    var soundName: String? {
        self == .none ? nil : rawValue
    }

    /// Parses a persisted sound value with case-insensitive matching.
    static func fromStoredValue(_ rawValue: String) -> NotificationSound? {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return allCases.first { $0.rawValue.lowercased() == normalized }
    }
}

enum AppSettings {
    private static let defaults = UserDefaults.standard

    // MARK: - Keys

    private enum Keys {
        static let notificationSound = "notificationSound"
    }

    // MARK: - Notification Sound

    /// True when the user has explicitly chosen a notification sound.
    static var hasCustomNotificationSoundSelection: Bool {
        defaults.object(forKey: Keys.notificationSound) != nil
    }

    /// The sound to play when an agent finishes and is ready for input.
    static func notificationSound(for agentId: String) -> NotificationSound {
        guard let rawValue = defaults.string(forKey: Keys.notificationSound),
              let sound = NotificationSound.fromStoredValue(rawValue) else {
            return defaultNotificationSound(for: agentId)
        }
        return sound
    }

    /// Global picker value used by settings UI (Claude baseline).
    static var notificationSound: NotificationSound {
        get {
            notificationSound(for: "claude")
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.notificationSound)
        }
    }

    private static func defaultNotificationSound(for agentId: String) -> NotificationSound {
        switch agentId {
        case "codex":
            return .ping
        default:
            return .pop
        }
    }
}
