import CoreGraphics
import Foundation
import ImageIO

private struct Result {
    let path: String
    let originalBytes: Int64
    let outputBytes: Int64
    let converted: Bool
}

private enum ConversionFailure: Error, CustomStringConvertible {
    case failed(String)
    var description: String {
        switch self { case .failed(let message): return message }
    }
}

@main
struct HEICDownscaler {
    static func main() throws {
        guard CommandLine.arguments.count >= 2 else {
            throw ConversionFailure.failed(
                "usage: downscale_heic_assets ROOT [MAX_PIXEL_SIZE] [QUALITY]"
            )
        }
        let root = URL(
            fileURLWithPath: (CommandLine.arguments[1] as NSString).expandingTildeInPath,
            isDirectory: true
        ).standardizedFileURL
        let maximum = Int(CommandLine.arguments.dropFirst(2).first ?? "") ?? 1920
        let quality = Double(CommandLine.arguments.dropFirst(3).first ?? "") ?? 0.85
        guard maximum >= 256, maximum <= 4096, (0.5...1).contains(quality) else {
            throw ConversionFailure.failed("unsafe maximum pixel size or quality")
        }
        guard root.path != "/", root.path != FileManager.default.homeDirectoryForCurrentUser.path,
              FileManager.default.fileExists(atPath: root.path) else {
            throw ConversionFailure.failed("unsafe or missing asset root: \(root.path)")
        }

        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else {
            throw ConversionFailure.failed("unable to enumerate \(root.path)")
        }
        var files: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            if url.pathExtension.lowercased() == "heic" { files.append(url) }
        }
        files.sort { $0.path < $1.path }
        guard !files.isEmpty else {
            throw ConversionFailure.failed("no HEIC files under \(root.path)")
        }

        let queue = OperationQueue()
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 2
        let lock = NSLock()
        var results: [Result] = []
        var failures: [String] = []
        for url in files {
            queue.addOperation {
                autoreleasepool {
                    do {
                        let result = try convert(
                            url, maximumPixelSize: maximum, quality: quality
                        )
                        lock.lock(); results.append(result); lock.unlock()
                    } catch {
                        lock.lock()
                        failures.append("\(url.path): \(error)")
                        lock.unlock()
                    }
                }
            }
        }
        queue.waitUntilAllOperationsAreFinished()
        if !failures.isEmpty {
            failures.prefix(100).forEach { fputs("ERROR: \($0)\n", stderr) }
            throw ConversionFailure.failed("\(failures.count) HEIC conversion failures")
        }

        let converted = results.filter(\.converted)
        let before = converted.reduce(Int64(0)) { $0 + $1.originalBytes }
        let after = converted.reduce(Int64(0)) { $0 + $1.outputBytes }
        let summary: [String: Any] = [
            "schemaVersion": 1,
            "fileCount": results.count,
            "downscaledThisRun": converted.count,
            "maximumPixelSize": maximum,
            "bitsPerComponent": 8,
            "quality": quality,
            "sourceBytesThisRun": before,
            "outputBytesThisRun": after,
        ]
        let summaryData = try JSONSerialization.data(
            withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]
        )
        try summaryData.write(
            to: root.appendingPathComponent("heic-build.json"), options: .atomic
        )
        print(
            "HEIC validation passed: \(results.count) files, "
                + "\(converted.count) downscaled, "
                + "\(before / 1_048_576) -> \(after / 1_048_576) MiB"
        )
    }

    private static func convert(
        _ url: URL, maximumPixelSize: Int, quality: Double
    ) throws -> Result {
        guard let source = CGImageSourceCreateWithURL(
            url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary
        ), let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [CFString: Any],
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        else {
            throw ConversionFailure.failed("unreadable HEIC metadata")
        }
        let originalBytes = Int64(
            (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        )
        if max(width, height) <= maximumPixelSize {
            let metadataDepth = (
                properties[kCGImagePropertyDepth] as? NSNumber
            )?.intValue
            if metadataDepth != 8 {
                guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                      image.bitsPerComponent == 8 else {
                    throw ConversionFailure.failed("HEIC is not 8-bit")
                }
            }
            return Result(
                path: url.path, originalBytes: originalBytes,
                outputBytes: originalBytes, converted: false
            )
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source, 0, options as CFDictionary
        ) else {
            throw ConversionFailure.failed("unable to decode HEIC")
        }
        let sourceHasAlpha = hasAlpha(image.alphaInfo)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(
            ".\(url.deletingPathExtension().lastPathComponent)-\(UUID().uuidString).heic"
        )
        guard let destination = CGImageDestinationCreateWithURL(
            temporary as CFURL, "public.heic" as CFString, 1, nil
        ) else {
            throw ConversionFailure.failed("unable to create HEIC destination")
        }
        let destinationProperties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
        ]
        CGImageDestinationAddImage(
            destination, image, destinationProperties as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: temporary)
            throw ConversionFailure.failed("unable to finalize HEIC")
        }
        do {
            guard let verification = CGImageSourceCreateWithURL(
                temporary as CFURL,
                [kCGImageSourceShouldCache: false] as CFDictionary
            ), let output = CGImageSourceCreateImageAtIndex(verification, 0, nil),
            max(output.width, output.height) <= maximumPixelSize,
            output.bitsPerComponent == 8,
            !sourceHasAlpha || hasAlpha(output.alphaInfo)
            else {
                throw ConversionFailure.failed(
                    "output lost size, 8-bit depth, or Alpha invariants"
                )
            }
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
            let outputBytes = Int64(
                (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            )
            return Result(
                path: url.path, originalBytes: originalBytes,
                outputBytes: outputBytes, converted: true
            )
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    private static func hasAlpha(_ info: CGImageAlphaInfo) -> Bool {
        switch info {
        case .first, .last, .premultipliedFirst, .premultipliedLast,
             .alphaOnly:
            return true
        default:
            return false
        }
    }
}
