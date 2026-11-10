import Foundation

struct CutItem: Codable {
    struct Identity: Codable, Equatable {
        let device: Int64
        let inode: UInt64
        let birthSeconds: Int64
        let birthNanoseconds: Int64
    }

    let path: String
    let identity: Identity
    var hiddenBookmark: Data?
}

struct CutBatch: Codable {
    let id: Int
    let created: Date
    var items: [CutItem]
    var cancelled: Bool?
    var deferredRecovery: [CutItem]?

    func isPending(now: Date = Date()) -> Bool {
        cancelled != true && !items.isEmpty && (0..<86_400).contains(now.timeIntervalSince(created))
    }

    var needsVisibilityRecovery: Bool {
        items.contains { $0.hiddenBookmark != nil } || !(deferredRecovery ?? []).isEmpty
    }
}

enum CutState {
    static func pending(now: Date = Date()) throws -> CutBatch? {
        guard let batch = try load(), batch.isPending(now: now) else { return nil }
        return batch
    }

    static func load() throws -> CutBatch? {
        let data: Data
        do {
            data = try Data(contentsOf: stateURL())
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
        return try JSONDecoder().decode(CutBatch.self, from: data)
    }

    static func save(_ batch: CutBatch) throws {
        try JSONEncoder().encode(batch).write(to: stateURL(), options: .atomic)
    }

    private static func stateURL() throws -> URL {
        try SharedStore.directory().appendingPathComponent("Cut.json")
    }
}
