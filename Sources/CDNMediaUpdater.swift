import CryptoKit
import Foundation

/// Keeps the CDN-lite media cache in a fixed per-user directory. The bundled
/// manifest is the trusted bootstrap; a fresh manifest is requested from the
/// same HTTPS origin on every screen-saver session (with a short multi-display
/// throttle), then only missing or changed files are downloaded.
final class CDNMediaUpdater {
    static let shared = CDNMediaUpdater()

    private struct Manifest: Codable {
        let schemaVersion: Int
        let baseURL: String
        let files: [Entry]
    }

    private struct Entry: Codable {
        let path: String
        let size: Int64
        let sha256: String
        let url: String?
    }

    private struct Receipt: Codable {
        var schemaVersion = 1
        var baseURL: String
        var files: [String: ReceiptEntry]
    }

    private struct ReceiptEntry: Codable {
        let size: Int64
        let sha256: String
        let modificationTime: TimeInterval
    }

    private enum UpdateError: Error, CustomStringConvertible {
        case failed(String)

        var description: String {
            switch self {
            case .failed(let message): return message
            }
        }
    }

    private final class RedirectGuard: NSObject, URLSessionTaskDelegate {
        let trustedHost: String
        let allowHTTPForTests: Bool

        init(trustedHost: String, allowHTTPForTests: Bool) {
            self.trustedHost = trustedHost.lowercased()
            self.allowHTTPForTests = allowHTTPForTests
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            guard let url = request.url,
                  url.host?.lowercased() == trustedHost,
                  url.scheme == "https" || (allowHTTPForTests && url.scheme == "http")
            else {
                completionHandler(nil)
                return
            }
            completionHandler(request)
        }
    }

    private final class HTTPClient {
        private let session: URLSession
        private let trustedHost: String
        private let allowHTTPForTests: Bool

        init(trustedHost: String, allowHTTPForTests: Bool) {
            self.trustedHost = trustedHost.lowercased()
            self.allowHTTPForTests = allowHTTPForTests
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 180
            configuration.httpAdditionalHeaders = [
                "User-Agent": "Snoopy-CDN/1.1",
                "Accept-Encoding": "identity",
            ]
            let delegate = RedirectGuard(
                trustedHost: trustedHost,
                allowHTTPForTests: allowHTTPForTests
            )
            session = URLSession(
                configuration: configuration,
                delegate: delegate,
                delegateQueue: nil
            )
        }

        deinit { session.invalidateAndCancel() }

        func validate(_ url: URL) throws {
            guard url.host?.lowercased() == trustedHost else {
                throw UpdateError.failed("untrusted CDN host: \(url.host ?? "<none>")")
            }
            guard url.scheme == "https" || (allowHTTPForTests && url.scheme == "http")
            else {
                throw UpdateError.failed("CDN URL must use HTTPS")
            }
        }

        func data(from url: URL, maximumBytes: Int) throws -> Data {
            try validate(url)
            let semaphore = DispatchSemaphore(value: 0)
            let lock = NSLock()
            var result: Result<Data, Error>?
            let task = session.dataTask(with: url) { data, response, error in
                let resolved: Result<Data, Error>
                if let error {
                    resolved = .failure(error)
                } else if let http = response as? HTTPURLResponse,
                          !(200...299).contains(http.statusCode) {
                    resolved = .failure(
                        UpdateError.failed("HTTP \(http.statusCode) for \(url.absoluteString)")
                    )
                } else if let data, data.count <= maximumBytes {
                    resolved = .success(data)
                } else {
                    resolved = .failure(UpdateError.failed("response exceeded size limit"))
                }
                lock.lock()
                result = resolved
                lock.unlock()
                semaphore.signal()
            }
            task.resume()
            guard semaphore.wait(timeout: .now() + 60) == .success else {
                task.cancel()
                throw UpdateError.failed("timed out requesting \(url.absoluteString)")
            }
            lock.lock()
            let final = result
            lock.unlock()
            return try final?.get() ?? {
                throw UpdateError.failed("empty response for \(url.absoluteString)")
            }()
        }

