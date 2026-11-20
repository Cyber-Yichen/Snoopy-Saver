import AppKit
import QuartzCore

/// Decoded as a unit so the mask and its ink outline never advance independently.
final class TransitionFrames {
    struct Phase {
        let mask: [CGImage]
        let outline: [SpriteRaster]
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
            cost = [pair.hide.mask, pair.hide.outline.map(\.image), pair.reveal.mask, pair.reveal.outline.map(\.image)]
                .joined().reduce(0) { $0 + $1.bytesPerRow * $1.height }
        }
    }

    private static let cache: NSCache<NSString, CachedPair> = {
        let cache = NSCache<NSString, CachedPair>()
        cache.countLimit = 1
        cache.totalCostLimit = 192 * 1024 * 1024
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
        // Give the visible ink a separate pixel budget. Thin strokes can be
        // cropped without changing their position or their sampling density.
        let outlineSize = Int(min(1536, max(512, pixelWidth)))
        let key = [hide.mask.directoryURL.path, reveal.mask.directoryURL.path, String(outlineSize)]
            .joined(separator: "|") as NSString
        if let cached = Self.cache.object(forKey: key) {
            result = cached.pair
            finished = true
            return
        }
        operation.addExecutionBlock { [weak self, weak operation] in
            guard let operation else { return }
            let result = Self.decodePair(hide: hide, reveal: reveal, pixelSize: outlineSize, operation: operation)
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
        var outlines: [SpriteRaster] = []
        for frame in sequence.mask.startFrame...sequence.mask.endFrame {
            guard !operation.isCancelled,
                  let maskURL = sequence.mask.frameURL(frame),
                  let outlineURL = sequence.outline.frameURL(frame),
                  let mask = autoreleasepool(invoking: { FrameDecoder.decodeImage(maskURL, maxPixelSize: min(640, pixelSize)) }),
                  let outline = autoreleasepool(invoking: {
                      FrameDecoder.decodeImage(outlineURL, maxPixelSize: pixelSize)
                          .map(SpriteRaster.trimmingTransparentBorder)
                  })
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

    enum Direction: String {
        case hide, reveal
    }

    private let root: CALayer
    private let incoming: CALayer
    private let outgoing: CALayer?
    private let mask = CALayer()
    private let outline = CALayer()
    private var outlineRaster: SpriteRaster?
    private var maskedLayer: CALayer?
    private var work: DispatchWorkItem?
    private var frameTimer: Timer?
    private var active = true
    private var started = false

    init(root: CALayer, incoming: CALayer, outgoing: CALayer?) {
        self.root = root
        self.incoming = incoming
        self.outgoing = outgoing
        mask.contentsGravity = .resizeAspectFill
        outline.contentsGravity = .resize
        outline.zPosition = 100
    }

    func play(
        frames: TransitionFrames?,
        direction: Direction,
        onStart: @escaping (_ usesSprite: Bool) -> Void,
        completion: @escaping () -> Void
    ) {
        // Mirror the old dissolve for first presentation and incomplete assets.
        guard let frames, let outgoing else {
            dissolve(onStart: onStart, completion: completion)
            return
        }
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.active, !self.started else { return }
            NSLog("Snoopy transition frames not ready; using dissolve")
            self.dissolve(onStart: onStart, completion: completion)
        }
        work = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: timeout)
        frames.whenReady { [weak self] pair in
            guard let self, self.active, !self.started else { return }
            self.work?.cancel()
            guard let pair else {
                NSLog("Snoopy transition frames missing or unreadable; using dissolve")
                self.dissolve(onStart: onStart, completion: completion)
                return
            }
            self.started = true
            let phase = direction == .hide ? pair.hide : pair.reveal
            let top = direction == .hide ? outgoing : self.incoming
            let bottom = direction == .hide ? self.incoming : outgoing
            CATransaction.begin(); CATransaction.setDisableActions(true)
            // One scene is always fully visible under the animated mask.
            // Hide closes the OLD scene over the new one; Reveal opens the
            // NEW scene over the old one. Never chain two empty endpoints.
            self.root.insertSublayer(top, above: bottom)
            self.incoming.opacity = 1
            outgoing.opacity = 1
            self.root.addSublayer(self.outline)
            self.showFrame(0, of: phase)
            self.installMask(over: top, phaseName: direction.rawValue)
            CATransaction.commit()
            onStart(true)
            self.playPhase(phase) { [weak self] in
                self?.complete(completion)
            }
        }
    }

    func resize() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layoutOutline()
        if let maskedLayer { mask.frame = maskedLayer.bounds }
        CATransaction.commit()
    }

    func cancel() {
        guard active else { return }
        active = false
        work?.cancel(); work = nil
        frameTimer?.invalidate(); frameTimer = nil
        CATransaction.begin(); CATransaction.setDisableActions(true)
        outline.removeFromSuperlayer()
        maskedLayer?.mask = nil; maskedLayer = nil
        mask.removeAllAnimations(); mask.contents = nil
        outline.removeAllAnimations(); outline.contents = nil
        outlineRaster = nil
        incoming.removeAnimation(forKey: "snoopyFadeIn")
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
        outlineRaster = phase.outline[frame]
        outline.contents = outlineRaster?.image
        layoutOutline()
        CATransaction.commit()
    }

    private func layoutOutline() {
        let bounds = root.bounds
        let aspect = ViewportLayout.designSize.width / ViewportLayout.designSize.height
        let width = max(bounds.width, bounds.height * aspect)
        let height = width / aspect
        let canvas = CGRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
        outline.frame = outlineRaster?.frame(in: canvas) ?? canvas
    }

    private func dissolve(onStart: (Bool) -> Void, completion: @escaping () -> Void) {
        guard active, !started else { return }
        started = true
        let fadeIn = CABasicAnimation(keyPath: "opacity")
        fadeIn.fromValue = 0; fadeIn.toValue = 1; fadeIn.duration = Self.dissolveDuration
        fadeIn.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // Keep an opaque picture underneath the incoming fade. Fading both
        // pictures exposes the black root at intermediate opacities.
        incoming.opacity = 1; outgoing?.opacity = 1
        incoming.add(fadeIn, forKey: "snoopyFadeIn")
        CATransaction.commit()
        onStart(false)
        schedule(after: Self.dissolveDuration) { [weak self] in self?.complete(completion) }
    }

    private func complete(_ completion: () -> Void) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        cancel()
        completion()
        CATransaction.commit()
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
