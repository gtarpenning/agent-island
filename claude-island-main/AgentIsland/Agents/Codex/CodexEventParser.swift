//
//  CodexEventParser.swift
//  AgentIsland
//
//  Parses Codex CLI stdout/stderr lines into AgentEventKind values.
//  Returns nil for unrecognized lines (silent skip).
//
//  Design note: When Codex gains a native hooks API, swap this parser
//  for a JSON decoder without changing CodexAdapter or anything else.
//

import Foundation

struct CodexEventParser {

    // MARK: - Public API

    /// Parse a single output line from the Codex process.
    /// Returns nil if the line doesn't match any known pattern.
    func parse(line: String, sessionId: String, agentId: String) -> AgentEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Try JSON first (future-proof: Codex may emit structured JSON lines)
        if trimmed.hasPrefix("{"), let event = parseJSON(trimmed, sessionId: sessionId, agentId: agentId) {
            return event
        }

        // Fall back to text pattern matching
        return parseText(trimmed, sessionId: sessionId, agentId: agentId)
    }

    // MARK: - JSON parsing (future native hook format)

    private func parseJSON(_ line: String, sessionId: String, agentId: String) -> AgentEvent? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        // Codex session JSONL format (type + payload envelope)
        if let type = json["type"] as? String,
           let payload = json["payload"] as? [String: Any],
           let event = parseSessionJSON(type: type, payload: payload, sessionId: sessionId, agentId: agentId) {
            return event
        }

        // If Codex emits hook-style JSON, parse it here
        if let eventName = json["event"] as? String ?? json["hook_event_name"] as? String {
            return parseHookJSON(eventName: eventName, json: json, sessionId: sessionId, agentId: agentId)
        }

        return nil
    }

    private func parseHookJSON(eventName: String, json: [String: Any], sessionId: String, agentId: String) -> AgentEvent? {
        switch eventName {
        case "SessionStart":
            let cwd = json["cwd"] as? String ?? ""
            return AgentEvent(agentId: agentId, sessionId: sessionId, kind: .sessionStart(cwd: cwd, model: json["model"] as? String))

        case "SessionEnd":
            return AgentEvent(agentId: agentId, sessionId: sessionId, kind: .sessionEnd(reason: json["reason"] as? String))

        case "PreToolUse":
            let toolName = json["tool_name"] as? String ?? "unknown"
            let toolUseId = json["tool_use_id"] as? String ?? UUID().uuidString
            let rawInput = json["tool_input"] as? [String: Any] ?? [:]
            let input = rawInput.compactMapValues { "\($0)" }
            return AgentEvent(agentId: agentId, sessionId: sessionId,
                              kind: .preToolUse(toolUseId: toolUseId, toolName: toolName, toolInput: input))

        case "PostToolUse":
            let toolName = json["tool_name"] as? String ?? "unknown"
            let toolUseId = json["tool_use_id"] as? String ?? ""
            return AgentEvent(agentId: agentId, sessionId: sessionId,
                              kind: .postToolUse(toolUseId: toolUseId, toolName: toolName, success: true))

        case "Stop":
            return AgentEvent(agentId: agentId, sessionId: sessionId, kind: .stop(lastMessage: nil))

        default:
            return nil
        }
    }

    private func parseSessionJSON(type: String, payload: [String: Any], sessionId: String, agentId: String) -> AgentEvent? {
        switch type {
        case "response_item":
            return parseResponseItem(payload, sessionId: sessionId, agentId: agentId)

        case "event_msg":
            return parseEventMessage(payload, sessionId: sessionId, agentId: agentId)

        default:
            return nil
        }
    }

    private func parseResponseItem(_ payload: [String: Any], sessionId: String, agentId: String) -> AgentEvent? {
        guard let payloadType = payload["type"] as? String else { return nil }

        switch payloadType {
        case "function_call", "custom_tool_call":
            let toolName = payload["name"] as? String ?? "tool"
            let toolUseId = payload["call_id"] as? String ?? UUID().uuidString
            let arguments = payload["arguments"] as? String ?? ""
            let input = arguments.isEmpty ? [:] : ["arguments": arguments]
            return AgentEvent(
                agentId: agentId,
                sessionId: sessionId,
                kind: .preToolUse(toolUseId: toolUseId, toolName: toolName, toolInput: input)
            )

        case "function_call_output", "custom_tool_call_output":
            let toolUseId = payload["call_id"] as? String ?? UUID().uuidString
            return AgentEvent(
                agentId: agentId,
                sessionId: sessionId,
                kind: .postToolUse(toolUseId: toolUseId, toolName: "tool", success: true)
            )

        case "message":
            let role = payload["role"] as? String ?? ""
            // Assistant messages can be high-frequency progress updates mid-turn.
            // Completion is modeled by event_msg/task_complete, so don't emit .stop here.
            if role == "assistant" { return nil }
            if role == "user" {
                return AgentEvent(agentId: agentId, sessionId: sessionId, kind: .processing)
            }
            return nil

        case "reasoning":
            return AgentEvent(agentId: agentId, sessionId: sessionId, kind: .processing)

        default:
            return nil
        }
    }

    private func parseEventMessage(_ payload: [String: Any], sessionId: String, agentId: String) -> AgentEvent? {
        guard let payloadType = payload["type"] as? String else { return nil }

        switch payloadType {
        case "agent_reasoning", "task_started":
            return AgentEvent(agentId: agentId, sessionId: sessionId, kind: .processing)

        case "task_complete":
            let message = payload["last_agent_message"] as? String
            return AgentEvent(agentId: agentId, sessionId: sessionId, kind: .stop(lastMessage: message))

        case "agent_message":
            // Mid-turn progress/status updates; do not signal completion.
            return nil

        default:
            return nil
        }
    }

    // MARK: - Text pattern matching

    private func parseText(_ line: String, sessionId: String, agentId: String) -> AgentEvent? {
        let lower = line.lowercased()

        // Session start indicators
        if matchesAny(lower, patterns: [
            "starting session",
            "session started",
            "codex agent starting",
            "initializing codex"
        ]) {
            return AgentEvent(agentId: agentId, sessionId: sessionId,
                              kind: .sessionStart(cwd: "", model: nil))
        }

        // Session end indicators
        if matchesAny(lower, patterns: [
            "session ended",
            "codex exiting",
            "goodbye",
            "session complete"
        ]) {
            return AgentEvent(agentId: agentId, sessionId: sessionId,
                              kind: .sessionEnd(reason: "process_exit"))
        }

        // Tool execution indicators
        if let toolName = extractToolName(from: line, patterns: [
            "running tool:",
            "executing:",
            "tool:",
            "> "
        ]) {
            let toolUseId = UUID().uuidString
            return AgentEvent(agentId: agentId, sessionId: sessionId,
                              kind: .preToolUse(toolUseId: toolUseId, toolName: toolName, toolInput: [:]))
        }

        // Processing / thinking indicators
        if matchesAny(lower, patterns: [
            "thinking...",
            "processing...",
            "analyzing",
            "planning"
        ]) {
            return AgentEvent(agentId: agentId, sessionId: sessionId, kind: .processing)
        }

        // Completion / idle indicators
        if matchesAny(lower, patterns: [
            "task complete",
            "done.",
            "finished.",
            "all done"
        ]) {
            return AgentEvent(agentId: agentId, sessionId: sessionId,
                              kind: .stop(lastMessage: line))
        }

        // Permission / approval request indicators
        if matchesAny(lower, patterns: [
            "permission required",
            "approval needed",
            "allow this action",
            "confirm:"
        ]) {
            return AgentEvent(agentId: agentId, sessionId: sessionId,
                              kind: .permissionRequest(
                                requestId: UUID().uuidString,
                                toolName: "unknown",
                                toolInput: ["description": line]
                              ))
        }

        return nil
    }

    // MARK: - Helpers

    private func matchesAny(_ text: String, patterns: [String]) -> Bool {
        patterns.contains { text.contains($0) }
    }

    private func extractToolName(from line: String, patterns: [String]) -> String? {
        for pattern in patterns {
            let lower = line.lowercased()
            if let range = lower.range(of: pattern) {
                let after = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                let toolName = after.components(separatedBy: CharacterSet(charactersIn: " \t\n:")).first ?? after
                if !toolName.isEmpty && toolName.count < 50 {
                    return toolName
                }
            }
        }
        return nil
    }
}
