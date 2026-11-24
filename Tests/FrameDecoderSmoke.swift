import AppKit
import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import QuartzCore

@main
struct FrameDecoderSmoke {
    static func main() throws {
        let image = CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!.makeImage()!
        verifyReplacement(image: image, purgeAll: false)
        verifyReplacement(image: image, purgeAll: true)
        verifyQueuedCancellation(image: image)
        verifyTrimmedPlacement()
        verifyOpaqueDissolve()
        verifyDeferredBoundaryAdvance()
        verifyPlayerPolicy()
        verifyOffscreenSuspensionPolicy()
        verifyMediaTimingFallbackRemoved()
        verifyMediaTimingCancellation()
        verifyFrameRetention()
        verifySuspendedClock()
        try verifyNaturalBoundaryAdvance()
        print("Frame decoder smoke passed: in-flight and queued cancellation, trimmed raster placement, opaque dissolve, and deferred end-of-movie advance.")
        if CommandLine.arguments.count == 2 {
            try verifyNativeHide(resources: URL(fileURLWithPath: CommandLine.arguments[1]))
        }
    }

    private static func verifyQueuedCancellation(image: CGImage) {
        let release = DispatchSemaphore(value: 0)
        let decoder = FrameDecoder { _, _ in
            precondition(release.wait(timeout: .now() + 5) == .success)
            return image
        }
        let canceled = UUID(), subscriber = UUID()
        let url = URL(fileURLWithPath: "/pending-delivery")
        var delivered = false
        decoder.request(url, maxPixelSize: 256, clientID: canceled) { _ in
            preconditionFailure("canceled callback ran after decode completion")
        }
        decoder.request(url, maxPixelSize: 256, clientID: subscriber) { delivered = $0?.image === image }
        let originalQueueLength = OperationQueue.main.operationCount
        release.signal()
        // Do not drive the run loop yet: the full decode and callback
        // enqueue must happen before cancellation, not during the decoder.
        let deadline = Date().addingTimeInterval(5)
        while OperationQueue.main.operationCount <= originalQueueLength && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.001)
        }
        precondition(OperationQueue.main.operationCount > originalQueueLength)
        decoder.cancelRequests(for: canceled)
        while !delivered && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        precondition(delivered)
    }

    private static func verifyNativeHide(resources: URL) throws {
        let catalog = try AssetCatalog(resources: resources)
        let environment = EnvironmentProvider()
        let scorer = RelevancyEngine()
        let composition = catalog.makeIdleComposition(environment: environment.snapshot(), scorer: scorer)!
        let actions = catalog.assets(.characterSceneTransitionPose)
        let supported = actions.first { $0.identifier == "104_ST006_Hide_A" }!
        let incompatible = actions.first { $0.identifier == "101_ST001_Hide_A" }!
        _ = NSApplication.shared
        let frame = CGRect(x: 0, y: 0, width: 800, height: 500)
        let view = NSView(frame: frame)
        view.wantsLayer = true
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        let idle = IdleScenePlayback(composition: composition, catalog: catalog, scorer: scorer,
                                     environment: environment, frame: frame, targetDuration: 20, initialPoseID: "101_BP001")
        view.layer!.addSublayer(idle.container)
        window.orderFront(nil)
        defer { idle.stop(); window.close() }
        idle.prepare()
        func waitForLayer(_ name: String, ready: (CALayer) -> Bool) -> CALayer? {
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                idle.tick()
                if let layer = idle.container.sublayers?.first(where: { $0.name == name }), ready(layer) { return layer }
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
            return nil
        }
        guard let base = waitForLayer("snoopyIdleBasePose", ready: { $0.opacity == 1 }) else {
            preconditionFailure("bundled base pose never presented")
        }
        idle.prepareHidePose(incompatible)
        precondition(idle.container.sublayers?.contains { $0.name == "snoopyPreparedHideCharacter" } != true)
        idle.prepareHidePose(supported)
        guard let prepared = waitForLayer("snoopyPreparedHideCharacter", ready: {
            ($0 as? AVPlayerLayer)?.isReadyForDisplay == true
        }) as? AVPlayerLayer else { preconditionFailure("bundled Hide clip did not present a preroll frame") }
        precondition(prepared.opacity == 0 && !base.isHidden && prepared.player?.currentTime() == .zero)
        idle.startPreparedHidePose()
        precondition(prepared.name == "snoopyHideCharacter" && prepared.opacity == 1 && base.isHidden)
        print("Native pose smoke passed: incompatible Hide rejected; matching Apple clip primed at zero and installed atomically.")
    }

    private static func verifyTrimmedPlacement() {
        let canvas = CGRect(x: 0, y: 0, width: 256, height: 256)
        let context = CGContext(data: nil, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let ink = CGRect(x: 100, y: 175, width: 40, height: 30)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(ink)
        let raster = SpriteRaster.trimmingTransparentBorder(context.makeImage()!)
        let frame = raster.frame(in: canvas)
        precondition(frame.contains(ink) && frame.width < 90 && frame.height < 90)
        precondition(CGFloat(raster.image.width) == frame.width && CGFloat(raster.image.height) == frame.height)
    }

    private static func verifyOpaqueDissolve() {
        let root = CALayer()
        let incoming = CALayer()
        let outgoing = CALayer()
        let animator = TransitionAnimator(root: root, incoming: incoming, outgoing: outgoing)
        animator.play(frames: nil, direction: .hide, onStart: { precondition(!$0) }, completion: {})
        precondition(outgoing.opacity == 1 && outgoing.animation(forKey: "snoopyFadeOut") == nil)
        precondition(incoming.animation(forKey: "snoopyFadeIn") != nil)
        animator.cancel()
    }

    private static func verifyReplacement(image: CGImage, purgeAll: Bool) {
        let firstStarted = DispatchSemaphore(value: 0)
        let secondStarted = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let releaseSecond = DispatchSemaphore(value: 0)
        let probeStarted = DispatchSemaphore(value: 0)
        let frame = URL(fileURLWithPath: "/frame")
        let lock = NSLock()
        var decodeCount = 0
        let decoder = FrameDecoder { url, _ in
            guard url == frame else {
                probeStarted.signal()
                return image
            }
            lock.lock()
            decodeCount += 1
            let attempt = decodeCount
            lock.unlock()
            if attempt == 1 {
                firstStarted.signal()
                precondition(releaseFirst.wait(timeout: .now() + 10) == .success)
            } else {
                secondStarted.signal()
                precondition(releaseSecond.wait(timeout: .now() + 10) == .success)
            }
            return image
        }

        let oldClient = UUID()
        let newClient = UUID()
        decoder.request(frame, maxPixelSize: 256, clientID: oldClient) { _ in
            preconditionFailure("cancelled request called back")
        }
        precondition(firstStarted.wait(timeout: .now() + 5) == .success)
        if purgeAll { decoder.removeAll() }
        else { decoder.cancelRequests(for: oldClient) }

        var receivedImage: CGImage?
        var callbackCount = 0
        decoder.request(frame, maxPixelSize: 256, clientID: newClient) {
            callbackCount += 1
            receivedImage = $0?.image
        }
        precondition(secondStarted.wait(timeout: .now() + 5) == .success)
        decoder.request(URL(fileURLWithPath: "/probe"), maxPixelSize: 256, clientID: newClient)
        releaseFirst.signal()
        // Both decoder slots were occupied. Starting the probe proves the old
        // task has completed while the replacement is still blocked.
        precondition(probeStarted.wait(timeout: .now() + 5) == .success)
        releaseSecond.signal()
        let deadline = Date().addingTimeInterval(5)
        while callbackCount == 0, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        precondition(callbackCount == 1 && receivedImage === image)
        precondition(decoder.cachedFrame(for: frame, maxPixelSize: 256)?.image === image)
    }

    private static func verifyDeferredBoundaryAdvance() {
        var epoch = 4
        var sessionActive = true
        var playerCurrent = true
        var ran = false
        SceneAdvance.deferBoundaryAdvance(
            sessionActive: { sessionActive },
            epoch: { epoch },
            capturedEpoch: 4,
            playerStillCurrent: { playerCurrent },
            advance: { ran = true }
        )
        precondition(!ran, "boundary callback switched scenes before returning")
        epoch = 5
        pumpMain(until: Date().addingTimeInterval(0.4), done: { ran })
        precondition(!ran, "stale scene epoch was allowed to advance")
        epoch = 7
        playerCurrent = false
        var rejected = false
        SceneAdvance.deferBoundaryAdvance(
            sessionActive: { sessionActive },
            epoch: { epoch },
            capturedEpoch: 7,
            playerStillCurrent: { playerCurrent },
            advance: { rejected = true }
        )
        pumpMain(until: Date().addingTimeInterval(0.4), done: { rejected })
        precondition(!rejected, "advance ran after the player was replaced")
        playerCurrent = true
        sessionActive = false
        var stopped = false
        SceneAdvance.deferBoundaryAdvance(
            sessionActive: { sessionActive },
            epoch: { epoch },
            capturedEpoch: 7,
            playerStillCurrent: { playerCurrent },
            advance: { stopped = true }
        )
        pumpMain(until: Date().addingTimeInterval(0.4), done: { stopped })
        precondition(!stopped, "advance ran after the session stopped")
        sessionActive = true
        var accepted = false
        SceneAdvance.deferBoundaryAdvance(
            sessionActive: { sessionActive },
            epoch: { epoch },
            capturedEpoch: 7,
            playerStillCurrent: { playerCurrent },
            advance: { accepted = true }
        )
        pumpMain(until: Date().addingTimeInterval(1), done: { accepted })
        precondition(accepted, "current epoch did not advance on the following turn")
    }

    private static func verifyNaturalBoundaryAdvance() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("snoopy-boundary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("clip.mov")
        try writeSilentClip(to: url, seconds: 0.5)
        let player = AVPlayer(playerItem: AVPlayerItem(url: url))
        player.isMuted = true
        player.volume = 0
        var insideCallback = false
        var removedInsideCallback = false
        var advances = 0
        var epoch = 1
        var token: Any?
        token = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: CMTime(seconds: 0.15, preferredTimescale: 600))],
            queue: .main
        ) {
            insideCallback = true
            let observer = token
            SceneAdvance.deferBoundaryAdvance(
                sessionActive: { true },
                epoch: { epoch },
                capturedEpoch: 1,
                playerStillCurrent: { true },
                advance: {
                    removedInsideCallback = insideCallback
                    if let observer { player.removeTimeObserver(observer) }
                    advances += 1
                    epoch += 1
                }
            )
            insideCallback = false
        }
        player.play()
        pumpMain(until: Date().addingTimeInterval(5), done: { advances > 0 })
        player.pause()
        player.replaceCurrentItem(with: nil)
        precondition(advances == 1, "natural boundary did not advance exactly once")
        precondition(!removedInsideCallback, "time observer was removed inside its own callback")
    }

    private static func writeSilentClip(to url: URL, seconds: Double) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 16,
            AVVideoHeightKey: 16,
        ])
        writer.add(input)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: 16,
                kCVPixelBufferHeightKey as String: 16,
            ]
        )
        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "SnoopyBoundary", code: 1)
        }
        writer.startSession(atSourceTime: .zero)
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
        guard let pixelBuffer else { throw NSError(domain: "SnoopyBoundary", code: 2) }
        let fps = 10
        let frameCount = max(2, Int(seconds * Double(fps)))
        for index in 0..<frameCount {
            let readyDeadline = Date().addingTimeInterval(2)
            while !input.isReadyForMoreMediaData && Date() < readyDeadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            precondition(input.isReadyForMoreMediaData, "asset writer was not ready")
            let time = CMTime(value: CMTimeValue(index), timescale: CMTimeScale(fps))
            precondition(adaptor.append(pixelBuffer, withPresentationTime: time), "could not append a test frame")
        }
        input.markAsFinished()
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        precondition(finished.wait(timeout: .now() + 5) == .success, "asset writer did not finish")
        if writer.status != .completed {
            throw writer.error ?? NSError(domain: "SnoopyBoundary", code: 3)
        }
    }

    private static func verifyPlayerPolicy() {
        let player = AVPlayer()
        PlayerPolicy.apply(player)
        precondition(!player.allowsExternalPlayback, "external playback stayed enabled")
        precondition(!player.preventsDisplaySleepDuringVideoPlayback, "video playback still prevents display sleep")
        precondition(player.isMuted && player.volume == 0 && player.actionAtItemEnd == .pause)
    }

    private static func verifyMediaTimingFallbackRemoved() {
        precondition(MediaTiming.validatedDuration(seconds: 1.25, loaded: true) == 1.25)
        precondition(MediaTiming.validatedDuration(seconds: 0, loaded: true) == nil)
        precondition(MediaTiming.validatedDuration(seconds: .nan, loaded: true) == nil)
        precondition(MediaTiming.validatedDuration(seconds: 2, loaded: false) == nil)
        precondition(MediaTiming.loopRepeatCount(loopDuration: 2, desiredLoop: 5) == 3)
        precondition(MediaTiming.loopRepeatCount(loopDuration: 0, desiredLoop: 10) == nil)
        precondition(MediaTiming.loopRepeatCount(loopDuration: .infinity, desiredLoop: 10) == nil)
        let missing = URL(fileURLWithPath: "/tmp/snoopy-missing-\(UUID().uuidString).mov")
        let finished = DispatchSemaphore(value: 0)
        MediaTimingCache.shared.load(missing) { value in
            precondition(value == nil, "a missing movie was given a placeholder duration")
            finished.signal()
        }
        precondition(finished.wait(timeout: .now() + 5) == .success, "duration load did not finish")
        precondition(MediaTimingCache.shared.duration(for: missing) == nil)
    }

    private static func verifyFrameRetention() {
        let wrapped = SpriteAssetPlayer.retentionWindow(current: 4, start: 0, count: 5, limit: 3)
        precondition(wrapped == Set([4, 0, 1]), "sharp loop window did not wrap")
        let whole = SpriteAssetPlayer.retentionWindow(current: 12, start: 10, count: 4, limit: 8)
        precondition(whole == Set([10, 11, 12, 13]))
        let context = CGContext(
            data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let image = context.makeImage()!
        precondition(FrameDecoder.imageCost(image) >= image.width * image.height * 4)
        let outline = SpriteRaster(image: image)
        let hide = TransitionFrames.Phase(mask: [image, image, image], outline: [outline, outline, outline])
        let reveal = TransitionFrames.Phase(mask: [image], outline: [outline])
        let frames = TransitionFrames(testingHide: hide, reveal: reveal)
        precondition(frames.debugHideFrameCount == 3 && frames.debugRevealFrameCount == 1)
        frames.releaseHideFrames()
        precondition(frames.debugHideFrameCount == 0, "hide frames stayed resident after the wipe")
        precondition(frames.debugRevealFrameCount == 1, "releasing hide dropped the reveal phase")
    }

    private static func verifySuspendedClock() {
        let pauseBegan: CFTimeInterval = 100
        let resumedAt: CFTimeInterval = 130
        precondition(SpriteAssetPlayer.resumedFrameStart(
            frameStarted: 90, pauseBegan: pauseBegan, resumedAt: resumedAt
        ) == 120)
        precondition(SpriteAssetPlayer.resumedFrameStart(
            frameStarted: 0, pauseBegan: pauseBegan, resumedAt: resumedAt
        ) == 0)
        precondition(SpriteAssetPlayer.shiftedFireTime(
            fireAt: pauseBegan + 1.5, pauseBegan: pauseBegan, resumedAt: resumedAt
        ) == resumedAt + 1.5)
    }

    private static func verifyMediaTimingCancellation() {
        let flag = CancelFlag()
        precondition(!flag.isCancelled)
        flag.cancel()
        precondition(flag.isCancelled)
        let missing = URL(fileURLWithPath: "/tmp/snoopy-cancelled-\(UUID().uuidString).mov")
        precondition(MediaTimingCache.loadSource(missing, cancel: flag) == nil)
    }

    private static func verifyOffscreenSuspensionPolicy() {
        precondition(!SnoopyScreenSaverView.shouldSuspendPlayback(
            sessionActive: true, sawOnscreenWindow: true, windowVisible: true, viewHidden: false
        ), "visible fullscreen playback would be paused")
        precondition(!SnoopyScreenSaverView.shouldSuspendPlayback(
            sessionActive: true, sawOnscreenWindow: false, windowVisible: false, viewHidden: false
        ), "playback would be paused before the host shows the window")
        precondition(SnoopyScreenSaverView.shouldSuspendPlayback(
            sessionActive: true, sawOnscreenWindow: true, windowVisible: false, viewHidden: false
        ), "an ordered-out window would keep decoding")
        precondition(SnoopyScreenSaverView.shouldSuspendPlayback(
            sessionActive: true, sawOnscreenWindow: true, windowVisible: true, viewHidden: true
        ), "a hidden view would keep decoding")
        precondition(!SnoopyScreenSaverView.shouldSuspendPlayback(
            sessionActive: false, sawOnscreenWindow: true, windowVisible: false, viewHidden: true
        ))
    }

    private static func pumpMain(until deadline: Date, done: () -> Bool = { false }) {
        while Date() < deadline && !done() {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }
}
