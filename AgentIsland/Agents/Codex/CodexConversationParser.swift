//
//  CodexConversationParser.swift
//  AgentIsland
//
//  Incrementally parses Codex CLI session JSONL files into ChatMessages.
//  Codex stores sessions at ~/.codex/sessions/YYYY/MM/DD/rollout-{ts}-{uuid}.jsonl
//
//  Record types handled:
//    event_msg/user_message      → user ChatMessage
//    response_item/message(asst) → assistant ChatMessage
//    response_item/function_call → tool use ChatMessage + pending state
//    response_item/function_call_output → ToolResult, marks tool complete
//    event_msg/agent_reasoning   → thinking ChatMessage
//

import Foundation
import os.log

actor CodexConversationParser {
    static let shared = CodexConversationParser()

    nonisolated static let logger = Logger(subsystem: "com.agentisland", category: "CodexParser")

    // MARK: - Types

    struct ParseResult {
        let newMessages: [ChatMessage]
        let completedToolIds: Set<String>
        let toolResults: [String: ConversationParser.ToolResult]
    }

    private struct State {
        var lastFileOffset: UInt64 = 0
        var messages: [ChatMessage] = []
        var completedToolIds: Set<String> = []
        var toolResults: [String: ConversationParser.ToolResult] = [:]
        var messageIndex: Int = 0
    }

    private var states: [String: State] = [:]

    // MARK: - Public API

    /// Parse new lines since last call. Thread-safe via actor isolation.
    func parseIncremental(sessionId: String, filePath: String) -> ParseResult {
        guard FileManager.default.fileExists(atPath: filePath) else {
            return ParseResult(newMessages: [], completedToolIds: [], toolResults: [:])
        }

        var s = states[sessionId] ?? State()
        let newMessages = readNewLines(filePath: filePath, state: &s)
        states[sessionId] = s

        return ParseResult(
            newMessages: newMessages,
            completedToolIds: s.completedToolIds,
            toolResults: s.toolResults
        )
    }

    /// Full parse for ConversationInfo (used by sidebar / session list).
    /// Reads the whole file each time — call sparingly (file is cached by mod date externally).
    func parseConversationInfo(filePath: String) -> ConversationInfo {
        guard let handle = FileHandle(forReadingAtPath: filePath),
              let data = try? handle.readToEnd(),
              let content = String(data: data, encoding: .utf8) else {
            return .empty
        }
        try? handle.close()

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var firstUserMsg: String?
        var lastUserMsg: String?
        var lastUserDate: Date?
        var lastAssistantMsg: String?
        var lastToolName: String?

        for line in content.split(separator: "\n") where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = json["type"] as? String,
                  let payload = json["payload"] as? [String: Any],
                  let payloadType = payload["type"] as? String else { continue }

            let ts = (json["timestamp"] as? String).flatMap { formatter.date(from: $0) }

            switch (type, payloadType) {
            case ("event_msg", "user_message"):
                if let msg = (payload["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !msg.isEmpty {
                    if firstUserMsg == nil { firstUserMsg = msg }
                    lastUserMsg = msg
                    if let ts { lastUserDate = ts }
                }
            case ("response_item", "message") where payload["role"] as? String == "assistant":
                if let blocks = payload["content"] as? [[String: Any]] {
                    for b in blocks where b["type"] as? String == "output_text" {
                        if let t = b["text"] as? String, !t.isEmpty {
                            lastAssistantMsg = t
                        }
                    }
                }
            case ("response_item", "function_call"), ("response_item", "custom_tool_call"):
                if let name = payload["name"] as? String {
                    lastToolName = name
                    lastAssistantMsg = nil
                }
            default:
                break
            }
        }

        let lastMessage: String?
        let lastRole: String?
        if lastAssistantMsg == nil, let tool = lastToolName {
            lastMessage = tool
            lastRole = "tool"
        } else {
            lastMessage = lastAssistantMsg ?? lastUserMsg
            lastRole = lastAssistantMsg != nil ? "assistant" : (lastUserMsg != nil ? "user" : nil)
        }

        return ConversationInfo(
            summary: nil,
            lastMessage: truncate(lastMessage, max: 80),
            lastMessageRole: lastRole,
            lastToolName: lastToolName,
            firstUserMessage: truncate(firstUserMsg, max: 50),
            lastUserMessageDate: lastUserDate
        )
    }

    /// Drop cached state (e.g. when a session ends).
    func resetState(for sessionId: String) {
        states.removeValue(forKey: sessionId)
    }

    // MARK: - Private

    private func readNewLines(filePath: String, state: inout State) -> [ChatMessage] {
        guard let handle = FileHandle(forReadingAtPath: filePath) else { return [] }
        defer { try? handle.close() }

        guard let fileSize = try? handle.seekToEnd() else { return [] }

        // File was truncated / replaced
        if fileSize < state.lastFileOffset { state = State() }
        guard fileSize > state.lastFileOffset else { return [] }

        guard (try? handle.seek(toOffset: state.lastFileOffset)) != nil,
              let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return [] }

        state.lastFileOffset = fileSize

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var newMessages: [ChatMessage] = []

        for line in text.split(separator: "\n") where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = json["type"] as? String,
                  let payload = json["payload"] as? [String: Any],
                  let payloadType = payload["type"] as? String else { continue }

            let ts = (json["timestamp"] as? String).flatMap { formatter.date(from: $0) } ?? Date()

            switch (type, payloadType) {

            case ("event_msg", "user_message"):
                guard let raw = payload["message"] as? String else { break }
                let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { break }
                let msg = makeMessage(role: .user, timestamp: ts, block: .text(text), state: &state)
                newMessages.append(msg)

            case ("response_item", "message") where payload["role"] as? String == "assistant":
                guard let blocks = payload["content"] as? [[String: Any]] else { break }
                var combined = ""
                for b in blocks where b["type"] as? String == "output_text" {
                    combined += (b["text"] as? String) ?? ""
                }
                guard !combined.isEmpty else { break }
                let msg = makeMessage(role: .assistant, timestamp: ts, block: .text(combined), state: &state)
                newMessages.append(msg)

            case ("response_item", "function_call"), ("response_item", "custom_tool_call"):
                guard let callId = payload["call_id"] as? String,
                      let name = payload["name"] as? String else { break }
                let args = payload["arguments"] as? String ?? ""
                let input = parseArguments(args)
                let toolBlock = ToolUseBlock(id: callId, name: name, input: input)
                let msg = makeMessage(role: .assistant, timestamp: ts, block: .toolUse(toolBlock), state: &state)
                newMessages.append(msg)

            case ("response_item", "function_call_output"), ("response_item", "custom_tool_call_output"):
                guard let callId = payload["call_id"] as? String else { break }
                let raw = payload["output"] as? String ?? ""
                let output = extractOutput(raw)
                state.completedToolIds.insert(callId)
                state.toolResults[callId] = ConversationParser.ToolResult(
                    content: output.isEmpty ? nil : output,
                    stdout: output.isEmpty ? nil : output,
                    stderr: nil,
                    isError: false
                )

            case ("event_msg", "agent_reasoning"):
                guard let text = payload["text"] as? String, !text.isEmpty else { break }
                let msg = makeMessage(role: .assistant, timestamp: ts, block: .thinking(text), state: &state)
                newMessages.append(msg)

            default:
                break
            }
        }

        state.messages.append(contentsOf: newMessages)
        return newMessages
    }

    private func makeMessage(role: ChatRole, timestamp: Date, block: MessageBlock, state: inout State) -> ChatMessage {
        state.messageIndex += 1
        let prefix = role == .user ? "u" : "a"
        let id = "cx-\(prefix)-\(state.messageIndex)"
        return ChatMessage(id: id, role: role, timestamp: timestamp, content: [block])
    }

    /// Parse a JSON arguments string into [String: String].
    private func parseArguments(_ args: String) -> [String: String] {
        guard !args.isEmpty,
              let data = args.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return args.isEmpty ? [:] : ["arguments": args]
        }
        var result: [String: String] = [:]
        for (k, v) in json { result[k] = "\(v)" }
        return result
    }

    /// Strips the Codex output header (Chunk ID, Wall time, etc.) and returns just the output.
    private func extractOutput(_ raw: String) -> String {
        if let range = raw.range(of: "Output:\n") {
            return String(raw[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func truncate(_ s: String?, max: Int) -> String? {
        guard let s else { return nil }
        let clean = s.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        return clean.count > max ? String(clean.prefix(max - 3)) + "..." : clean
    }
}

private extension ConversationInfo {
    static let empty = ConversationInfo(
        summary: nil, lastMessage: nil, lastMessageRole: nil,
        lastToolName: nil, firstUserMessage: nil, lastUserMessageDate: nil
    )
}
