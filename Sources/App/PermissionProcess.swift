import Foundation
import Darwin

/// Only run on a background queue. Permission services must never hold the UI indefinitely.
enum PermissionProcess {
    static func output(executable: URL, arguments: [String], timeout: TimeInterval = 3) -> Data? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { usleep(20_000) }
        if process.isRunning {
            process.terminate()
            usleep(100_000)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return pipe.fileHandleForReading.readDataToEndOfFile()
    }
}
