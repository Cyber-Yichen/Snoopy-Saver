import Foundation

/// A small persistent diagnostic log for the CDN-lite edition. Standard and
/// 1080p builds continue to use the unified system log only. The file logger
/// is deliberately synchronous and bounded because ScreenSaverEngine can
/// terminate its plug-in process without a shutdown callback.
final class SnoopyDiagnostics {
    static let shared = SnoopyDiagnostics()

    private let lock = NSLock()
    private let formatter = ISO8601DateFormatter()
    private let sessionID = UUID().uuidString
    private var enabled = false
    private var logURL: URL?
    private var onceKeys: Set<String> = []
    private var rotationBytes: UInt64 = 5 * 1024 * 1024

    private init() {
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func start(bundle: Bundle) {
        let environment = ProcessInfo.processInfo.environment
        let forced = Self.truthy(environment["SNOOPY_FORCE_FILE_LOG"])
        let isCDNEdition = bundle.url(
            forResource: "cdn-manifest", withExtension: "json"
        ) != nil
        guard forced || isCDNEdition else { return }

        lock.lock()
        if !enabled {
            enabled = true
            if let override = UInt64(environment["SNOOPY_LOG_ROTATION_BYTES"] ?? ""),
               override >= 1_024 {
                rotationBytes = override
            }
            logURL = prepareLogURL(environment: environment)
        }
        let path = logURL?.path
        lock.unlock()

        log(
            "session",
            "begin id=\(sessionID) pid=\(ProcessInfo.processInfo.processIdentifier) "
                + "version=\(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown") "
                + "build=\(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown")"
        )
        if let path { NSLog("Snoopy CDN diagnostics: %@", path) }
    }

    func log(_ category: String, _ message: String) {
        let safeCategory = Self.sanitize(category, limit: 64)
        let safeMessage = Self.sanitize(message, limit: 4_096)
        NSLog("Snoopy [%@] %@", safeCategory, safeMessage)

        lock.lock()
        defer { lock.unlock() }
        guard enabled else { return }
        appendLocked(
            "\(formatter.string(from: Date())) [\(safeCategory)] \(safeMessage)\n"
        )
    }

    func logOnce(key: String, category: String, message: String) {
        lock.lock()
        guard enabled, onceKeys.insert(key).inserted else {
            lock.unlock()
            return
        }
        lock.unlock()
        log(category, message)
    }

    private func prepareLogURL(environment: [String: String]) -> URL? {
        var roots: [URL] = []
        if let override = environment["SNOOPY_LOG_ROOT"], !override.isEmpty {
            roots.append(URL(
                fileURLWithPath: (override as NSString).expandingTildeInPath,
                isDirectory: true
            ))
        } else {
            if let library = FileManager.default.urls(
                for: .libraryDirectory, in: .userDomainMask
            ).first {
                roots.append(
                    library.appendingPathComponent("Logs", isDirectory: true)
                        .appendingPathComponent("Snoopy", isDirectory: true)
                )
            }
            roots.append(
                FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library", isDirectory: true)
                    .appendingPathComponent("Logs", isDirectory: true)
                    .appendingPathComponent("Snoopy", isDirectory: true)
            )
        }

        for root in roots {
            let url = root.appendingPathComponent("CDN-Lite.log")
            do {
                try FileManager.default.createDirectory(
                    at: root, withIntermediateDirectories: true
                )
                if !FileManager.default.fileExists(atPath: url.path) {
                    guard FileManager.default.createFile(
                        atPath: url.path, contents: nil
                    ) else { continue }
                }
                let handle = try FileHandle(forWritingTo: url)
                try handle.close()
                return url
            } catch {
                NSLog("Snoopy diagnostics path unavailable: %@", String(describing: error))
            }
        }
        return nil
    }

    private func appendLocked(_ line: String) {
        guard let logURL, let data = line.data(using: .utf8) else { return }
        do {
            try rotateIfNeededLocked(logURL)
            let handle = try FileHandle(forWritingTo: logURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            NSLog("Snoopy diagnostics write failed: %@", String(describing: error))
        }
    }

    private func rotateIfNeededLocked(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        guard size >= rotationBytes else { return }
        let backup = url.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: backup)
        try FileManager.default.moveItem(at: url, to: backup)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private static func sanitize(_ value: String, limit: Int) -> String {
        let flattened = value.replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        return String(flattened.prefix(limit))
    }

    private static func truthy(_ value: String?) -> Bool {
        guard let value else { return false }
        return ["1", "true", "yes", "on"].contains(value.lowercased())
    }
}
