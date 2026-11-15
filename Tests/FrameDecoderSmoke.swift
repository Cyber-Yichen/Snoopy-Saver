import CoreGraphics
import Foundation

@main
struct FrameDecoderSmoke {
    static func main() {
        let image = CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!.makeImage()!
        verifyReplacement(image: image, purgeAll: false)
        verifyReplacement(image: image, purgeAll: true)
        print("Frame decoder smoke passed: cancellation and cache purge preserve the replacement request.")
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
            receivedImage = $0
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
        precondition(decoder.cachedImage(for: frame, maxPixelSize: 256) === image)
    }
}
