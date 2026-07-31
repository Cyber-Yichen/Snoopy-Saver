import AVFoundation
import CoreMedia
import Foundation

private struct Report: Decodable {
    let alphaMovieCount: Int
    let files: [Record]
}

private struct Record: Decodable {
    let destination: String
}

private enum ValidationError: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): return message
        }
    }
}

private func containsAlpha(_ description: CMFormatDescription) -> Bool {
    guard let extensions = CMFormatDescriptionGetExtensions(description) as NSDictionary? else {
        return false
    }
    return (extensions["ContainsAlphaChannel"] as? NSNumber)?.boolValue == true
        || extensions["AlphaChannelMode"] != nil
}

@main
private struct ValidateAlphaMovies {
    static func main() async {
        do {
            guard CommandLine.arguments.count == 2 else {
                throw ValidationError.failed(
                    "usage: validate_alpha_movies NORMALIZED_ROOT"
                )
            }
            let root = URL(
                fileURLWithPath: CommandLine.arguments[1], isDirectory: true
            ).standardizedFileURL
            let reportURL = root.appendingPathComponent("alpha-preservation.json")
            let report = try JSONDecoder().decode(
                Report.self,
                from: Data(contentsOf: reportURL)
            )
            guard report.alphaMovieCount == report.files.count,
                  report.alphaMovieCount > 0 else {
                throw ValidationError.failed("invalid alpha movie count")
            }
            var seen: Set<String> = []
            for (index, record) in report.files.enumerated() {
                let components = record.destination.split(separator: "/")
                guard components.count >= 2,
                      !components.contains(".."),
                      record.destination.lowercased().hasSuffix(".mov"),
                      seen.insert(record.destination).inserted else {
                    throw ValidationError.failed(
                        "unsafe or duplicate path: \(record.destination)"
                    )
                }
                let movie = root
                    .appendingPathComponent("Assets", isDirectory: true)
                    .appendingPathComponent("Resolved", isDirectory: true)
                    .appendingPathComponent(record.destination)
                let asset = AVURLAsset(url: movie)
                guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                    throw ValidationError.failed("missing video track: \(record.destination)")
                }
                let descriptions = try await track.load(.formatDescriptions)
                guard descriptions.contains(where: containsAlpha) else {
                    throw ValidationError.failed("missing alpha: \(record.destination)")
                }
                let size = try await track.load(.naturalSize)
                guard abs(size.width) <= 1920, abs(size.height) <= 1080 else {
                    throw ValidationError.failed(
                        "oversized alpha movie \(Int(abs(size.width)))x\(Int(abs(size.height))): "
                            + record.destination
                    )
                }
                if (index + 1).isMultiple(of: 50) {
                    print("verified \(index + 1)/\(report.files.count)")
                }
            }
            print(
                "Alpha validation passed: \(report.files.count) HEVC-alpha movies, "
                    + "all <=1920x1080"
            )
        } catch {
            fputs("validate_alpha_movies: \(error)\n", stderr)
            exit(1)
        }
    }
}
