import AppKit
import Darwin
import ScreenSaver

private enum RuntimeFailure: Error, CustomStringConvertible {
    case failed(String)
    var description: String {
        switch self { case .failed(let message): return message }
    }
}

@main
struct RuntimeSmoke {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw RuntimeFailure.failed("usage: RuntimeSmoke SAVER_PATH")
        }
        let url = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        guard let bundle = Bundle(url: url), bundle.load(),
              let type = bundle.principalClass as? ScreenSaverView.Type,
              let view = type.init(
                frame: NSRect(x: 0, y: 0, width: 1440, height: 900), isPreview: true
              ) else {
            throw RuntimeFailure.failed("unable to load saver principal class")
        }

        let window = NSWindow(
            contentRect: view.frame, styleMask: [.borderless],
            backing: .buffered, defer: false
        )
        window.contentView = view
        view.startAnimation()
        spin(seconds: 6)
        try require(
            view.layer?.sublayers?.isEmpty == false,
            "screen saver did not create an initial scene layer"
        )

        let environment = ProcessInfo.processInfo.environment
        let switchCount = Int(environment["SNOOPY_RUNTIME_SWITCHES"] ?? "") ?? 8
        let dwell = Double(environment["SNOOPY_RUNTIME_DWELL"] ?? "") ?? 3
        var peakResidentBytes: UInt64 = residentBytes()
        for index in 0..<switchCount {
            let selector = index.isMultiple(of: 2)
                ? NSSelectorFromString("forceNextSceneForTesting")
                : NSSelectorFromString("forceIdleSceneForTesting")
            guard view.responds(to: selector) else {
                throw RuntimeFailure.failed("missing runtime test selector")
            }
            view.perform(selector)
            spin(seconds: dwell)
            let layers = view.layer?.sublayers?.count ?? 0
            peakResidentBytes = max(peakResidentBytes, residentBytes())
            try require(layers <= 8, "root layer count accumulated to \(layers)")
            print(
                "switch \(index + 1): rootLayers=\(layers) "
                    + "rss=\(peakResidentBytes / 1_048_576)MiB"
            )
            fflush(stdout)
        }

        view.stopAnimation()
        spin(seconds: 1)
        try require(
            view.layer?.sublayers?.isEmpty != false,
            "root layers remained after stopAnimation"
        )
        let maximumRSSMiB = UInt64(
            Int(environment["SNOOPY_RUNTIME_MAX_RSS_MB"] ?? "") ?? 1_500
        )
        try require(
            peakResidentBytes < maximumRSSMiB * 1_048_576,
            "resident memory exceeded \(maximumRSSMiB) MiB: \(peakResidentBytes)"
        )
        print(
            "Runtime smoke passed: \(switchCount) forced scene changes, "
                + "peakRSS=\(peakResidentBytes / 1_048_576)MiB, clean shutdown"
        )
        window.contentView = nil
        window.close()
    }

    private static func spin(seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(
                mode: .default, before: min(deadline, Date().addingTimeInterval(0.05))
            )
        }
    }

    private static func require(
        _ value: @autoclosure () -> Bool, _ message: String
    ) throws {
        if !value() { throw RuntimeFailure.failed(message) }
    }

    private static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    $0,
                    &count
                )
            }
        }
        return status == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }
}
