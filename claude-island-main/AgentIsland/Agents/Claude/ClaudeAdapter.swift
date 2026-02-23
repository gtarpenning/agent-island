//
//  ClaudeAdapter.swift
//  AgentIsland
//
//  AgentAdapter implementation for Claude Code.
//  Wraps the existing HookSocketServer + HookInstaller infrastructure.
//  All existing Claude behavior is preserved - this is just a protocol wrapper.
//

import Foundation
import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.agentisland", category: "ClaudeAdapter")

/// AgentAdapter implementation for Claude Code CLI.
/// Delegates to the existing HookSocketServer and HookInstaller.
final class ClaudeAdapter: AgentAdapter, @unchecked Sendable {
    let agentId = "claude"
    let displayName = "Claude Code"
    let accentColor = Color(red: 0.85, green: 0.47, blue: 0.34)  // Claude orange
    let iconName = "c.circle.fill"

    private let hookServer = HookSocketServer.shared
    private var eventContinuation: AsyncStream<AgentEvent>.Continuation?

    private(set) lazy var events: AsyncStream<AgentEvent> = {
        AsyncStream<AgentEvent> { continuation in
            self.eventContinuation = continuation
        }
    }()

    // MARK: - AgentAdapter

    func install() async throws {
        // Only install hook scripts into ~/.claude/settings.json.
        // ClaudeSessionMonitor owns HookSocketServer.shared.start() — we must NOT
        // call start() here to avoid replacing its callbacks (InterruptWatcher etc.).
        HookInstaller.installIfNeeded()
        logger.info("ClaudeAdapter: hooks installed")
    }

    func uninstall() async throws {
        // Don't stop the socket server — ClaudeSessionMonitor owns its lifecycle.
        eventContinuation?.finish()
        HookInstaller.uninstall()
        logger.info("ClaudeAdapter: hooks uninstalled")
    }

    /// Called by ClaudeSessionMonitor to bridge existing hook events into AgentEvent stream.
    /// This keeps the existing socket server as the single owner while still publishing AgentEvents.
    func forward(_ hookEvent: HookEvent) {
        emit(hookEvent)
    }

    func resolvePermission(_ decision: PermissionDecision, for requestId: String) async {
        switch decision {
        case .allow:
            hookServer.respondToPermission(toolUseId: requestId, decision: "allow", reason: nil)
        case .deny(let reason):
            hookServer.respondToPermission(toolUseId: requestId, decision: "deny", reason: reason)
        }
    }

    // MARK: - Private

    private func emit(_ hookEvent: HookEvent) {
        guard let kind = agentEventKind(from: hookEvent) else { return }
        let event = AgentEvent(
            agentId: agentId,
            sessionId: hookEvent.sessionId,
            kind: kind
        )
        eventContinuation?.yield(event)
        logger.debug("ClaudeAdapter emitted: \(hookEvent.event, privacy: .public) for \(hookEvent.sessionId.prefix(8), privacy: .public)")
    }

    private func agentEventKind(from hook: HookEvent) -> AgentEventKind? {
        // Flatten toolInput to [String: String] for AgentEvent
        var inputStrings: [String: String] = [:]
        if let toolInput = hook.toolInput {
            for (key, val) in toolInput {
                if let str = val.value as? String {
                    inputStrings[key] = str
                } else if let num = val.value as? Int {
                    inputStrings[key] = String(num)
                } else if let bool = val.value as? Bool {
                    inputStrings[key] = bool ? "true" : "false"
                }
            }
        }

        switch hook.event {
        case "SessionStart":
            return .sessionStart(cwd: hook.cwd, model: nil)

        case "SessionEnd":
            return .sessionEnd(reason: hook.status)

        case "PreToolUse":
            return .preToolUse(
                toolUseId: hook.toolUseId ?? UUID().uuidString,
                toolName: hook.tool ?? "unknown",
                toolInput: inputStrings
            )

        case "PostToolUse":
            return .postToolUse(
                toolUseId: hook.toolUseId ?? "",
                toolName: hook.tool ?? "unknown",
                success: true
            )

        case "PermissionRequest":
            guard hook.expectsResponse else { return nil }
            return .permissionRequest(
                requestId: hook.toolUseId ?? UUID().uuidString,
                toolName: hook.tool ?? "unknown",
                toolInput: inputStrings
            )

        case "Notification":
            guard hook.notificationType != "permission_prompt" else { return nil }
            return .notification(
                message: hook.message ?? "",
                title: nil,
                notificationType: hook.notificationType
            )

        case "Stop", "SubagentStop":
            return .stop(lastMessage: nil)

        case "UserPromptSubmit":
            return .processing

        case "PreCompact":
            return .compacting

        default:
            return .custom(eventName: hook.event, payload: ["status": hook.status])
        }
    }
}
