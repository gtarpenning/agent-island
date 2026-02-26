//
//  CodexProcessMonitor.swift
//  AgentIsland
//
//  Detects running Codex CLI processes via sysctl (no subprocess — Process/ps
//  hangs inside a Swift concurrency task due to cooperative thread pool blocking).
//  Polls every 3 seconds and diffs against known PIDs.
//

import Darwin
import Foundation
import os.log

private let logger = Logger(subsystem: "com.agentisland", category: "CodexProcessMonitor")

/// Watches for Codex CLI processes via sysctl polling and tracks their lifetime.
final class CodexProcessMonitor: @unchecked Sendable {

    // MARK: - State (all protected by lock)

    private let lock = NSLock()
    private var _activeSessions: [Int32: CodexSession] = [:]
    private var _isMonitoring = false
    private var _pollTask: Task<Void, Never>?

    private var activeSessions: [Int32: CodexSession] {
        get { lock.withLock { _activeSessions } }
        set { lock.withLock { _activeSessions = newValue } }
    }

    private var isMonitoring: Bool {
        get { lock.withLock { _isMonitoring } }
        set { lock.withLock { _isMonitoring = newValue } }
    }

    // MARK: - Callbacks

    /// Called when a new Codex session is detected. Args: (sessionId, cwd, sessionFilePath)
    var onSessionStart: ((String, String, String?) -> Void)?

    /// Called with each parsed output line. Args: (line, sessionId)
    var onLine: ((String, String) -> Void)?

    /// Called when a session ends. Args: sessionId
    var onSessionEnd: ((String) -> Void)?

    // MARK: - Start / Stop

    func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true

        let pollTask = Task.detached(priority: .background) { [weak self] in
            while !Task.isCancelled {
                self?.scanForProcesses()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
        lock.withLock { _pollTask = pollTask }
        logger.info("CodexProcessMonitor started (3s sysctl polling)")
    }

    func stopMonitoring() {
        isMonitoring = false
        lock.withLock {
            _pollTask?.cancel()
            _pollTask = nil
        }
        let sessions = activeSessions
        for (_, session) in sessions {
            session.livenessTask?.cancel()
            session.linePollTask?.cancel()
        }
        activeSessions = [:]
        logger.info("CodexProcessMonitor stopped")
    }

    // MARK: - Process Scanning (sysctl — no subprocess)

    nonisolated private func scanForProcesses() {
        let procs = listAllProcesses()

        for (pid, name) in procs {
            // p_comm is truncated to MAXCOMLEN (16 chars), e.g. "codex-aarch64-ap".
            guard name.hasPrefix("codex") else { continue }
            guard activeSessions[pid] == nil else { continue }
            let fallbackSessionId = "codex-\(pid)"
            let metadata = processMetadata(pid: pid, fallbackSessionId: fallbackSessionId)
            // Codex may not open its session file immediately on process spawn.
            // Wait until it's available so we can tail events reliably.
            guard metadata.sessionFilePath != nil else { continue }
            logger.info("Detected Codex PID=\(pid, privacy: .public)")
            attachToProcess(pid: pid, metadata: metadata)
        }
    }

    /// Uses sysctl KERN_PROC_ALL to enumerate all processes without spawning a subprocess.
    nonisolated private func listAllProcesses() -> [(pid: Int32, name: String)] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0

        // First call: get required buffer size
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }

