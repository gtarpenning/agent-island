//
//  AgentRegistry.swift
//  AgentIsland
//
//  Discovers, instantiates, and lifecycle-manages all AgentAdapter instances.
//  Single point of control for enabling/disabling agents at runtime.
//

import Combine
import Foundation
import os.log

private let logger = Logger(subsystem: "com.agentisland", category: "AgentRegistry")

/// Manages all registered agent adapters and their lifecycle.
@MainActor
final class AgentRegistry: ObservableObject {
    static let shared = AgentRegistry()

    // MARK: - Published State

    @Published private(set) var adapters: [any AgentAdapter] = []
    @Published private(set) var enabledAgentIds: Set<String> = []

    // MARK: - Private

    private var configWatcher: DispatchSourceFileSystemObject?
    private var configFileDescriptor: Int32 = -1

    private init() {}

    // MARK: - Bootstrap

    /// Call once on app launch. Instantiates built-in adapters + any custom agents from config.
    func bootstrap() async {
        AgentConfigStore.ensureConfigDirectory()

        let config = AgentConfigStore.load()
        enabledAgentIds = Set(config.enabledAgents)

        // Built-in adapters (always available, enabled/disabled by config)
        let builtIns: [any AgentAdapter] = [
            ClaudeAdapter(),
            CodexAdapter()
        ]

        for adapter in builtIns {
            if enabledAgentIds.contains(adapter.agentId) {
                await enable(adapter: adapter)
            }
        }

        // Start hot-reload watcher for custom agents
        watchConfigFile()

        logger.info("AgentRegistry bootstrapped with \(self.adapters.count, privacy: .public) adapters")
    }

    // MARK: - Enable / Disable

    /// Enable an adapter: call install(), register with EventBus.
    func enable(adapter: any AgentAdapter) async {
        guard !adapters.contains(where: { $0.agentId == adapter.agentId }) else {
            return
        }

        do {
            try await adapter.install()
            adapters.append(adapter)
            enabledAgentIds.insert(adapter.agentId)
            EventBus.shared.register(adapter: adapter)
            EventBus.shared.start()
            configWatcher?.suspend()
            AgentConfigStore.enable(agentId: adapter.agentId)
            configWatcher?.resume()
            logger.info("Enabled agent: \(adapter.agentId, privacy: .public)")
        } catch {
            logger.error("Failed to install \(adapter.agentId, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Disable an adapter by ID: call uninstall(), remove from EventBus.
    func disable(agentId: String) async {
        guard let idx = adapters.firstIndex(where: { $0.agentId == agentId }) else { return }
        let adapter = adapters[idx]

        do {
            try await adapter.uninstall()
        } catch {
            logger.error("Error uninstalling \(agentId, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }

        adapters.remove(at: idx)
        enabledAgentIds.remove(agentId)
        configWatcher?.suspend()
        AgentConfigStore.disable(agentId: agentId)
        configWatcher?.resume()

        // Restart EventBus with remaining adapters
        EventBus.shared.removeAll()
        for remaining in adapters {
            EventBus.shared.register(adapter: remaining)
        }
        EventBus.shared.start()

        logger.info("Disabled agent: \(agentId, privacy: .public)")
    }

    /// Toggle an agent by ID. Used from the settings UI.
    func toggle(agentId: String) async {
        if enabledAgentIds.contains(agentId) {
            await disable(agentId: agentId)
        } else {
            // Re-enable known built-ins
            switch agentId {
            case "claude":
                await enable(adapter: ClaudeAdapter())
            case "codex":
                await enable(adapter: CodexAdapter())
            default:
                logger.warning("Cannot re-enable unknown agent: \(agentId, privacy: .public)")
            }
        }
    }

    // MARK: - Config Hot-Reload

    private func watchConfigFile() {
        let path = AgentConfigStore.configFileURL.path

        // Create file if it doesn't exist so we can open it
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }

        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            logger.warning("Cannot watch config file: \(path, privacy: .public)")
            return
        }

        configFileDescriptor = fd
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )

        source.setEventHandler { [weak self] in
            Task { @MainActor in
                self?.reloadConfig()
            }
        }

        source.setCancelHandler {
            close(fd)
        }

        source.resume()
        configWatcher = source
    }

    private func reloadConfig() {
        let config = AgentConfigStore.load()
        let newIds = Set(config.enabledAgents)
        logger.info("Config changed, reloading. enabled: \(newIds, privacy: .public)")

        Task {
            // Disable agents that were removed
            for agentId in enabledAgentIds where !newIds.contains(agentId) {
                await disable(agentId: agentId)
            }
            // Enable agents that were added
            for agentId in newIds where !enabledAgentIds.contains(agentId) {
                await toggle(agentId: agentId)
            }
        }
    }
}
