import Foundation

private enum SmokeError: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): return message
        }
    }
}

@main
private struct CDNUpdaterSmoke {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else {
            throw SmokeError.failed(
                "usage: CDNUpdaterSmoke BUNDLE DESTINATION_ROOT"
            )
        }
        let bundleURL = URL(
            fileURLWithPath: CommandLine.arguments[1],
            isDirectory: true
        )
        let destination = URL(
            fileURLWithPath: CommandLine.arguments[2],
            isDirectory: true
        )
        guard let bundle = Bundle(url: bundleURL) else {
            throw SmokeError.failed("unable to open fixture bundle")
        }
        let media = destination
            .appendingPathComponent("Fixture.icasset", isDirectory: true)
            .appendingPathComponent("Fixture.mov")
        let state = destination.deletingLastPathComponent()
            .appendingPathComponent("cdn-state-v1.json")

        CDNMediaUpdater.shared.checkForUpdates(bundle: bundle)
        try waitUntil(timeout: 15) {
            FileManager.default.fileExists(atPath: media.path)
                && FileManager.default.fileExists(atPath: state.path)
        }
        let firstData = try Data(contentsOf: media)
        guard firstData == Data("alpha-fixture\n".utf8) else {
            throw SmokeError.failed("downloaded media content mismatch")
        }
        let firstModification = try modificationTime(media)

        Thread.sleep(forTimeInterval: 0.2)
        CDNMediaUpdater.shared.checkForUpdates(bundle: bundle)
        Thread.sleep(forTimeInterval: 1.0)
        let secondModification = try modificationTime(media)
        guard firstModification == secondModification else {
            throw SmokeError.failed("unchanged media was downloaded again")
        }
        print(
            "CDN updater smoke passed: first run downloaded 1 file; "
                + "second run reused the verified local file"
        )
    }

    private static func waitUntil(
        timeout: TimeInterval,
        condition: () -> Bool
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(
                mode: .default,
                before: min(deadline, Date().addingTimeInterval(0.05))
            )
        }
        throw SmokeError.failed("timed out waiting for CDN updater")
    }

    private static func modificationTime(_ url: URL) throws -> Date {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let date = attributes[.modificationDate] as? Date else {
            throw SmokeError.failed("missing modification date")
        }
        return date
    }
}
