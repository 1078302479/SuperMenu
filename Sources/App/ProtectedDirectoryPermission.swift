import Foundation
import Darwin

/// Tests access without reading file contents or changing the user's files.
/// This is a capability check, not a query of the Full Disk Access switch.
enum ProtectedDirectoryPermission: Equatable {
    case accessible, denied, unknown

    static func result(errors: [Int32]) -> Self {
        if errors.contains(0) { return .accessible }
        if errors.contains(EPERM) || errors.contains(EACCES) { return .denied }
        return .unknown
    }

    static func check() -> Self {
        guard let home = getpwuid(getuid())?.pointee.pw_dir else { return .unknown }
        let root = URL(fileURLWithPath: String(cString: home), isDirectory: true)
        let errors: [Int32] = ["Library/Mail", "Library/Safari/Bookmarks.plist"].map { path in
            let descriptor = open(root.appendingPathComponent(path).path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
            if descriptor >= 0 {
                close(descriptor)
                return 0
            }
            return errno
        }
        return result(errors: errors)
    }
}
