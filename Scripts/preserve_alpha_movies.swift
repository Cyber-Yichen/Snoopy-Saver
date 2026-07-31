import AVFoundation
import CoreMedia
import Foundation

private struct Candidate {
    let sourceURL: URL
    let sourceRelativePath: String
    let destinationRelativePath: String
    let width: Int
    let height: Int
    let packagePriority: Int
}

private struct PreservationRecord: Codable {
    let destination: String
    let source: String
    let width: Int
    let height: Int
    let bytes: Int64
    let mode: String
}

private struct PreservationReport: Codable {
    let schemaVersion: Int
    let alphaMovieCount: Int
    let maximumResolution: String
    let files: [PreservationRecord]
}

private enum PreservationError: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): return message
        }
    }
}

private struct Package {
    let directory: URL
    let priority: Int
}

private func packages(in source: URL) -> [Package] {
    let fileManager = FileManager.default
    var result: [Package] = []
    for (offset, name) in ["DefaultAssetBundle", "DefaultAssetBundleV2"].enumerated() {
        let directory = source.appendingPathComponent(name, isDirectory: true)
        if fileManager.fileExists(atPath: directory.path) {
            result.append(Package(directory: directory, priority: offset + 1))
        }
    }
    let optional = source
        .appendingPathComponent("OptionalDownloads", isDirectory: true)
        .appendingPathComponent("expanded", isDirectory: true)
    if let children = try? fileManager.contentsOfDirectory(
        at: optional,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    ) {
        for child in children.sorted(by: { $0.path < $1.path }) {
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true {
                result.append(Package(directory: child, priority: 100))
            }
        }
    }
    return result
}

private func assetDirectories(in package: URL) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(
        at: package,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    ).filter {
        $0.pathExtension == "icasset"
            && ((try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true)
    }.sorted { $0.path < $1.path }
}

private func movies(in asset: URL) -> [URL] {
    guard let enumerator = FileManager.default.enumerator(
        at: asset,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles, .skipsPackageDescendants]
    ) else {
        return []
    }
    var result: [URL] = []
    for case let url as URL in enumerator where url.pathExtension.lowercased() == "mov" {
        result.append(url)
    }
    return result.sorted { $0.path < $1.path }
}

private func relativePath(of child: URL, under parent: URL) throws -> String {
    let parentPath = parent.standardizedFileURL.path
    let prefix = parentPath.hasSuffix("/") ? parentPath : parentPath + "/"
    let childPath = child.standardizedFileURL.path
    guard childPath.hasPrefix(prefix) else {
        throw PreservationError.failed("\(child.path) is outside \(parent.path)")
    }
    return String(childPath.dropFirst(prefix.count))
}

private func hasAlpha(_ description: CMFormatDescription) -> Bool {
    guard let extensions = CMFormatDescriptionGetExtensions(description) as NSDictionary? else {
        return false
    }
    if let value = extensions["ContainsAlphaChannel"] as? NSNumber {
        return value.boolValue
    }
    return extensions["AlphaChannelMode"] != nil
}

private func inspectMovie(
    _ movie: URL,
    sourceRoot: URL,
    asset: URL,
    priority: Int
) async throws -> Candidate? {
    let audiovisualAsset = AVURLAsset(url: movie)
    guard let track = try await audiovisualAsset.loadTracks(withMediaType: .video).first else {
        throw PreservationError.failed("no video track: \(movie.path)")
    }
    let descriptions = try await track.load(.formatDescriptions)
    guard descriptions.contains(where: hasAlpha) else { return nil }
    let size = try await track.load(.naturalSize)
    let movieWithinAsset = try relativePath(of: movie, under: asset)
    return Candidate(
        sourceURL: movie,
        sourceRelativePath: try relativePath(of: movie, under: sourceRoot),
        destinationRelativePath: asset.lastPathComponent + "/" + movieWithinAsset,
        width: Int(abs(size.width.rounded())),
        height: Int(abs(size.height.rounded())),
        packagePriority: priority
    )
}

