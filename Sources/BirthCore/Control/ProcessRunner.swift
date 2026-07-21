import Foundation

public struct ProcessResult: Sendable {
    public var stdout: String
    public var stderr: String
    public var exitCode: Int32

    public var succeeded: Bool { exitCode == 0 }
}

public enum ProcessRunner {
    public enum ProcessError: Error, LocalizedError {
        case timedOut(command: String, seconds: TimeInterval)

        public var errorDescription: String? {
            switch self {
            case .timedOut(let command, let seconds):
                "\(command) 在 \(Int(seconds)) 秒内未完成，已被强制终止。"
            }
        }
    }

    /// Run an external tool and capture its output. The watchdog matters:
    /// tools like sfltool can hang indefinitely waiting on tccd when the
    /// app's privacy authorization is stale.
    public static func run(
        _ executablePath: String,
        _ arguments: [String],
        timeout: TimeInterval = 15
    ) async throws -> ProcessResult {
        try await Task.detached(priority: .userInitiated) {
            try execute(executablePath, arguments, timeout: timeout)
        }.value
    }

    private static func execute(
        _ executablePath: String,
        _ arguments: [String],
        timeout: TimeInterval
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(filePath: executablePath)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // stderr drains via callback while we block on stdout; reading both
        // sequentially after exit can deadlock once output exceeds the 64 KB
        // pipe buffer (launchctl print system emits far more than that).
        let stderrBuffer = LockedBuffer()
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
            } else {
                stderrBuffer.append(chunk)
            }
        }

        try process.run()

        let timedOut = LockedFlag()
        let watchdog = DispatchWorkItem { [weak process] in
            guard let process, process.isRunning else { return }
            timedOut.set()
            process.terminate()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        if timedOut.isSet {
            throw ProcessError.timedOut(
                command: ([executablePath] + arguments).joined(separator: " "),
                seconds: timeout
            )
        }

        return ProcessResult(
            stdout: String(decoding: stdoutData, as: UTF8.self),
            stderr: String(decoding: stderrBuffer.take(), as: UTF8.self),
            exitCode: process.terminationStatus
        )
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class LockedBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func take() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}
