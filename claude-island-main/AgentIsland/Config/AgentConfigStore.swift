//
//  AgentConfigStore.swift
//  AgentIsland
//
//  Persists which agents are enabled and any custom agent configs.
//  Primary store: ~/.openisland/config.json
//  Backup store: UserDefaults (key "openisland.agentConfig")
//

import Foundation
import os.log

private let logger = Logger(subsystem: "com.agentisland", category: "AgentConfig")

// MARK: - Models

/// Top-level config file structure
public struct AppAgentConfig: Codable, Sendable {
    /// IDs of agents that should be active (e.g. ["claude", "codex"])
    public var enabledAgents: [String]
    /// Optional custom/third-party agent configs
    public var customAgents: [CustomAgentConfig]

    public init(enabledAgents: [String] = ["claude", "codex"], customAgents: [CustomAgentConfig] = []) {
        self.enabledAgents = enabledAgents
        self.customAgents = customAgents
    }
}

/// A user-defined agent loaded from config rather than compiled in
public struct CustomAgentConfig: Codable, Sendable, Identifiable {
    public var id: String { agentId }
    public var agentId: String
    public var displayName: String
    public var accentColorHex: String   // "#RRGGBB"
    public var iconSFSymbol: String     // SF Symbol name
    /// Path to Unix socket this agent's hook script writes to
    public var hookSocketPath: String
}

// MARK: - AgentConfigStore

public struct AgentConfigStore {
    private static let configDir: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".openisland")
    }()

    private static let configURL: URL = configDir.appendingPathComponent("config.json")
    private static let userDefaultsKey = "openisland.agentConfig"

    // MARK: - Load

    /// Load config from disk. Falls back to UserDefaults, then returns a default config.
    public static func load() -> AppAgentConfig {
        // Try primary: config.json
        if let data = try? Data(contentsOf: configURL),
           let config = try? JSONDecoder().decode(AppAgentConfig.self, from: data) {
            return config
        }

        // Try backup: UserDefaults
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey),
           let config = try? JSONDecoder().decode(AppAgentConfig.self, from: data) {
            logger.info("Loaded agent config from UserDefaults backup")
            return config
        }

        logger.info("No config found, using defaults")
        return AppAgentConfig()
    }

    // MARK: - Save

    /// Persist config to ~/.openisland/config.json and UserDefaults.
    public static func save(_ config: AppAgentConfig) {
        do {
            try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(config)
            try data.write(to: configURL, options: .atomic)
            // Mirror to UserDefaults as backup
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
            logger.debug("Saved agent config to \(configURL.path, privacy: .public)")
        } catch {
            logger.error("Failed to save agent config: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Convenience

    /// Enable an agent by ID (adds to enabledAgents if not already present).
    public static func enable(agentId: String) {
        var config = load()
        if !config.enabledAgents.contains(agentId) {
            config.enabledAgents.append(agentId)
            save(config)
        }
    }

    /// Disable an agent by ID.
    public static func disable(agentId: String) {
        var config = load()
        config.enabledAgents.removeAll { $0 == agentId }
        save(config)
    }

    /// Whether an agent ID is currently enabled.
    public static func isEnabled(agentId: String) -> Bool {
        load().enabledAgents.contains(agentId)
    }

    // MARK: - Config Directory

    /// Ensure ~/.openisland/ exists. Called on app launch.
    public static func ensureConfigDirectory() {
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
    }

    /// URL to watch for hot-reload (used by AgentRegistry).
    public static var configFileURL: URL { configURL }
}
