import AppKit
import ApplicationServices
import FinderSync
import Darwin

@MainActor
final class CloudMenuController {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var settings = Settings()
    private let snapshots = FinderContextCache()
    private var context: FinderMenuContext?
    private var menuController: FinderMenuController?
    private var suppressedButton: CGEventType?
    private var displaying = false
    var onRequest: ((FinderRequest) -> Void)?
    private(set) var available = false

    func configure(_ settings: Settings) {
        self.settings = settings
        let preferences = settings.cloudMenu ?? CloudMenuSettings()
        guard preferences.modifierRightClick || preferences.middleClick, AXIsProcessTrusted() else { stop(); return }
        snapshots.start(settings: settings)
        if let tap, CFMachPortIsValid(tap), CGEvent.tapIsEnabled(tap: tap) { available = true; return }
        stopTap()
        let types: [CGEventType] = [.rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                         eventsOfInterest: mask, callback: { proxy, type, event, reference in
            guard let reference else { return Unmanaged.passUnretained(event) }
            return MainActor.assumeIsolated {
                let controller = Unmanaged<CloudMenuController>.fromOpaque(reference).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = controller.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                    return Unmanaged.passUnretained(event)
                }
                return controller.handle(type, event) ? nil : Unmanaged.passUnretained(event)
            }
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { available = false; return }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        available = true
    }

    func stop() {
        snapshots.stop()
        stopTap()
    }

    private func stopTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        suppressedButton = nil
        available = false
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == suppressedButton {
            suppressedButton = nil
            return true
        }
        guard !displaying else { return false }
        let preferences = settings.cloudMenu ?? CloudMenuSettings()
        let modifier: CGEventFlags
        switch preferences.modifier {
        case .shift: modifier = .maskShift
        case .option: modifier = .maskAlternate
        case .command: modifier = .maskCommand
        case .control: modifier = .maskControl
        }
        let matchesRight = type == .rightMouseDown && preferences.modifierRightClick && event.flags.contains(modifier)
        let matchesMiddle = type == .otherMouseDown && preferences.middleClick && event.getIntegerValueField(.mouseEventButtonNumber) == 2
        guard matchesRight || matchesMiddle else { return false }
        // Never perform AX IPC or filesystem work while WindowServer waits for
        // this callback: Finder may itself be waiting for the mouse event.
        guard let snapshot = snapshots.snapshot(at: event.location) else { return false }
        suppressedButton = matchesRight ? .rightMouseUp : .otherMouseUp
        displaying = true
        context = snapshot
        DispatchQueue.main.async { [weak self] in self?.showMenu() }
        return true
    }

    private func showMenu() {
        defer { displaying = false; menuController = nil; context = nil }
        guard let context else { return }
        let controller = FinderMenuController(context: { context }, onRequest: { [weak self] request in self?.onRequest?(request) })
        menuController = controller
        guard let menu = controller.menu(for: context.selection.isEmpty ? .contextualMenuForContainer : .contextualMenuForItems,
                                         settings: settings) else { return }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

/// Keeps AX IPC outside the synchronous mouse event callback. Entries are
/// short-lived and tied to the exact pointer position; uncertainty passes through.
final class FinderContextCache: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "SuperMenu.cloud-context", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var settings = Settings()
    private var generation = 0
    private var entry: (point: CGPoint, captured: TimeInterval, context: FinderMenuContext)?

    func start(settings: Settings) {
        lock.lock()
        self.settings = settings
        generation += 1
        lock.unlock()
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(80), leeway: .milliseconds(15))
        timer.setEventHandler { [weak self] in self?.refresh() }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        lock.lock()
        generation += 1
        entry = nil
        lock.unlock()
    }

    private func refresh() {
        lock.lock()
        let preferences = settings
        let revision = generation
        lock.unlock()
        let started = ProcessInfo.processInfo.systemUptime
        guard let point = CGEvent(source: nil)?.location else { return }
        var diagnostic = ""
        let context = FinderAccessibility.context(at: point) { diagnostic = $0 }
        let latestPoint = CGEvent(source: nil)?.location
        let home = getpwuid(getuid()).map { URL(fileURLWithPath: String(cString: $0.pointee.pw_dir)) }
        let valid = context.flatMap { context -> FinderMenuContext? in
            guard let folder = context.folder, let home,
                  CloudMenuSettings.isCloudFolder(folder, home: home),
                  ([folder] + context.selection).allSatisfy({ FileAccessPolicy.allows($0, settings: preferences) }) else { return nil }
            return context
        }
        #if SUPERMENU_CLOUD_DIAGNOSTICS
        if let root = try? SharedStore.directory() {
            let report = "\(Date())\n\(diagnostic)\nparsed=\(context != nil) policy=\(valid != nil) samePoint=\(latestPoint == point) duration=\(ProcessInfo.processInfo.systemUptime - started)\n"
            try? report.write(to: root.appendingPathComponent("cloud-diagnostic.txt"), atomically: true, encoding: .utf8)
        }
        #endif
        lock.lock()
        defer { lock.unlock() }
        guard revision == generation else { return }
        if let valid, latestPoint == point, ProcessInfo.processInfo.systemUptime - started < 0.2 {
            entry = (point, ProcessInfo.processInfo.systemUptime, valid)
        } else { entry = nil }
    }

    func snapshot(at point: CGPoint) -> FinderMenuContext? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry, ProcessInfo.processInfo.systemUptime - entry.captured < 0.2,
              abs(entry.point.x - point.x) <= 2, abs(entry.point.y - point.y) <= 2 else { return nil }
        return entry.context
    }
}