        let count = size / MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)

        // Second call: fill the buffer
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }

        let actualCount = size / MemoryLayout<kinfo_proc>.stride
        return procs.prefix(actualCount).compactMap { kp in
            let pid = kp.kp_proc.p_pid
            guard pid > 0 else { return nil }
            // p_comm is a C char[17] tuple — use String(cString:) via pointer rebinding
            let name = withUnsafePointer(to: kp.kp_proc.p_comm) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: kp.kp_proc.p_comm)) {
                    String(cString: $0)
                }
            }
            return name.isEmpty ? nil : (pid: pid, name: name)
        }
    }

    // MARK: - Session Lifecycle

    nonisolated private func attachToProcess(pid: Int32, metadata: ProcessMetadata) {
        guard activeSessions[pid] == nil else { return }

        let session = CodexSession(
            pid: pid,
            sessionId: metadata.sessionId,
            sessionFilePath: metadata.sessionFilePath
        )

        // Poll liveness every 2s via kill(pid, 0) — zero-cost signal check
        let livenessTask = Task.detached(priority: .background) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if kill(pid, 0) != 0 {
                    self?.handleSessionEnd(pid: pid, sessionId: session.sessionId)
                    break
                }
            }
        }

        session.livenessTask = livenessTask
        if let sessionFilePath = session.sessionFilePath {
            session.linePollTask = Task.detached(priority: .background) { [weak self] in
                self?.tailSessionFile(path: sessionFilePath, sessionId: session.sessionId)
            }
        }
        activeSessions[pid] = session

        logger.info("Attached to Codex PID=\(pid, privacy: .public) session=\(session.sessionId, privacy: .public) cwd=\(metadata.cwd, privacy: .public)")
        onSessionStart?(session.sessionId, metadata.cwd, metadata.sessionFilePath)
    }

    nonisolated private func handleSessionEnd(pid: Int32, sessionId: String) {
        if let session = activeSessions.removeValue(forKey: pid) {
            session.livenessTask?.cancel()
            session.linePollTask?.cancel()
        }
        onSessionEnd?(sessionId)
        logger.info("Codex session ended PID=\(pid, privacy: .public)")
    }

    // MARK: - Per-Process Metadata

    private struct ProcessMetadata {
        let sessionId: String
        let cwd: String
        let sessionFilePath: String?
    }

    nonisolated private func processMetadata(pid: Int32, fallbackSessionId: String) -> ProcessMetadata {
        let sessionFilePath = findCodexSessionFilePath(pid: pid)
        let sessionId = sessionFilePath.flatMap(extractSessionId(fromSessionFilePath:)) ?? fallbackSessionId
        let cwd = processWorkingDirectory(pid: pid, sessionFilePath: sessionFilePath)
        return ProcessMetadata(sessionId: sessionId, cwd: cwd, sessionFilePath: sessionFilePath)
    }

    /// Returns the process CWD from PROC_PIDVNODEPATHINFO.
    nonisolated private func processWorkingDirectory(pid: Int32, sessionFilePath: String?) -> String {
        var vnodeInfo = proc_vnodepathinfo()
        let status = proc_pidinfo(
            pid,
            PROC_PIDVNODEPATHINFO,
            0,
            &vnodeInfo,
            Int32(MemoryLayout<proc_vnodepathinfo>.size)
        )

        if status == Int32(MemoryLayout<proc_vnodepathinfo>.size) {
            let cwd = withUnsafePointer(to: &vnodeInfo.pvi_cdir.vip_path) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                    String(cString: $0)
                }
            }
            if !cwd.isEmpty {
                return cwd
            }
        }

        if let sessionFilePath,
           let cwd = parseSessionMetaCwd(fromSessionFilePath: sessionFilePath) {
            return cwd
        }

        return FileManager.default.homeDirectoryForCurrentUser.path
    }

    /// Finds the active Codex session file currently opened by the process.
    nonisolated private func findCodexSessionFilePath(pid: Int32) -> String? {
        let maxFDs = 4096
        var fdInfos = [proc_fdinfo](repeating: proc_fdinfo(), count: maxFDs)
        let bytes = proc_pidinfo(
            pid,
            PROC_PIDLISTFDS,
            0,
            &fdInfos,
            Int32(MemoryLayout<proc_fdinfo>.stride * maxFDs)
        )

        guard bytes > 0 else { return nil }
        let count = Int(bytes) / MemoryLayout<proc_fdinfo>.stride

        for fdInfo in fdInfos.prefix(count) where fdInfo.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var vnodePath = vnode_fdinfowithpath()
            let result = proc_pidfdinfo(
                pid,
                fdInfo.proc_fd,
                PROC_PIDFDVNODEPATHINFO,
                &vnodePath,
                Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            )
            guard result == Int32(MemoryLayout<vnode_fdinfowithpath>.size) else { continue }

            let path = withUnsafePointer(to: &vnodePath.pvip.vip_path) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                    String(cString: $0)
                }
            }
            guard !path.isEmpty else { continue }
            if path.contains("/.codex/sessions/"), path.hasSuffix(".jsonl") {
                return path
            }
        }

        return nil
    }

    nonisolated private func extractSessionId(fromSessionFilePath path: String) -> String? {
        let filename = URL(fileURLWithPath: path).lastPathComponent
        guard let range = filename.range(
            of: #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#,
            options: .regularExpression
        ) else {
            return nil
        }
        return String(filename[range]).lowercased()
    }

    /// Session files contain a top-level session_meta record with the authoritative cwd.
    nonisolated private func parseSessionMetaCwd(fromSessionFilePath path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }

        for line in text.split(separator: "\n").prefix(20) {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  (json["type"] as? String) == "session_meta",
                  let payload = json["payload"] as? [String: Any],
                  let cwd = payload["cwd"] as? String,
                  !cwd.isEmpty else {
                continue
            }
            return cwd
        }

        return nil
    }

    // MARK: - Session File Streaming

    nonisolated private func tailSessionFile(path: String, sessionId: String) {
        let size = fileSize(atPath: path)
        let snapshotBytes: UInt64 = 32 * 1024
        var offset = size > snapshotBytes ? (size - snapshotBytes) : 0
        var carry = Data()

        while !Task.isCancelled {
            let (chunk, newOffset) = readData(atPath: path, fromOffset: offset)
            if !chunk.isEmpty {
                offset = newOffset
                carry = emitLines(fromChunk: chunk, carry: carry, sessionId: sessionId)
            }
            Thread.sleep(forTimeInterval: 0.75)
        }
    }

    nonisolated private func fileSize(atPath path: String) -> UInt64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? UInt64 else {
            return 0
        }
        return size
    }

    nonisolated private func readData(atPath path: String, fromOffset offset: UInt64) -> (Data, UInt64) {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            return (Data(), offset)
        }

        do {
            try handle.seek(toOffset: offset)
            let data = try handle.readToEnd() ?? Data()
            try handle.close()
            return (data, offset + UInt64(data.count))
        } catch {
            try? handle.close()
            return (Data(), offset)
        }
    }

    nonisolated private func emitLines(fromChunk chunk: Data, carry: Data, sessionId: String) -> Data {
        var buffer = carry
        buffer.append(chunk)

        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[..<newlineIndex]
            buffer.removeSubrange(...newlineIndex)

            guard !lineData.isEmpty,
                  let line = String(data: lineData, encoding: .utf8),
                  !line.isEmpty else {
                continue
            }
            onLine?(line, sessionId)
        }

        return buffer
    }
}

// MARK: - CodexSession

private final class CodexSession: @unchecked Sendable {
    let pid: Int32
    let sessionId: String
    let sessionFilePath: String?
    var livenessTask: Task<Void, Never>?
    var linePollTask: Task<Void, Never>?

    init(pid: Int32, sessionId: String, sessionFilePath: String?) {
        self.pid = pid
        self.sessionId = sessionId
        self.sessionFilePath = sessionFilePath
    }
}
