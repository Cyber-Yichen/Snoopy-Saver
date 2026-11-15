import AppKit
import QuartzCore

/// Decoded as a unit so the mask and its ink outline never advance independently.
final class TransitionFrames {
    struct Phase {
        let mask: [CGImage]
        let outline: [CGImage]
        var duration: TimeInterval { Double(mask.count) / TransitionSequence.framesPerSecond }
    }

    struct Pair {
        let hide: Phase
        let reveal: Phase
    }

    private final class CachedPair {
        let pair: Pair
        let cost: Int

        init(_ pair: Pair) {
            self.pair = pair
            cost = [pair.hide.mask, pair.hide.outline, pair.reveal.mask, pair.reveal.outline]
                .joined().reduce(0) { $0 + $1.bytesPerRow * $1.height }
        }
    }

    private static let cache: NSCache<NSString, CachedPair> = {
        let cache = NSCache<NSString, CachedPair>()
        cache.countLimit = 1
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()

    private static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "local.snoopy.transition-decoder"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()

    private let operation = BlockOperation()
    private var callbacks: [(Pair?) -> Void] = []
    private var finished = false
    private var result: Pair?

    init(choice: TransitionChoice, pixelWidth: CGFloat) {
        let hide = choice.hide
        let reveal = choice.reveal
        // Reserve at most about 48 MiB of RGBA image pixels for a pair.
        let frameCount = Double(2 * (hide.mask.frameCount + reveal.mask.frameCount))
        let aspect = Double(hide.mask.assetSize.width / hide.mask.assetSize.height)
        let boundedWidth = sqrt(48 * 1024 * 1024 * aspect / (4 * frameCount))
        let pixelSize = Int(min(max(320, pixelWidth), min(768, boundedWidth)))
        let key = [hide.mask.directoryURL.path, reveal.mask.directoryURL.path, String(pixelSize)]
            .joined(separator: "|") as NSString
        if let cached = Self.cache.object(forKey: key) {
            result = cached.pair
            finished = true
            return
        }
        operation.addExecutionBlock { [weak self, weak operation] in
            guard let operation else { return }
            let result = Self.decodePair(hide: hide, reveal: reveal, pixelSize: pixelSize, operation: operation)
            guard !operation.isCancelled else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let result {
                    let cached = CachedPair(result)
                    Self.cache.setObject(cached, forKey: key, cost: cached.cost)
                }
                self.complete(result)
            }
        }
        Self.queue.addOperation(operation)
    }

    deinit { operation.cancel() }

    static func purgeCache() { cache.removeAllObjects() }

    func whenReady(_ callback: @escaping (Pair?) -> Void) {
        if finished { callback(result) }
        else { callbacks.append(callback) }
    }

    private func complete(_ pair: Pair?) {
        result = pair
        finished = true
        let pending = callbacks
        callbacks.removeAll()
        pending.forEach { $0(pair) }
    }

    private static func decode(
        _ sequence: TransitionSequence, pixelSize: Int, operation: Operation
    ) -> Phase? {
        var masks: [CGImage] = []
        var outlines: [CGImage] = []
        for frame in sequence.mask.startFrame...sequence.mask.endFrame {
            guard !operation.isCancelled,
                  let maskURL = sequence.mask.frameURL(frame),
                  let outlineURL = sequence.outline.frameURL(frame),
                  let mask = autoreleasepool(invoking: { FrameDecoder.decodeImage(maskURL, maxPixelSize: pixelSize) }),
                  let outline = autoreleasepool(invoking: { FrameDecoder.decodeImage(outlineURL, maxPixelSize: pixelSize) })
            else { return nil }
            masks.append(mask)
            outlines.append(outline)
        }
        return Phase(mask: masks, outline: outlines)
    }

    private static func decodePair(
        hide: TransitionSequence, reveal: TransitionSequence, pixelSize: Int, operation: Operation
    ) -> Pair? {
        let sequences = [hide, reveal]
        let lock = NSLock()
        var phases: [Phase?] = [nil, nil]
        // One pair is decoded at a time; the two phases are independent.
        DispatchQueue.concurrentPerform(iterations: sequences.count) { index in
            let phase = decode(sequences[index], pixelSize: pixelSize, operation: operation)
            lock.lock()
            phases[index] = phase
            lock.unlock()
        }
        guard let hide = phases[0], let reveal = phases[1] else { return nil }
        return Pair(hide: hide, reveal: reveal)
    }
}

final class TransitionAnimator {
    static let dissolveDuration: TimeInterval = 1.5

    private let root: CALayer
    private let incoming: CALayer
    private let outgoing: CALayer?
    private let backdrop: CGColor
    private let mask = CALayer()
    private let outline = CALayer()
    private var previousBackground: CGColor?
    private var maskedLayer: CALayer?
    private var work: DispatchWorkItem?
    private var frameTimer: Timer?
    private var active = true
    private var started = false

    init(root: CALayer, incoming: CALayer, outgoing: CALayer?, backdrop: CGColor) {
        self.root = root
        self.incoming = incoming
        self.outgoing = outgoing
        self.backdrop = backdrop
        mask.contentsGravity = .resizeAspectFill
        outline.contentsGravity = .resizeAspectFill
        outline.zPosition = 100
    }

