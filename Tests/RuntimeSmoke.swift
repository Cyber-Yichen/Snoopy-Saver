import AppKit
import AVFoundation
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
        let arguments = CommandLine.arguments
        let manualPreview = arguments.count == 3 && arguments[2] == "--preview"
        guard arguments.count == 2 || manualPreview else {
            throw RuntimeFailure.failed("usage: RuntimeSmoke SAVER_PATH [--preview]")
        }
        let app = NSApplication.shared
        let url = URL(fileURLWithPath: arguments[1], isDirectory: true)
        guard let bundle = Bundle(url: url), bundle.load(),
              let saverType = bundle.principalClass as? ScreenSaverView.Type,
              let view = saverType.init(
                frame: NSRect(x: 0, y: 0, width: 1440, height: 900), isPreview: true
              ) else {
            throw RuntimeFailure.failed("unable to load saver principal class")
        }

        let window = NSWindow(
            contentRect: view.frame, styleMask: manualPreview ? [.titled, .closable, .miniaturizable, .resizable] : [.borderless],
            backing: .buffered, defer: false
        )
        window.contentView = view
        if manualPreview {
            app.setActivationPolicy(.regular)
            let delegate = PreviewWindowDelegate(view: view)
            window.delegate = delegate
            window.isReleasedWhenClosed = false
            window.title = "Snoopy Beta Preview"
            window.center()
            window.makeKeyAndOrderFront(nil)
            app.activate(ignoringOtherApps: true)
            view.startAnimation()
            withExtendedLifetime(delegate) { app.run() }
            return
        }
        window.orderFront(nil)
        defer {
            view.stopAnimation()
            window.contentView = nil
            window.close()
        }
        var peakResidentBytes = residentBytes()
        var presentedVideoSizes: Set<String> = []
        let samplePlayback = {
            peakResidentBytes = max(peakResidentBytes, residentBytes())
            for scene in rootLayers(of: view) {
                for layer in scene.sublayers ?? [] {
                    guard let video = layer as? AVPlayerLayer, video.videoGravity == .resizeAspectFill,
                          video.isReadyForDisplay,
                          let size = video.player?.currentItem?.presentationSize else { continue }
                    presentedVideoSizes.insert("\(Int(size.width))×\(Int(size.height))")
                }
            }
        }
        view.startAnimation()
        spin(seconds: 6, sample: samplePlayback)
        try require(
            !rootLayers(of: view).isEmpty,
            "screen saver did not create an initial scene layer"
        )

        let environment = ProcessInfo.processInfo.environment
        let switchCount = Int(environment["SNOOPY_RUNTIME_SWITCHES"] ?? "") ?? 8
        let dwell = Double(environment["SNOOPY_RUNTIME_DWELL"] ?? "") ?? 3
        for index in 0..<switchCount {
            let selector = index.isMultiple(of: 2)
                ? NSSelectorFromString("forceNextSceneForTesting")
                : NSSelectorFromString("forceIdleSceneForTesting")
            guard view.responds(to: selector) else {
                throw RuntimeFailure.failed("missing runtime test selector")
            }
            view.perform(selector)
            spin(seconds: dwell, sample: samplePlayback)
            let layers = rootLayers(of: view).count
            try require(layers <= 3, "root layer count accumulated to \(layers)")
            print(
                "switch \(index + 1): rootLayers=\(layers) "
                    + "rss=\(peakResidentBytes / 1_048_576)MiB"
            )
            fflush(stdout)
        }

        let forceIdle = NSSelectorFromString("forceIdleSceneForTesting")
        let forceActive = NSSelectorFromString("forceNextSceneForTesting")
        let interruptedSwitches = 12
        for index in 0..<interruptedSwitches {
            view.perform(index.isMultiple(of: 2) ? forceActive : forceIdle)
            let layers = rootLayers(of: view).count
            peakResidentBytes = max(peakResidentBytes, residentBytes())
            try require(layers <= 3, "interrupted transitions left \(layers) attached root layers")
        }
        spin(seconds: 3, sample: samplePlayback)
        let remainingLayers = rootLayers(of: view)
        let remainingDescriptions = remainingLayers.map { layer in
            "\(type(of: layer)) opacity=\(layer.opacity) masked=\(layer.mask != nil) children=\(layer.sublayers?.count ?? 0)"
        }
        try require(
            remainingLayers.count == 1,
            "interrupted transitions did not settle to one scene: \(remainingDescriptions)"
        )
        try require(!presentedVideoSizes.isEmpty, "no AVPlayerLayer reported a video frame ready for display")

        view.stopAnimation()
        spin(seconds: 1)
        try require(
            rootLayers(of: view).isEmpty,
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
            "Runtime smoke passed: \(switchCount) normal and \(interruptedSwitches) interrupted scene changes, "
                + "peakRSS=\(peakResidentBytes / 1_048_576)MiB, clean shutdown, "
                + "video sizes=\(presentedVideoSizes.sorted().joined(separator: ", "))"
        )
    }

    private static func rootLayers(of view: ScreenSaverView) -> [CALayer] {
        // AppKit may also insert a private ContentLayer behind the saver layers.
        view.layer?.sublayers?.filter { type(of: $0) == CALayer.self } ?? []
    }

    private static func spin(seconds: TimeInterval, sample: () -> Void = {}) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(
                mode: .default, before: min(deadline, Date().addingTimeInterval(0.05))
            )
            sample()
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

private final class PreviewWindowDelegate: NSObject, NSWindowDelegate {
    private weak var view: ScreenSaverView?

    init(view: ScreenSaverView) {
        self.view = view
    }

    func windowWillClose(_ notification: Notification) {
        view?.stopAnimation()
        NSApplication.shared.terminate(nil)
    }
}
