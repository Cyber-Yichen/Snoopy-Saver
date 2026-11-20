import AppKit
import AVFoundation
import CoreGraphics
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
        print("Frame decoder smoke passed: in-flight and queued cancellation, trimmed raster placement, and opaque dissolve.")
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
}
