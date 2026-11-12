import AppKit
import CryptoKit

struct ReleaseAsset: Decodable {
    let name: String
    let browser_download_url: String
    let size: Int64
    let digest: String?

    var url: URL? {
        guard let value = URL(string: browser_download_url), value.scheme == "https", value.host == "github.com",
              value.user == nil, value.password == nil, value.query == nil, value.fragment == nil,
              value.path.hasPrefix("/1078302479/SuperMenu/releases/download/") else { return nil }
        return value
    }
}

struct UpdatePackage {
    let release: GitHubRelease
    let archive: ReleaseAsset
    let checksums: ReleaseAsset

    init(release: GitHubRelease, architecture: String) throws {
        guard release.page != nil, !release.draft, !release.prerelease,
              GitHubRelease.version(release.tag_name) != nil else { throw ToolboxError.message("更新版本信息无效。") }
        let version = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
        let name = "SuperMenu-v\(version)-\(architecture).zip"
        let prefix = "/1078302479/SuperMenu/releases/download/\(release.tag_name)/"
        let assets = release.assets ?? []
        guard let archive = assets.first(where: { $0.name == name }),
              let checksums = assets.first(where: { $0.name == "SHA256SUMS.txt" }),
              archive.url?.path == prefix + name, checksums.url?.path == prefix + checksums.name,
              archive.size > 0, archive.size <= 250_000_000,
              checksums.size > 0, checksums.size <= 100_000 else {
            throw ToolboxError.message("此版本没有适合本机的可校验安装包，请前往发布页下载。")
        }
        self.release = release
        self.archive = archive
        self.checksums = checksums
    }

    func expectedHash(in data: Data) throws -> String {
        guard data.count <= 100_000, let text = String(data: data, encoding: .utf8) else {
            throw ToolboxError.message("校验文件无效。")
        }
        let matches = text.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 2, String(fields[1]).trimmingCharacters(in: CharacterSet(charactersIn: "*")) == archive.name,
                  fields[0].count == 64, fields[0].allSatisfy({ $0.isHexDigit && $0.isASCII }) else { return nil }
            return fields[0].lowercased()
        }
        guard matches.count == 1 else { throw ToolboxError.message("安装包校验值缺失或重复。") }
        if let digest = archive.digest, digest != "sha256:" + matches[0] {
            throw ToolboxError.message("发布附件与校验文件中的校验值不一致。")
        }
        return matches[0]
    }

    static func hash(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty { hash.update(data: bytes) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Owns a unique temporary directory. Never removes downloaded files from other jobs.
final class UpdateDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?
    private let lock = NSLock()
    private var cancelled = false
    private var progress: (@Sendable (Double) -> Void)?
    private var expectedBytes: Int64 = 0
    private var destination: URL?

    func download(_ asset: ReleaseAsset, to destination: URL,
                  progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard let url = asset.url else { throw ToolboxError.message("下载地址无效。") }
        self.destination = destination
        self.expectedBytes = asset.size
        self.progress = progress
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if cancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = 30
                configuration.timeoutIntervalForResource = 600
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                self.session = session
                let task = session.downloadTask(with: url)
                task.resume()
                lock.unlock()
            }
        } onCancel: { self.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let session = session
        lock.unlock()
        session?.invalidateAndCancel()
    }

    private func finish(_ result: Result<URL, Error>) {
        lock.lock()
        let saved = continuation
        continuation = nil
        let session = session
        self.session = nil
        lock.unlock()
        saved?.resume(with: result)
        session?.finishTasksAndInvalidate()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > expectedBytes || (totalBytesExpectedToWrite > 0 && totalBytesExpectedToWrite != expectedBytes) {
            finish(.failure(ToolboxError.message("下载大小与发布信息不一致。")))
            session.invalidateAndCancel()
            return
        }
        progress?(min(1, Double(totalBytesWritten) / Double(max(1, expectedBytes))))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200,
                  let destination, (try location.resourceValues(forKeys: [.fileSizeKey])).fileSize == Int(expectedBytes) else {
                throw ToolboxError.message("下载安装包失败或文件大小不正确。")
            }
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(destination))
        } catch { finish(.failure(error)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }
}