        func download(from url: URL, staging: URL) throws {
            try validate(url)
            let semaphore = DispatchSemaphore(value: 0)
            let lock = NSLock()
            var result: Result<Void, Error>?
            let task = session.downloadTask(with: url) { temporary, response, error in
                let resolved: Result<Void, Error>
                do {
                    if let error { throw error }
                    guard let http = response as? HTTPURLResponse,
                          (200...299).contains(http.statusCode) else {
                        throw UpdateError.failed("non-success HTTP response")
                    }
                    guard let temporary else {
                        throw UpdateError.failed("download did not produce a file")
                    }
                    try? FileManager.default.removeItem(at: staging)
                    try FileManager.default.copyItem(at: temporary, to: staging)
                    resolved = .success(())
                } catch {
                    resolved = .failure(error)
                }
                lock.lock()
                result = resolved
                lock.unlock()
                semaphore.signal()
            }
            task.resume()
            guard semaphore.wait(timeout: .now() + 240) == .success else {
                task.cancel()
                throw UpdateError.failed("timed out downloading \(url.absoluteString)")
            }
            lock.lock()
            let final = result
            lock.unlock()
            try final?.get() ?? {
                throw UpdateError.failed("download returned no result")
            }()
        }
    }

    private let queue = DispatchQueue(
        label: "local.snoopy.cdn-updater",
        qos: .utility
    )
    private var updateInProgress = false
    private var lastCheck = Date.distantPast

    private init() {}

    func checkForUpdates(bundle: Bundle) {
        let environment = ProcessInfo.processInfo.environment
        if Self.truthy(environment["SNOOPY_DISABLE_CDN_UPDATE"]) { return }
        guard let bundledManifest = bundle.url(
            forResource: "cdn-manifest",
            withExtension: "json"
        ) else {
            return
        }
        let minimumInterval = max(
            0,
            Double(environment["SNOOPY_CDN_MIN_CHECK_INTERVAL"] ?? "") ?? 30
        )
        queue.async { [weak self] in
            guard let self else { return }
            let now = Date()
            guard !self.updateInProgress,
                  now.timeIntervalSince(self.lastCheck) >= minimumInterval else {
                return
            }
            self.updateInProgress = true
            self.lastCheck = now
            defer { self.updateInProgress = false }
            do {
                try self.performUpdate(
                    bundledManifest: bundledManifest,
                    environment: environment
                )
            } catch {
                NSLog("Snoopy CDN update skipped: %@", String(describing: error))
            }
        }
    }

    private func performUpdate(
        bundledManifest: URL,
        environment: [String: String]
    ) throws {
        let decoder = JSONDecoder()
        let bootstrapData = try Data(contentsOf: bundledManifest)
        let bootstrap = try decoder.decode(Manifest.self, from: bootstrapData)
        let allowHTTP = Self.truthy(
            environment["SNOOPY_CDN_ALLOW_HTTP_FOR_TESTS"]
        )
        let bootstrapBase = try validatedBaseURL(
            bootstrap.baseURL,
            allowHTTPForTests: allowHTTP
        )
        guard let trustedHost = bootstrapBase.host else {
            throw UpdateError.failed("CDN bootstrap URL has no host")
        }
        let client = HTTPClient(
            trustedHost: trustedHost,
            allowHTTPForTests: allowHTTP
        )
        let remoteManifestURL = bootstrapBase
            .appendingPathComponent("cdn-manifest.json", isDirectory: false)
        let manifest: Manifest
        do {
            let remoteData = try client.data(
                from: remoteManifestURL,
                maximumBytes: 5 * 1024 * 1024
            )
            manifest = try decoder.decode(Manifest.self, from: remoteData)
        } catch {
            NSLog(
                "Snoopy CDN manifest refresh failed; using bundled manifest: %@",
                String(describing: error)
            )
            manifest = bootstrap
        }
        let baseURL = try validatedBaseURL(
            manifest.baseURL,
            allowHTTPForTests: allowHTTP
        )
        guard baseURL.host?.lowercased() == trustedHost.lowercased() else {
            throw UpdateError.failed("remote manifest changed the trusted CDN host")
        }
        let entries = try validatedEntries(manifest.files)
        let destination = try destinationRoot(environment: environment)
        let receiptURL = destination
            .deletingLastPathComponent()
            .appendingPathComponent("cdn-state-v1.json")
        var receipt = loadReceipt(at: receiptURL, baseURL: baseURL.absoluteString)

        var downloaded = 0
        var verified = 0
        for entry in entries {
            let destinationURL = try safeDestination(
                root: destination,
                relativePath: entry.path
            )
            if try matches(
                entry,
                file: destinationURL,
                receiptEntry: receipt.files[entry.path]
            ) {
                receipt.files[entry.path] = try receiptEntry(
                    for: destinationURL,
                    entry: entry
                )
                verified += 1
                continue
            }
            let remoteURL = try mediaURL(
                for: entry,
                baseURL: baseURL,
                trustedHost: trustedHost,
                allowHTTPForTests: allowHTTP
            )
            let staging = destinationURL.deletingLastPathComponent()
                .appendingPathComponent(
                    ".\(destinationURL.lastPathComponent).\(UUID().uuidString).download"
                )
            defer { try? FileManager.default.removeItem(at: staging) }
            try client.download(from: remoteURL, staging: staging)
            guard try fileSize(staging) == entry.size,
                  try sha256(staging) == entry.sha256.lowercased() else {
                throw UpdateError.failed(
                    "download verification failed: \(entry.path)"
                )
            }
            try install(staging, at: destinationURL)
            receipt.files[entry.path] = try receiptEntry(
                for: destinationURL,
                entry: entry
            )
            downloaded += 1
        }
        receipt.baseURL = baseURL.absoluteString
        try writeReceipt(receipt, to: receiptURL)
        NSLog(
            "Snoopy CDN media ready: %d downloaded, %d unchanged, %d total",
            downloaded, verified, entries.count
        )
    }

