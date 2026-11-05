import Darwin
import Foundation

/// Runs the packaged, metadata-only local-record adapters without blocking the
/// main actor. The returned values are fixed health codes, never subprocess
/// output or paths.
actor MetadataSources {
    private static let runnerQueue = DispatchQueue(
        label: "local.agentwatch.metadata-sources",
        qos: .utility
    )

    private var collecting = false

    func collect() async -> [String: String] {
        guard !collecting else {
            return ["codex_records": "busy", "claude_records": "busy", "claude_code_records": "busy"]
        }
        collecting = true
        let result = await withCheckedContinuation { continuation in
            Self.runnerQueue.async {
                continuation.resume(returning: Self.runAdapters())
            }
        }
        collecting = false
        return result
    }

    private nonisolated static func runAdapters() -> [String: String] {
        let python = pythonInterpreter()
        let adapterDirectory = Bundle.main.resourceURL?.appendingPathComponent("adapters", isDirectory: true)
        return [
            "codex_records": runAdapter("codex_rollouts.py", key: "codex_records", python: python, directory: adapterDirectory),
            "claude_records": runAdapter("claude_desktop.py", key: "claude_records", python: python, directory: adapterDirectory),
            "claude_code_records": runAdapter("claude_code_records.py", key: "claude_code_records", python: python, directory: adapterDirectory),
        ]
    }

    nonisolated static func pythonInterpreter() -> URL? {
        let candidates = [
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3",
        ]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
            .map { URL(fileURLWithPath: $0) }
    }

    private nonisolated static func runAdapter(
        _ filename: String,
        key: String,
        python: URL?,
        directory: URL?
    ) -> String {
        guard let directory, isPlainDirectory(directory),
              let script = safeScript(filename, in: directory) else {
            return "adapter_unavailable"
        }
        guard let python else { return "python_unavailable" }

        let process = Process()
        process.executableURL = python
        process.arguments = ["-B", "-E", "-s", script.path, "--once"]
        process.currentDirectoryURL = directory
        process.environment = ["HOME": NSHomeDirectory()]
        process.standardInput = FileHandle.nullDevice

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        let controller = ProcessController(process: process)
        do {
            try process.run()
        } catch {
            return "process_unavailable"
        }

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) {
            guard controller.markTimedOutIfRunning() else { return }
            controller.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25) {
                controller.killIfRunning()
            }
        }

        var output = Data()
        var overflow = false
        let outputHandle = outputPipe.fileHandleForReading
        while true {
            let bytesToRead = min(1024, 4_097 - output.count)
            let chunk = outputHandle.readData(ofLength: bytesToRead)
            if chunk.isEmpty { break }
            guard output.count + chunk.count <= 4_096 else {
                overflow = true
                controller.terminate()
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25) {
                    controller.killIfRunning()
                }
                break
            }
            output.append(chunk)
        }
        process.waitUntilExit()
        let timedOut = controller.finishAndReadTimeout()
        try? outputHandle.close()

        if timedOut { return "timeout" }
        if overflow { return "invalid_summary" }
        guard process.terminationStatus == 0,
              let summary = parseSummary(output) else {
            return "invalid_summary"
        }
        return healthCode(summary, for: key)
    }

    private nonisolated static func isPlainDirectory(_ directory: URL) -> Bool {
        guard let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private nonisolated static func safeScript(_ filename: String, in directory: URL) -> URL? {
        let allowed = Set(["codex_rollouts.py", "claude_desktop.py", "claude_code_records.py"])
        guard allowed.contains(filename) else { return nil }
        let script = directory.appendingPathComponent(filename, isDirectory: false)
        guard let values = try? script.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              script.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL else {
            return nil
        }
        return script
    }

    private nonisolated static func parseSummary(_ data: Data) -> [String: Any]? {
        guard !data.isEmpty, data.count <= 4_096,
              let value = try? JSONSerialization.jsonObject(with: data),
              let summary = value as? [String: Any] else {
            return nil
        }
        return summary
    }

    private nonisolated static func healthCode(_ summary: [String: Any], for key: String) -> String {
        guard let status = summary["status"] as? String else { return "invalid_summary" }

        if key == "codex_records" {
            if status == "source_unavailable" { return "source_unavailable" }
            guard let sessions = summary["sessions"] as? Int, sessions >= 0,
                  let events = summary["events"] as? Int, events >= 0,
                  let errors = summary["errors"] as? Int, errors >= 0 else {
                return "invalid_summary"
            }
            if errors > 0 { return "partial" }
            switch status {
            case "ok": return "ok"
            case "no_records": return "no_records"
            case "source_unavailable": return "source_unavailable"
            default: return "invalid_summary"
            }
        }

        let expectedAdapter = key == "claude_code_records" ? "claude_code_records" : "claude_desktop"
        let expectedSchema = key == "claude_code_records" ? "claude-code-session-metadata-v1" : "cowork-audit-v1"
        guard ["claude_records", "claude_code_records"].contains(key),
              summary["adapter"] as? String == expectedAdapter,
              summary["schema"] as? String == expectedSchema,
              let events = summary["eventsWritten"] as? Int, events >= 0,
              let validation = summary["validation"] as? String,
              ["schema-confirmed-4.4212.0", "schema-compatible"].contains(validation),
              summary["appVersion"] is String,
              let diagnostic = summary["diagnostic"] as? String else {
            return "invalid_summary"
        }
        if status == "ok" {
            switch diagnostic {
            case "none":
                return validation == "schema-confirmed-4.4212.0" ? "schema_confirmed" : "schema_compatible"
            case "no_status_signal": return "no_status_signal"
            case "store_empty", "no_records": return "no_records"
            default: return "invalid_summary"
            }
        }
        guard status == "degraded" else { return "invalid_summary" }
        switch diagnostic {
        case "store_unavailable", "directory_scan_error": return "source_unavailable"
        case "store_empty": return "no_records"
        case "scan_limited", "directory_scan_limited", "session_scan_limited", "journal_index_limited": return "scan_limited"
        case "metadata_changed_during_read": return "partial"
        case "journal_index_error": return "source_unavailable"
        case "metadata_unavailable": return "metadata_unavailable"
        case "unsupported_metadata_schema", "unsupported_audit_schema", "identity_mismatch": return "unsupported_schema"
        case "unsupported_session_type": return "unsupported_mode"
        case "state_unavailable", "state_reset": return "state_unavailable"
        case "audit_read_failed": return "audit_read_failed"
        case "event_write_failed": return "event_write_failed"
        case "state_write_failed": return "state_write_failed"
        case "adapter_error": return "adapter_error"
        case "no_status_signal": return "no_status_signal"
        default: return "invalid_summary"
        }
    }
}

private final class ProcessController: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var finished = false
    private var timedOut = false

    init(process: Process) {
        self.process = process
    }

    func markTimedOutIfRunning() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !finished, process.isRunning else { return false }
        timedOut = true
        return true
    }

    func terminate() {
        if process.isRunning { process.terminate() }
    }

    func killIfRunning() {
        if process.isRunning {
            _ = kill(process.processIdentifier, SIGKILL)
        }
    }

    func finishAndReadTimeout() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        finished = true
        return timedOut
    }
}