private func choose(
    _ candidates: [Candidate],
    maxWidth: Int,
    maxHeight: Int
) -> (candidate: Candidate, requiresDownscale: Bool) {
    let fitting = candidates.filter {
        $0.width <= maxWidth && $0.height <= maxHeight
    }
    let pool = fitting.isEmpty ? candidates : fitting
    let candidate = pool.max {
        let left = (
            $0.width * $0.height,
            $0.packagePriority,
            $0.sourceRelativePath
        )
        let right = (
            $1.width * $1.height,
            $1.packagePriority,
            $1.sourceRelativePath
        )
        return left < right
    }!
    return (candidate, fitting.isEmpty)
}

private func replaceFile(at destination: URL, with source: URL) throws {
    let fileManager = FileManager.default
    try fileManager.createDirectory(
        at: destination.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let temporary = destination.deletingLastPathComponent()
        .appendingPathComponent(".\(destination.lastPathComponent).alpha-\(UUID().uuidString)")
    defer { try? fileManager.removeItem(at: temporary) }
    try fileManager.copyItem(at: source, to: temporary)
    if fileManager.fileExists(atPath: destination.path) {
        _ = try fileManager.replaceItemAt(
            destination,
            withItemAt: temporary,
            backupItemName: nil,
            options: []
        )
    } else {
        try fileManager.moveItem(at: temporary, to: destination)
    }
}

private func downscaleAlpha(
    source: URL,
    destination: URL,
    maxWidth: Int,
    maxHeight: Int
) async throws {
    guard maxWidth == 1920 && maxHeight == 1080 else {
        throw PreservationError.failed(
            "native HEVC-alpha export currently supports a 1920x1080 target"
        )
    }
    let asset = AVURLAsset(url: source)
    let preset = AVAssetExportPresetHEVC1920x1080WithAlpha
    guard let export = AVAssetExportSession(asset: asset, presetName: preset) else {
        throw PreservationError.failed(
            "HEVC-with-alpha 1920x1080 export is unavailable for \(source.path)"
        )
    }
    let fileManager = FileManager.default
    try fileManager.createDirectory(
        at: destination.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let temporary = destination.deletingLastPathComponent()
        .appendingPathComponent(".\(destination.lastPathComponent).alpha-\(UUID().uuidString).mov")
    defer { try? fileManager.removeItem(at: temporary) }
    export.shouldOptimizeForNetworkUse = true
    try await export.export(to: temporary, as: .mov)
    if fileManager.fileExists(atPath: destination.path) {
        _ = try fileManager.replaceItemAt(
            destination,
            withItemAt: temporary,
            backupItemName: nil,
            options: []
        )
    } else {
        try fileManager.moveItem(at: temporary, to: destination)
    }
}

private func verifyAlpha(at movie: URL, maxWidth: Int, maxHeight: Int) async throws {
    let asset = AVURLAsset(url: movie)
    guard let track = try await asset.loadTracks(withMediaType: .video).first else {
        throw PreservationError.failed("no video track after copy: \(movie.path)")
    }
    let descriptions = try await track.load(.formatDescriptions)
    guard descriptions.contains(where: hasAlpha) else {
        throw PreservationError.failed("alpha was not preserved: \(movie.path)")
    }
    let size = try await track.load(.naturalSize)
    if Int(abs(size.width.rounded())) > maxWidth || Int(abs(size.height.rounded())) > maxHeight {
        throw PreservationError.failed(
            "no <=\(maxWidth)x\(maxHeight) Apple alpha source exists for \(movie.lastPathComponent); "
                + "selected \(Int(abs(size.width)))x\(Int(abs(size.height)))"
        )
    }
}

@main
private struct PreserveAlphaMovies {
    static func main() async {
        do {
            try await run()
        } catch {
            fputs("preserve_alpha_movies: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func run() async throws {
        guard (3...5).contains(CommandLine.arguments.count) else {
            throw PreservationError.failed(
                "usage: preserve_alpha_movies SOURCE_ROOT NORMALIZED_ROOT "
                    + "[MAX_WIDTH] [MAX_HEIGHT]"
            )
        }
        let source = URL(
            fileURLWithPath: CommandLine.arguments[1], isDirectory: true
        ).standardizedFileURL.resolvingSymlinksInPath()
        let normalized = URL(
            fileURLWithPath: CommandLine.arguments[2], isDirectory: true
        ).standardizedFileURL
        let maxWidth = CommandLine.arguments.count >= 4
            ? (Int(CommandLine.arguments[3]) ?? 1920) : 1920
        let maxHeight = CommandLine.arguments.count >= 5
            ? (Int(CommandLine.arguments[4]) ?? 1080) : 1080
        let resolved = normalized
            .appendingPathComponent("Assets", isDirectory: true)
            .appendingPathComponent("Resolved", isDirectory: true)
        guard FileManager.default.fileExists(atPath: resolved.path) else {
            throw PreservationError.failed("missing normalized tree: \(resolved.path)")
        }

        var grouped: [String: [Candidate]] = [:]
        for package in packages(in: source) {
            for asset in try assetDirectories(in: package.directory) {
                for movie in movies(in: asset) {
                    if let candidate = try await inspectMovie(
                        movie,
                        sourceRoot: source,
                        asset: asset,
                        priority: package.priority
                    ) {
                        grouped[candidate.destinationRelativePath, default: []]
                            .append(candidate)
                    }
                }
            }
        }
        guard !grouped.isEmpty else {
            throw PreservationError.failed("no Apple alpha movies found under \(source.path)")
        }

        var records: [PreservationRecord] = []
        for destinationRelativePath in grouped.keys.sorted() {
            let selection = choose(
                grouped[destinationRelativePath]!,
                maxWidth: maxWidth,
                maxHeight: maxHeight
            )
            let candidate = selection.candidate
            let destination = resolved.appendingPathComponent(destinationRelativePath)
            guard FileManager.default.fileExists(atPath: destination.path) else {
                throw PreservationError.failed(
                    "normalized tree is missing alpha destination: \(destination.path)"
                )
            }
            let mode: String
            if selection.requiresDownscale {
                try await downscaleAlpha(
                    source: candidate.sourceURL,
                    destination: destination,
                    maxWidth: maxWidth,
                    maxHeight: maxHeight
                )
                mode = "nativeHEVCWithAlpha"
            } else {
                try replaceFile(at: destination, with: candidate.sourceURL)
                mode = "originalApple1080p"
            }
            try await verifyAlpha(
                at: destination,
                maxWidth: maxWidth,
                maxHeight: maxHeight
            )
            let attributes = try FileManager.default.attributesOfItem(
                atPath: destination.path
            )
            let outputWidth = selection.requiresDownscale ? maxWidth : candidate.width
            let outputHeight = selection.requiresDownscale ? maxHeight : candidate.height
            records.append(PreservationRecord(
                destination: destinationRelativePath,
                source: candidate.sourceRelativePath,
                width: outputWidth,
                height: outputHeight,
                bytes: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
                mode: mode
            ))
            print(
                "[\(records.count)/\(grouped.count)] \(destinationRelativePath) "
                    + "<- \(candidate.width)x\(candidate.height) \(mode)"
            )
        }

        let report = PreservationReport(
            schemaVersion: 1,
            alphaMovieCount: records.count,
            maximumResolution: "\(maxWidth)x\(maxHeight)",
            files: records
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(report) + Data([0x0a])
        try data.write(
            to: normalized.appendingPathComponent("alpha-preservation.json"),
            options: .atomic
        )
        print(
            "Preserved and verified \(records.count) Apple HEVC-alpha movies at "
                + "or below \(maxWidth)x\(maxHeight)"
        )
    }
}
