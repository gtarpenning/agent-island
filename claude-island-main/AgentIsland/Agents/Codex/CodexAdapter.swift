//
//  CodexAdapter.swift
//  AgentIsland
//
//  AgentAdapter implementation for OpenAI Codex CLI.
//  Uses process monitoring + stdout/stderr line parsing.
//  When Codex gains a native hooks API, swap CodexEventParser for JSON decode.
//

import Foundation
import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.agentisland", category: "CodexAdapter")

/// AgentAdapter implementation for OpenAI Codex CLI.
final class CodexAdapter: AgentAdapter, @unchecked Sendable {
    let agentId = "codex"
    let displayName = "Codex"
    let accentColor = Color(red: 0.06, green: 0.73, blue: 0.51)  // Codex emerald
    let iconName = "cpu"

    private let monitor = CodexProcessMonitor()
    private let parser = CodexEventParser()
    private var eventContinuation: AsyncStream<AgentEvent>.Continuation?

    private(set) lazy var events: AsyncStream<AgentEvent> = {
        AsyncStream<AgentEvent> { continuation in
            self.eventContinuation = continuation
            self.wireMonitor()
        }
    }()

    // MARK: - AgentAdapter

    func install() async throws {
        // Verify codex binary is reachable
        let codexPath = findCodexBinary()
        if let path = codexPath {
            logger.info("CodexAdapter: found codex at \(path, privacy: .public)")
        } else {
            logger.warning("CodexAdapter: codex binary not found in PATH — monitoring will still activate on process launch")
        }
    }

    func uninstall() async throws {
        monitor.stopMonitoring()
        eventContinuation?.finish()
        logger.info("CodexAdapter: stopped monitoring")
    }

    func resolvePermission(_ decision: PermissionDecision, for requestId: String) async {
        // Codex doesn't have a stable hook reply mechanism yet.
        // When Codex adds hook support, write the decision to the hook reply fd here.
        switch decision {
        case .allow:
            logger.info("CodexAdapter: permission allowed for \(requestId.prefix(8), privacy: .public) (no-op stub)")
        case .deny(let reason):
            logger.info("CodexAdapter: permission denied for \(requestId.prefix(8), privacy: .public): \(reason, privacy: .public) (no-op stub)")
        }
    }

    // MARK: - Private

    private func wireMonitor() {
        // Wire callbacks before starting so no events are missed.

        monitor.onSessionStart = { [weak self] sessionId, cwd in
            guard let self = self else { return }
            let event = AgentEvent(
                agentId: self.agentId,
                sessionId: sessionId,
                kind: .sessionStart(cwd: cwd, model: nil)
            )
            self.eventContinuation?.yield(event)
            logger.info("CodexAdapter: session started \(sessionId, privacy: .public) cwd=\(cwd, privacy: .public)")
        }

        monitor.onLine = { [weak self] line, sessionId in
            guard let self = self else { return }
            if let event = self.parser.parse(line: line, sessionId: sessionId, agentId: self.agentId) {
                self.eventContinuation?.yield(event)
            }
        }

        monitor.onSessionEnd = { [weak self] sessionId in
            guard let self = self else { return }
            let event = AgentEvent(
                agentId: self.agentId,
                sessionId: sessionId,
                kind: .sessionEnd(reason: "process_exit")
            )
            self.eventContinuation?.yield(event)
            logger.info("CodexAdapter: session ended \(sessionId.prefix(8), privacy: .public)")
        }

        monitor.startMonitoring()
    }

    private func findCodexBinary() -> String? {
        let searchPaths = [
            "/usr/local/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/bin/codex",
        ]

        for path in searchPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        // Try `which codex`
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        task.arguments = ["codex"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()
            if task.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return path.isEmpty ? nil : path
            }
        } catch {}

        return nil
    }
}