    private func validatedBaseURL(
        _ value: String,
        allowHTTPForTests: Bool
    ) throws -> URL {
        guard let url = URL(string: value),
              url.host != nil,
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil,
              url.scheme == "https"
                || (allowHTTPForTests && url.scheme == "http") else {
            throw UpdateError.failed("invalid CDN base URL")
        }
        return url
    }

    private func validatedEntries(_ entries: [Entry]) throws -> [Entry] {
        guard !entries.isEmpty, entries.count <= 2_000 else {
            throw UpdateError.failed("invalid CDN manifest file count")
        }
        var paths: Set<String> = []
        var total: Int64 = 0
        for entry in entries {
            guard entry.size > 0, entry.size < 2 * 1024 * 1024 * 1024 else {
                throw UpdateError.failed("invalid media size: \(entry.path)")
            }
            total += entry.size
            guard total < 50 * 1024 * 1024 * 1024 else {
                throw UpdateError.failed("CDN manifest is too large")
            }
            let digest = entry.sha256.lowercased()
            guard digest.count == 64,
                  digest.allSatisfy({ $0.isHexDigit }),
                  paths.insert(entry.path).inserted else {
                throw UpdateError.failed("invalid or duplicate CDN entry: \(entry.path)")
            }
            _ = try safeComponents(entry.path)
        }
        return entries
    }

    private func safeComponents(_ relativePath: String) throws -> [String] {
        let components = relativePath.split(
            separator: "/",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard components.count == 2,
              components[0].hasSuffix(".icasset"),
              !components[0].contains(".."),
              !components[1].contains(".."),
              URL(fileURLWithPath: components[1]).pathExtension.lowercased() == "mov",
              URL(fileURLWithPath: components[0]).lastPathComponent == components[0],
              URL(fileURLWithPath: components[1]).lastPathComponent == components[1]
        else {
            throw UpdateError.failed("unsafe media path: \(relativePath)")
        }
        return components
    }

    private func destinationRoot(
        environment: [String: String]
    ) throws -> URL {
        var candidates: [URL] = []
        if let override = environment["SNOOPY_CDN_DESTINATION"], !override.isEmpty {
            candidates.append(URL(
                fileURLWithPath: (override as NSString).expandingTildeInPath,
                isDirectory: true
            ))
        } else {
            let direct = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent("Snoopy", isDirectory: true)
                .appendingPathComponent("Assets", isDirectory: true)
                .appendingPathComponent("Resolved", isDirectory: true)
            candidates.append(direct)
            if let processSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first {
                candidates.append(
                    processSupport
                        .appendingPathComponent("Snoopy", isDirectory: true)
                        .appendingPathComponent("Assets", isDirectory: true)
                        .appendingPathComponent("Resolved", isDirectory: true)
                )
            }
        }
        var lastError: Error?
        for candidate in candidates {
            do {
                try FileManager.default.createDirectory(
                    at: candidate,
                    withIntermediateDirectories: true
                )
                let values = try candidate.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                )
                guard values.isDirectory == true,
                      values.isSymbolicLink != true else {
                    throw UpdateError.failed("unsafe CDN destination root")
                }
                return candidate.standardizedFileURL
            } catch {
                lastError = error
            }
        }
        throw lastError ?? UpdateError.failed("no writable CDN destination")
    }

