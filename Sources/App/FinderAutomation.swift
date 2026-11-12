import AppKit
import Carbon

/// Prototype: selection is valid only for Finder's front window. Match that
/// window's full bounds against the AX window under the pointer, never its title.
enum FinderAutomation {
    static var isAuthorized: Bool {
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder")
        return AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, false) == noErr
    }

    static func requestPermission() -> Bool {
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder")
        return AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, true) == noErr
    }

    static func matches(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= 2 && abs(lhs.minY - rhs.minY) <= 2 &&
        abs(lhs.width - rhs.width) <= 2 && abs(lhs.height - rhs.height) <= 2
    }

    static func context(window: AXUIElement, selectedItem: Bool) -> FinderMenuContext? {
        guard isAuthorized,
              let position = FinderAccessibility.attribute(window, kAXPositionAttribute),
              let size = FinderAccessibility.attribute(window, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &origin),
              AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions) else { return nil }
        let source = """
        tell application "Finder"
            if (count of Finder windows) is 0 then return {}
            set w to front Finder window
            set windowID to id of w
            set windowBounds to bounds of w
            set targetAlias to (target of w) as alias
            set paths to {}
            repeat with f in (selection as list)
                set end of paths to POSIX path of (f as alias)
            end repeat
            if id of front Finder window is not windowID then return {}
            if bounds of w is not windowBounds then return {}
            if ((target of w) as alias) is not targetAlias then return {}
            return {windowBounds, POSIX path of targetAlias, paths}
        end tell
        """
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        guard error == nil, result.numberOfItems == 3,
              let bounds = result.atIndex(1), bounds.numberOfItems == 4,
              let path = result.atIndex(2)?.stringValue, path.hasPrefix("/") else { return nil }
        let values = (1...4).map { CGFloat(bounds.atIndex($0)?.int32Value ?? 0) }
        guard matches(CGRect(origin: origin, size: dimensions), CGRect(x: values[0], y: values[1], width: values[2]-values[0], height: values[3]-values[1])) else { return nil }
        let folder = URL(fileURLWithPath: path).standardizedFileURL
        var selected: [URL] = []
        if selectedItem, let items = result.atIndex(3), items.numberOfItems > 0 {
            for i in 1...items.numberOfItems {
                guard let path = items.atIndex(i)?.stringValue, path.hasPrefix("/") else { return nil }
                let url = URL(fileURLWithPath: path).standardizedFileURL
                guard url.deletingLastPathComponent() == folder else { return nil }
                selected.append(url)
            }
        }
        guard !selectedItem || !selected.isEmpty else { return nil }
        return FinderMenuContext(folder: folder, selection: selected)
    }
}