    func play(
        frames: TransitionFrames?,
        onSpriteStart: @escaping () -> Void,
        onCut: @escaping () -> Void,
        completion: @escaping () -> Void
    ) {
        // Mirror the old dissolve for first presentation and incomplete assets.
        guard let frames, let outgoing else {
            dissolve(onCut: onCut, completion: completion)
            return
        }
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.active, !self.started else { return }
            NSLog("Snoopy transition frames not ready; using dissolve")
            self.dissolve(onCut: onCut, completion: completion)
        }
        work = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: timeout)
        frames.whenReady { [weak self] pair in
            guard let self, self.active, !self.started else { return }
            self.work?.cancel()
            guard let pair else {
                NSLog("Snoopy transition frames missing or unreadable; using dissolve")
                self.dissolve(onCut: onCut, completion: completion)
                return
            }
            self.started = true
            self.previousBackground = self.root.backgroundColor
            CATransaction.begin(); CATransaction.setDisableActions(true)
            self.root.backgroundColor = self.backdrop
            self.root.addSublayer(self.outline)
            self.installMask(over: outgoing, phaseName: "hide")
            CATransaction.commit()
            onSpriteStart()
            self.playPhase(pair.hide) { [weak self] in
                guard let self else { return }
                CATransaction.begin(); CATransaction.setDisableActions(true)
                outgoing.opacity = 0
                self.installMask(over: self.incoming, phaseName: "reveal")
                self.incoming.opacity = 1
                CATransaction.commit()
                onCut()
                self.playPhase(pair.reveal) { [weak self] in
                    self?.complete(completion)
                }
            }
        }
    }

    func resize() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        outline.frame = root.bounds
        if let maskedLayer { mask.frame = maskedLayer.bounds }
        CATransaction.commit()
    }

    func cancel() {
        guard active else { return }
        active = false
        work?.cancel(); work = nil
        frameTimer?.invalidate(); frameTimer = nil
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if outline.superlayer != nil {
            root.backgroundColor = previousBackground
            outline.removeFromSuperlayer()
        }
        maskedLayer?.mask = nil; maskedLayer = nil
        mask.removeAllAnimations(); mask.contents = nil
        outline.removeAllAnimations(); outline.contents = nil
        incoming.removeAnimation(forKey: "snoopyFadeIn")
        outgoing?.removeAnimation(forKey: "snoopyFadeOut")
        CATransaction.commit()
    }

    static func finishReveal(_ layer: CALayer) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.mask = nil
        layer.removeAnimation(forKey: "snoopyFadeIn")
        layer.opacity = 1
        CATransaction.commit()
    }

    private func installMask(over layer: CALayer, phaseName: String) {
        maskedLayer?.mask = nil
        maskedLayer = layer
        resize()
        layer.mask = mask
        outline.name = "snoopyTransitionOutline.\(phaseName)"
    }

    private func playPhase(_ phase: TransitionFrames.Phase, completion: @escaping () -> Void) {
        let start = CACurrentMediaTime()
        var displayedFrame = 0
        showFrame(0, of: phase)
        // Only submit the current pair to Core Animation. Uploading two
        // sequences as contents keyframes keeps their render surfaces alive.
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self, self.active else { timer.invalidate(); return }
            let elapsed = CACurrentMediaTime() - start
            if elapsed >= phase.duration {
                timer.invalidate()
                self.frameTimer = nil
                completion()
                return
            }
            let frame = min(phase.mask.count - 1, Int(elapsed * TransitionSequence.framesPerSecond))
            guard frame != displayedFrame else { return }
            displayedFrame = frame
            self.showFrame(frame, of: phase)
        }
        frameTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func showFrame(_ frame: Int, of phase: TransitionFrames.Phase) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        mask.contents = phase.mask[frame]
        outline.contents = phase.outline[frame]
        CATransaction.commit()
    }

    private func dissolve(onCut: () -> Void, completion: @escaping () -> Void) {
        guard active, !started else { return }
        started = true
        onCut()
        let fadeIn = CABasicAnimation(keyPath: "opacity")
        fadeIn.fromValue = 0; fadeIn.toValue = 1; fadeIn.duration = Self.dissolveDuration
        fadeIn.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        let fadeOut = CABasicAnimation(keyPath: "opacity")
        fadeOut.fromValue = outgoing?.presentation()?.opacity ?? outgoing?.opacity ?? 1
        fadeOut.toValue = 0; fadeOut.duration = Self.dissolveDuration
        fadeOut.timingFunction = fadeIn.timingFunction
        CATransaction.begin(); CATransaction.setDisableActions(true)
        incoming.opacity = 1; outgoing?.opacity = 0
        incoming.add(fadeIn, forKey: "snoopyFadeIn")
        outgoing?.add(fadeOut, forKey: "snoopyFadeOut")
        CATransaction.commit()
        schedule(after: Self.dissolveDuration) { [weak self] in self?.complete(completion) }
    }

    private func complete(_ completion: () -> Void) {
        cancel()
        completion()
    }

    private func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) {
        let item = DispatchWorkItem { [weak self] in
            guard self?.active == true else { return }
            action()
        }
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }
}