    private func safeDestination(
        root: URL,
        relativePath: String
    ) throws -> URL {
        let components = try safeComponents(relativePath)
        let assetDirectory = root.appendingPathComponent(
            components[0],
            isDirectory: true
        )
        if FileManager.default.fileExists(atPath: assetDirectory.path) {
            let values = try assetDirectory.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw UpdateError.failed("unsafe asset directory: \(relativePath)")
            }
        } else {
            try FileManager.default.createDirectory(
                at: assetDirectory,
                withIntermediateDirectories: false
            )
        }
        let destination = assetDirectory.appendingPathComponent(components[1])
        if FileManager.default.fileExists(atPath: destination.path) {
            let values = try destination.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw UpdateError.failed("unsafe destination file: \(relativePath)")
            }
        }
        return destination
    }

    private func mediaURL(
        for entry: Entry,
        baseURL: URL,
        trustedHost: String,
        allowHTTPForTests: Bool
    ) throws -> URL {
        let components = try safeComponents(entry.path)
        let url: URL
        if let explicit = entry.url, !explicit.isEmpty {
            guard let parsed = URL(string: explicit) else {
                throw UpdateError.failed("invalid media URL: \(entry.path)")
            }
            url = parsed
        } else {
            url = baseURL
                .appendingPathComponent(components[0], isDirectory: true)
                .appendingPathComponent(components[1], isDirectory: false)
        }
        guard url.host?.lowercased() == trustedHost.lowercased(),
              url.user == nil,
              url.password == nil,
              url.fragment == nil,
              url.scheme == "https"
                || (allowHTTPForTests && url.scheme == "http") else {
            throw UpdateError.failed("untrusted media URL: \(entry.path)")
        }
        return url
    }

    private func matches(
        _ entry: Entry,
        file: URL,
        receiptEntry: ReceiptEntry?
    ) throws -> Bool {
        guard FileManager.default.fileExists(atPath: file.path),
              try fileSize(file) == entry.size else {
            return false
        }
        let modification = try modificationTime(file)
        if let receiptEntry,
           receiptEntry.size == entry.size,
           receiptEntry.sha256 == entry.sha256.lowercased(),
           abs(receiptEntry.modificationTime - modification) < 0.001 {
            return true
        }
        return try sha256(file) == entry.sha256.lowercased()
    }

    private func receiptEntry(
        for file: URL,
        entry: Entry
    ) throws -> ReceiptEntry {
        ReceiptEntry(
            size: try fileSize(file),
            sha256: entry.sha256.lowercased(),
            modificationTime: try modificationTime(file)
        )
    }

    private func loadReceipt(at url: URL, baseURL: String) -> Receipt {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(Receipt.self, from: data),
              decoded.schemaVersion == 1 else {
            return Receipt(baseURL: baseURL, files: [:])
        }
        return decoded
    }

    private func writeReceipt(_ receipt: Receipt, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try (encoder.encode(receipt) + Data([0x0a])).write(
            to: url,
            options: [.atomic]
        )
    }

    private func install(_ staging: URL, at destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(
                destination,
                withItemAt: staging,
                backupItemName: nil,
                options: []
            )
        } else {
            try FileManager.default.moveItem(at: staging, to: destination)
        }
    }

    private func fileSize(_ url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? -1
    }

    private func modificationTime(_ url: URL) throws -> TimeInterval {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
    }

    private func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func truthy(_ value: String?) -> Bool {
        guard let value else { return false }
        return ["1", "true", "yes", "on"].contains(value.lowercased())
    }
}
