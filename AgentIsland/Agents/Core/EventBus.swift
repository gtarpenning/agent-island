//
//  EventBus.swift
//  AgentIsland
//
//  Consumes AgentEvent streams from all registered adapters and
//  routes them into the existing SessionStore as SessionEvents.
//
//  This is the glue between the new multi-agent layer and the
//  existing Agent Island session state machine.
//

import Combine
import Foundation
import os.log

private let logger = Logger(subsystem: "com.agentisland", category: "EventBus")

/// Bridges the new AgentEvent model into the existing SessionStore.
/// One EventBus instance manages all adapter tasks.
final class EventBus: ObservableObject, @unchecked Sendable {
    static let shared = EventBus()

    // Task group that fans in all adapter streams
    private var fanInTask: Task<Void, Never>?

    // Registered adapter streams
    private var adapterStreams: [(agentId: String, stream: AsyncStream<AgentEvent>)] = []

    private init() {}

    // MARK: - Registration

    /// Register an adapter's event stream. Call before start().
    func register(adapter: any AgentAdapter) {
        guard !adapterStreams.contains(where: { $0.agentId == adapter.agentId }) else {
            logger.debug("EventBus: adapter \(adapter.agentId, privacy: .public) already registered, skipping")
            return
        }
        adapterStreams.append((agentId: adapter.agentId, stream: adapter.events))
        logger.info("EventBus: registered adapter \(adapter.agentId, privacy: .public)")
    }

    /// Remove all registered streams (used when resetting).
    func removeAll() {
        fanInTask?.cancel()
        fanInTask = nil
        adapterStreams.removeAll()
    }

    // MARK: - Start

    /// Start consuming all registered adapter streams.
    func start() {
        fanInTask?.cancel()

        let streams = adapterStreams
        fanInTask = Task {
            await withTaskGroup(of: Void.self) { group in
                for (_, stream) in streams {
                    let s = stream
                    group.addTask {
                        for await event in s {
                            await Self.route(event)
                        }
                    }
                }
            }
        }

        logger.info("EventBus started with \(streams.count, privacy: .public) adapters")
    }

    // MARK: - Routing

    /// Convert AgentEvent → SessionEvent and process through SessionStore.
    private static func route(_ event: AgentEvent) async {
        logger.debug("EventBus routing: \(event.agentId, privacy: .public) \(event.kind, privacy: .public)")
        let currentCwd = await SessionStore.shared.session(for: event.sessionId)?.cwd ?? ""

        switch event.kind {
        case .sessionStart(let cwd, _):
            // Create session via hookReceived (reuses existing path)
            let hookEvent = HookEvent(
                agentId: event.agentId,
                sessionId: event.sessionId,
                cwd: cwd,
                event: "SessionStart",
                status: "waiting_for_input",
                pid: nil,
                tty: nil,
                tool: nil,
                toolInput: nil,
                toolUseId: nil,
                notificationType: nil,
                message: nil
            )
            await SessionStore.shared.process(.hookReceived(hookEvent))

        case .sessionEnd:
            await SessionStore.shared.process(.sessionEnded(sessionId: event.sessionId))

        case .preToolUse(let toolUseId, let toolName, let inputStrings):
            var acd: [String: AnyCodable] = [:]
            for (k, v) in inputStrings { acd[k] = AnyCodable(v) }
            let hookEvent = HookEvent(
                agentId: event.agentId,
                sessionId: event.sessionId,
                cwd: currentCwd,
                event: "PreToolUse",
                status: "running_tool",
                pid: nil,
                tty: nil,
                tool: toolName,
                toolInput: acd,
                toolUseId: toolUseId,
                notificationType: nil,
                message: nil
            )
            await SessionStore.shared.process(.hookReceived(hookEvent))

        case .postToolUse(let toolUseId, let toolName, _):
            let hookEvent = HookEvent(
                agentId: event.agentId,
                sessionId: event.sessionId,
                cwd: currentCwd,
                event: "PostToolUse",
                status: "processing",
                pid: nil,
                tty: nil,
                tool: toolName,
                toolInput: nil,
                toolUseId: toolUseId,
                notificationType: nil,
                message: nil
            )
            await SessionStore.shared.process(.hookReceived(hookEvent))

        case .permissionRequest(let requestId, let toolName, let inputStrings):
            var acd: [String: AnyCodable] = [:]
            for (k, v) in inputStrings { acd[k] = AnyCodable(v) }
            let hookEvent = HookEvent(
                agentId: event.agentId,
                sessionId: event.sessionId,
                cwd: currentCwd,
                event: "PermissionRequest",
                status: "waiting_for_approval",
                pid: nil,
                tty: nil,
                tool: toolName,
                toolInput: acd,
                toolUseId: requestId,
                notificationType: nil,
                message: nil
            )
            await SessionStore.shared.process(.hookReceived(hookEvent))

        case .notification(let message, _, let notificationType):
            let hookEvent = HookEvent(
                agentId: event.agentId,
                sessionId: event.sessionId,
                cwd: currentCwd,
                event: "Notification",
                status: "notification",
                pid: nil,
                tty: nil,
                tool: nil,
                toolInput: nil,
                toolUseId: nil,
                notificationType: notificationType,
                message: message
            )
            await SessionStore.shared.process(.hookReceived(hookEvent))

        case .stop(let lastMessage):
            let hookEvent = HookEvent(
                agentId: event.agentId,
                sessionId: event.sessionId,
                cwd: currentCwd,
                event: "Stop",
                status: "waiting_for_input",
                pid: nil,
                tty: nil,
                tool: nil,
                toolInput: nil,
                toolUseId: nil,
                notificationType: nil,
                message: lastMessage
            )
            await SessionStore.shared.process(.hookReceived(hookEvent))

        case .processing:
            let hookEvent = HookEvent(
                agentId: event.agentId,
                sessionId: event.sessionId,
                cwd: currentCwd,
                event: "UserPromptSubmit",
                status: "processing",
                pid: nil,
                tty: nil,
                tool: nil,
                toolInput: nil,
                toolUseId: nil,
                notificationType: nil,
                message: nil
            )
            await SessionStore.shared.process(.hookReceived(hookEvent))

        case .compacting:
            let hookEvent = HookEvent(
                agentId: event.agentId,
                sessionId: event.sessionId,
                cwd: currentCwd,
                event: "PreCompact",
                status: "compacting",
                pid: nil,
                tty: nil,
                tool: nil,
                toolInput: nil,
                toolUseId: nil,
                notificationType: nil,
                message: nil
            )
            await SessionStore.shared.process(.hookReceived(hookEvent))

        case .custom(let eventName, _):
            if eventName == "permissionSocketFailed" {
                // Already handled by ClaudeAdapter emitting this; no SessionStore mapping needed
                break
            }
            // Unknown custom events: no-op
            break
        }
    }
}
