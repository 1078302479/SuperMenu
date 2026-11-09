import AppKit

enum FinderHandoff {
    static func send(_ request: FinderRequest, to app: URL, completion: @escaping (Error?) -> Void) throws {
        let url = try SharedStore.enqueue(request)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration) { _, error in
            if error != nil {
                _ = try? SharedStore.consume(url)
            }
            completion(error)
        }
    }
}
