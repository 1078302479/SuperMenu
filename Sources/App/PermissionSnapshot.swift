import Foundation
import ApplicationServices

/// A short-lived copy of the same signed executable avoids process-local TCC caches.
struct PermissionSnapshot: Codable, Sendable {
    let accessibility: Bool
    let automation: Bool
    let protectedAccess: String

    static func capture() -> Self {
        let access = ProtectedDirectoryPermission.check()
        return Self(accessibility: AXIsProcessTrusted(), automation: FinderAutomation.isAuthorized,
                    protectedAccess: access == .accessible ? "accessible" : access == .denied ? "denied" : "unknown")
    }

    static func fresh() async -> Self? {
        await Task.detached(priority: .userInitiated) {
            guard let executable = Bundle.main.executableURL else { return nil }
            guard let data = PermissionProcess.output(executable: executable, arguments: ["--permission-status-probe"]) else { return nil }
            return try? JSONDecoder().decode(Self.self, from: data)
        }.value
    }
}
