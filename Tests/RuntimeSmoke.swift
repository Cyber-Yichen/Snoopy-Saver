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
        let environment = ProcessInfo.processInfo.environment
        var peakResidentBytes = residentBytes()
        var presentedVideoSizes: Set<String> = []
        var maskFrames: [String: Set<ObjectIdentifier>] = [:]
        var outlineFrames: [String: Set<ObjectIdentifier>] = [:]
        var lowestOutlineDensity = Double.infinity
        var lowestPoseDensity = Double.infinity
        var earlyVideoReveal = false
        var uncoveredTransition = false
        var observedContinuousReveal = false
        var changedRevealCharacter = false
        var invalidHideHandoff = false
        var revealingScene: CALayer?
        var revealedBase: ObjectIdentifier?
        var phasesInCurrentSwitch: Set<String> = []
        var transitionCaptures: [String: Process] = [:]
        let samplePlayback = {
            peakResidentBytes = max(peakResidentBytes, residentBytes())
            let layers = rootLayers(of: view)
            let outlineLayer = layers.first { $0.name?.hasPrefix("snoopyTransitionOutline.") == true }
            if let tracked = revealingScene, !layers.contains(where: { $0 === tracked }) {
                revealingScene = nil
                revealedBase = nil
            }
            for (index, scene) in layers.enumerated() {
                let sprites = scene.sublayers ?? []
                let visibleBase = sprites.first { $0.name == "snoopyIdleBasePose" && !$0.isHidden && $0.opacity == 1 }
                if scene === revealingScene, outlineLayer == nil {
                    if let revealedBase {
                        let continues = visibleBase.map(ObjectIdentifier.init) == revealedBase
                        observedContinuousReveal = observedContinuousReveal || continues
                        changedRevealCharacter = changedRevealCharacter || !continues
                    }
                    revealingScene = nil
                    revealedBase = nil
                }
                if let name = outlineLayer?.name,
                   let outline = outlineLayer?.contents, let mask = scene.mask?.contents {
                    if name.hasSuffix(".reveal") {
                        if scene !== revealingScene {
                            revealingScene = scene
                            revealedBase = nil
                        }
                        let visibleID = visibleBase.map(ObjectIdentifier.init)
                        if let revealedBase {
                            changedRevealCharacter = changedRevealCharacter || visibleID != revealedBase
                        } else {
                            revealedBase = visibleID
                        }
                    } else if let action = sprites.first(where: { $0.name == "snoopyHideCharacter" }) as? AVPlayerLayer {
                        invalidHideHandoff = invalidHideHandoff || visibleBase != nil || !action.isReadyForDisplay
                    }
                    phasesInCurrentSwitch.insert(name)
                    maskFrames[name, default: []].insert(ObjectIdentifier(mask as AnyObject))
                    outlineFrames[name, default: []].insert(ObjectIdentifier(outline as AnyObject))
                    if let outlineLayer, outlineLayer.frame.width > 0 {
                        let image = outline as! CGImage
                        lowestOutlineDensity = min(lowestOutlineDensity, Double(CGFloat(image.width) / outlineLayer.frame.width))
                    }
                    let underlay = layers[..<index].last
                    let video = underlay?.sublayers?.compactMap { $0 as? AVPlayerLayer }.first
                    uncoveredTransition = uncoveredTransition
                        || underlay?.opacity != 1 || underlay?.mask != nil || underlay?.frame != scene.frame
                    earlyVideoReveal = earlyVideoReveal || video?.isReadyForDisplay != true
                    if transitionCaptures[name] == nil, (maskFrames[name]?.count ?? 0) >= 12,
                       let prefix = environment["SNOOPY_RUNTIME_TRANSITION_SCREENSHOTS"] {
                        let process = Process()
                        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                        process.arguments = ["-x", "-l", String(window.windowNumber), "\(prefix)-\(name).png"]
                        if (try? process.run()) != nil { transitionCaptures[name] = process }
                    }
                }
                for layer in scene.sublayers ?? [] {
                    if layer.name == "snoopyIdleBasePose", let contents = layer.contents, layer.frame.width > 0 {
                        let image = contents as! CGImage
                        lowestPoseDensity = min(lowestPoseDensity, Double(CGFloat(image.width) / layer.frame.width))
                    }
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

        if let idleSeconds = Double(environment["SNOOPY_RUNTIME_IDLE_SECONDS"] ?? ""), idleSeconds > 0 {
            let activity = NSSelectorFromString("idleActivityForTesting")
            try require(view.responds(to: activity), "missing IdleScene activity probe")
            view.perform(NSSelectorFromString("forceLongIdleSceneForTesting"))
            var observedCharacter = false
            var observedVisitor = false
            var overlap = false
            var capture: Process?
            spin(seconds: idleSeconds) {
                view.animateOneFrame()
                samplePlayback()
                let flags = (view.perform(activity)?.takeUnretainedValue() as? NSNumber)?.intValue ?? 0
                observedCharacter = observedCharacter || flags & 1 != 0
                observedVisitor = observedVisitor || flags & 2 != 0
                overlap = overlap || (flags & 2 != 0 && flags & 5 != 0)
                if capture == nil, flags & 3 != 0,
                   let path = environment["SNOOPY_RUNTIME_SCREENSHOT"],
                   rootLayers(of: view).flatMap({ $0.sublayers ?? [] }).contains(where: {
                       ($0 as? AVPlayerLayer)?.isReadyForDisplay == true
                   }) {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    process.arguments = ["-x", "-l", String(window.windowNumber), path]
                    if (try? process.run()) != nil { capture = process }
                }
            }
            try require(!overlap, "visitor overlapped a character event or transition pose")
            try require(observedCharacter, "no IdleScene character event ran")
            try require(observedVisitor, "no IdleScene visitor ran")
            if environment["SNOOPY_RUNTIME_SCREENSHOT"] != nil {
                try require(capture != nil, "IdleScene screenshot was requested but no capture started")
            }
            if let capture {
                capture.waitUntilExit()
                try require(capture.terminationStatus == 0, "IdleScene screenshot capture failed")
            }
            print("IdleScene pacing: character and visitor events observed with no overlap.")
        }
        let switchCount = Int(environment["SNOOPY_RUNTIME_SWITCHES"] ?? "") ?? 8
        let dwell = Double(environment["SNOOPY_RUNTIME_DWELL"] ?? "") ?? 5
        for index in 0..<switchCount {
            let selector = index.isMultiple(of: 2)
                ? NSSelectorFromString("forceNextSceneForTesting")
                : NSSelectorFromString("forceIdleSceneForTesting")
            guard view.responds(to: selector) else {
                throw RuntimeFailure.failed("missing runtime test selector")
            }
            phasesInCurrentSwitch.removeAll()
            if index == 1 {
                // Superseding a pending Idle scene must not promote it
                // to visible or discard the movie that is still showing.
                guard let outgoing = rootLayers(of: view).first(where: { layer in
                    layer.opacity == 1 && (layer.sublayers ?? []).contains { sublayer in
                        (sublayer as? AVPlayerLayer)?.videoGravity == .resizeAspectFill
                    }
                }) else { throw RuntimeFailure.failed("missing visible movie before pre-reveal interruption") }
                view.perform(selector)
                let pending = rootLayers(of: view).first { $0 !== outgoing && $0.opacity == 0 }
                try require(pending != nil, "incoming Idle was visible before its initial-frame handoff")
                view.perform(selector)
                let after = rootLayers(of: view)
                try require(after.contains { $0 === outgoing } && !after.contains { $0 === pending },
                            "superseding a hidden Idle discarded the currently visible movie")
            } else {
                view.perform(selector)
            }
            spin(seconds: dwell, sample: samplePlayback)
            let expected = index.isMultiple(of: 2) ? "snoopyTransitionOutline.hide" : "snoopyTransitionOutline.reveal"
            try require(phasesInCurrentSwitch.isSubset(of: [expected]), "one scene switch ran multiple or wrong-direction wipes")
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
        try require(!uncoveredTransition, "a wipe exposed the root instead of an unmasked, opaque scene underneath")
        try require(!earlyVideoReveal, "transition revealed a video layer before it had a displayable frame")
        try require(observedContinuousReveal && !changedRevealCharacter, "Reveal did not keep the same base sprite through the wipe")
        try require(!invalidHideHandoff, "Hide showed an unprepared action or two character sprites")
        try require(lowestOutlineDensity.isFinite && lowestOutlineDensity >= 0.8, "transition outline raster is too small")
        try require(lowestPoseDensity.isFinite && lowestPoseDensity >= 0.9, "base-pose raster is too small")
        for phase in ["hide", "reveal"] {
            let name = "snoopyTransitionOutline.\(phase)"
            try require(
                (maskFrames[name]?.count ?? 0) > 1 && (outlineFrames[name]?.count ?? 0) > 1,
                "mask and outline did not both advance during \(phase)"
            )
        }
        for capture in transitionCaptures.values {
            capture.waitUntilExit()
            try require(capture.terminationStatus == 0, "transition screenshot capture failed")
        }

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
                + String(format: "outline=%.2f px/pt, base pose=%.2f px/pt, ", lowestOutlineDensity, lowestPoseDensity)
                + "one wipe per switch with full scene coverage, video sizes=\(presentedVideoSizes.sorted().joined(separator: ", "))"
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