/// Reads only the Finder window under the pointer. No AppleScript, clipboard or
/// frontmost-window fallback, and no full desktop traversal.
enum FinderAccessibility {
    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(element, 0.025)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    static func fileURL(_ value: CFTypeRef?) -> URL? {
        let url: URL?
        if let text = value as? String {
            url = text.hasPrefix("/") ? URL(fileURLWithPath: text) : URL(string: text)
        }
        else { url = value as? URL }
        guard let url, url.isFileURL else { return nil }
        return url.standardizedFileURL
    }

    static func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    /// Resolve only the proxy belonging to this window. Do not infer a folder
    /// from its title, sidebar selection, another window, or a selected file.
    static func folderURL(in window: AXUIElement) -> URL? {
        for name in [kAXDocumentAttribute, kAXFilenameAttribute] {
            if let url = fileURL(attribute(window, name)) { return url }
        }
        guard let proxy = element(attribute(window, kAXProxyAttribute)) else { return nil }
        for name in [kAXURLAttribute, kAXDocumentAttribute, kAXFilenameAttribute, kAXValueAttribute] {
            if let url = fileURL(attribute(proxy, name)) { return url }
        }
        return nil
    }

    static func resolvedContext(window: AXUIElement, hitItem: Bool, selectedRow: Bool) -> FinderMenuContext? {
        if let folder = folderURL(in: window) { return FinderMenuContext(folder: folder, selection: []) }
        guard !hitItem || selectedRow else { return nil }
        return FinderAutomation.context(window: window, selectedItem: hitItem)
    }

    static func context(at point: CGPoint, report: ((String) -> Void)? = nil) -> FinderMenuContext? {
        var trace: [String] = []
        defer { report?(trace.joined(separator: "\n")) }
        guard AXIsProcessTrusted() else { return nil }
        var hit: AXUIElement?
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.08)
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success, let hit else { return nil }
        trace.append("hit")
        var pid: pid_t = 0
        guard AXUIElementGetPid(hit, &pid) == .success,
              NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.apple.finder" else { return nil }
        trace.append("finder")
        let deadline = Date().addingTimeInterval(0.1)
        var insideFileArea = false
        var node: AXUIElement? = hit
        var window: AXUIElement?
        var clickedURL: URL?
        var selectedRow = false
        var hitItem = false
        for _ in 0..<16 {
            guard Date() < deadline, let current = node else { break }
            trace.append("\(attribute(current, kAXRoleAttribute) as? String ?? "?") id=\(attribute(current, "AXIdentifier") as? String ?? "?") url=\(fileURL(attribute(current, kAXURLAttribute)) != nil)")
            if let identifier = attribute(current, "AXIdentifier") as? String,
               ["IconView", "ListView", "ColumnView", "Browser"].contains(identifier) { insideFileArea = true }
            if !insideFileArea {
                let role = attribute(current, kAXRoleAttribute) as? String
                if role == kAXImageRole || role == kAXRowRole || role == kAXTextFieldRole { hitItem = true }
                if clickedURL == nil, let url = fileURL(attribute(current, kAXURLAttribute)) { clickedURL = url }
            }
            if attribute(current, kAXSelectedAttribute) as? Bool == true { selectedRow = true }
            if attribute(current, kAXRoleAttribute) as? String == kAXWindowRole { window = current; break }
            node = element(attribute(current, kAXParentAttribute))
        }
        #if SUPERMENU_CLOUD_DIAGNOSTICS
        if let window {
            var names: CFArray?
            AXUIElementCopyAttributeNames(window, &names)
            trace.append("windowAttributes=\(names as? [String] ?? [])")
            for name in [kAXDocumentAttribute, kAXFilenameAttribute, kAXURLAttribute] {
                let value = attribute(window, name)
                trace.append("\(name) type=\(value.map { String(describing: type(of: $0)) } ?? "nil") absolute=\((value as? String)?.hasPrefix("/") == true) fileURL=\(fileURL(value) != nil)")
            }
        }
        #endif
        guard insideFileArea, Date() < deadline, let window,
              let windowContext = resolvedContext(window: window, hitItem: hitItem, selectedRow: selectedRow) else { return nil }
        let folder = windowContext.folder!
        if folderURL(in: window) == nil { return windowContext }
        // Missing item URLs must never silently turn a file click into a
        // background operation in the containing directory.
        guard !hitItem || clickedURL != nil else { return nil }
        // A hit in Finder's sidebar/toolbar must not be interpreted as the folder background.
        guard clickedURL == nil || clickedURL!.deletingLastPathComponent() == folder || clickedURL == folder else { return nil }
        var selection: [URL] = []
        if let clickedURL, clickedURL != folder {
            selection = [clickedURL]
            if selectedRow {
                var queue: [AXUIElement] = [window]
                var count = 0
                var selected: [URL] = []
                while let current = queue.popLast(), count < 1200, Date() < deadline {
                    count += 1
                    if attribute(current, kAXSelectedAttribute) as? Bool == true,
                       let url = fileURL(attribute(current, kAXURLAttribute)), url.deletingLastPathComponent() == folder {
                        selected.append(url)
                    }
                    queue.append(contentsOf: attribute(current, kAXChildrenAttribute) as? [AXUIElement] ?? [])
                }
                if count >= 1200 || Date() >= deadline { return nil }
                if selected.contains(clickedURL) { selection = Array(Set(selected)).sorted { $0.path < $1.path } }
            }
        }
        return FinderMenuContext(folder: folder, selection: selection)
    }
}
