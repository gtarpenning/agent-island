//
//  AgentEvent.swift
//  AgentIsland
//
//  Canonical internal event model for all agent integrations.
//  Every agent adapter emits AgentEvents; the rest of the app speaks this language.
//

import Foundation

/// A normalized event from any agent CLI (Claude Code, Codex, custom agents).
/// All agent adapters translate their proprietary events into this model.
public struct AgentEvent: Sendable, Identifiable {
    public let id: UUID
    public let agentId: String        // e.g. "claude", "codex"
    public let sessionId: String      // agent-provided session identifier
    public let timestamp: Date
    public let kind: AgentEventKind

    public init(agentId: String, sessionId: String, kind: AgentEventKind, timestamp: Date = Date()) {
        self.id = UUID()
        self.agentId = agentId
        self.sessionId = sessionId
        self.timestamp = timestamp
        self.kind = kind
    }
}

/// All possible event kinds an agent can emit.
/// Use `.custom` for agent-specific events not covered here.
public enum AgentEventKind: Sendable {
    // Session lifecycle
    case sessionStart(cwd: String, model: String?)
    case sessionEnd(reason: String?)

    // Tool lifecycle
    case preToolUse(toolUseId: String, toolName: String, toolInput: [String: String])
    case postToolUse(toolUseId: String, toolName: String, success: Bool)

    // Permission requests (agent needs user approval to proceed)
    case permissionRequest(requestId: String, toolName: String, toolInput: [String: String])

    // Notifications / status messages
    case notification(message: String, title: String?, notificationType: String?)

    // Agent finished responding (waiting for next user prompt)
    case stop(lastMessage: String?)

    // Agent is processing a user prompt
    case processing

    // Context compaction
    case compacting

    // Catch-all for agent-specific events
    case custom(eventName: String, payload: [String: String])
}

// MARK: - Convenience

extension AgentEvent: CustomStringConvertible {
    public var description: String {
        "AgentEvent(agent:\(agentId), session:\(sessionId.prefix(8)), kind:\(kind))"
    }
}

extension AgentEventKind: CustomStringConvertible {
    public var description: String {
        switch self {
        case .sessionStart(let cwd, _): return "sessionStart(cwd:\(cwd))"
        case .sessionEnd(let reason): return "sessionEnd(reason:\(reason ?? "none"))"
        case .preToolUse(_, let name, _): return "preToolUse(\(name))"
        case .postToolUse(_, let name, let ok): return "postToolUse(\(name), ok:\(ok))"
        case .permissionRequest(let id, let name, _): return "permissionRequest(\(name), id:\(id.prefix(8)))"
        case .notification(let msg, _, _): return "notification(\(msg.prefix(40)))"
        case .stop: return "stop"
        case .processing: return "processing"
        case .compacting: return "compacting"
        case .custom(let name, _): return "custom(\(name))"
        }
    }
}
