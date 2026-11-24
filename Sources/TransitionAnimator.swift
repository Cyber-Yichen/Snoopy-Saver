import AppKit
import QuartzCore

/// One transition phase is decoded as a unit so its mask and ink stay aligned.
/// Hide is decoded when the ActiveScene starts and released after that wipe.
/// Reveal is decoded only when the movie is near its end, so a long movie does
/// not retain both frame sequences.
final class TransitionFrames {
    struct Phase {
        let mask: [CGImage]
        let outline: [SpriteRaster]
        var duration: TimeInterval { Double(mask.count) / TransitionSequence.framesPerSecond }
    }

    private final class CachedPhase {
        let phase: Phase
        let cost: Int
        init(_ phase: Phase) {
            self.phase = phase
            cost = (phase.mask + phase.outline.map(\.image)).reduce(0) { $0 + FrameDecoder.imageCost($1) }
        }
    }

    private static let cache: NSCache<NSString, CachedPhase> = {
        let cache = NSCache<NSString, CachedPhase>()
        cache.countLimit = 2
        cache.totalCostLimit = 96 * 1024 * 1024
        return cache
    }()

    private static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "local.snoopy.transition-decoder"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()

    private let hideSequence: TransitionSequence?
    private let revealSequence: TransitionSequence?
    private let outlineSize: Int
    private let cachePrefix: String
    private var hidePhase: Phase?
    private var revealPhase: Phase?
    private var hideFinished = false
    private var revealFinished = false
    private var hideDiscarded = false
    private var hideCallbacks: [(Phase?) -> Void] = []
    private var revealCallbacks: [(Phase?) -> Void] = []
    private var hideOperation: BlockOperation?
    private var revealOperation: BlockOperation?

    init(choice: TransitionChoice, pixelWidth: CGFloat) {
        hideSequence = choice.hide
        revealSequence = choice.reveal
        outlineSize = Int(min(1536, max(512, pixelWidth)))
        cachePrefix = [choice.hide.mask.directoryURL.path, choice.reveal.mask.directoryURL.path, String(outlineSize)]
            .joined(separator: "|")
        if let cached = Self.cache.object(forKey: cacheKey(.hide)) {
            hidePhase = cached.phase
            hideFinished = true
        } else {
            startDecode(.hide)
        }
    }

    init(testingHide hide: Phase, reveal: Phase?) {
        hideSequence = nil
        revealSequence = nil
        outlineSize = 0
        cachePrefix = "test-\(UUID().uuidString)"
        hidePhase = hide
        revealPhase = reveal
        hideFinished = true
        revealFinished = reveal != nil
    }

    deinit {
        hideOperation?.cancel()
        revealOperation?.cancel()
        Self.cache.removeObject(forKey: cacheKey(.hide))
        Self.cache.removeObject(forKey: cacheKey(.reveal))
    }

    var debugHideFrameCount: Int { hidePhase?.mask.count ?? 0 }
    var debugRevealFrameCount: Int { revealPhase?.mask.count ?? 0 }

    static func purgeCache() { cache.removeAllObjects() }

    func prepareReveal() {
        guard revealOperation == nil, !revealFinished else { return }
        if let cached = Self.cache.object(forKey: cacheKey(.reveal)) {
            revealPhase = cached.phase
            revealFinished = true
            deliver(.reveal)
            return
        }
        startDecode(.reveal)
    }

    func whenReady(
        _ direction: TransitionAnimator.Direction,
        _ callback: @escaping (Phase?) -> Void
    ) {
        if direction == .reveal { prepareReveal() }
        if isFinished(direction) {
            callback(phase(direction))
            return
        }
        switch direction {
        case .hide: hideCallbacks.append(callback)
        case .reveal: revealCallbacks.append(callback)
        }
    }

    func releaseHideFrames() {
        hideDiscarded = true
        hidePhase = nil
        Self.cache.removeObject(forKey: cacheKey(.hide))
    }

    private func cacheKey(_ direction: TransitionAnimator.Direction) -> NSString {
        "\(cachePrefix)|\(direction.rawValue)" as NSString
    }

    private func isFinished(_ direction: TransitionAnimator.Direction) -> Bool {
        direction == .hide ? hideFinished : revealFinished
    }

    private func phase(_ direction: TransitionAnimator.Direction) -> Phase? {
        let value = direction == .hide ? hidePhase : revealPhase
        guard let value, !value.mask.isEmpty, value.mask.count == value.outline.count else { return nil }
        return value
    }

    private func startDecode(_ direction: TransitionAnimator.Direction) {
        guard let sequence = direction == .hide ? hideSequence : revealSequence else { return }
        let operation = BlockOperation()
        if direction == .hide { hideOperation = operation } else { revealOperation = operation }
        let pixelSize = outlineSize
        operation.addExecutionBlock { [weak self, weak operation] in
            guard let operation else { return }
            let phase = Self.decode(sequence, pixelSize: pixelSize, operation: operation)
            guard !operation.isCancelled else { return }
            DispatchQueue.main.async { [weak self] in
                self?.store(phase, direction: direction)
            }
        }
        Self.queue.addOperation(operation)
    }

    private func store(_ phase: Phase?, direction: TransitionAnimator.Direction) {
        if direction == .hide && hideDiscarded {
            hideFinished = true
            deliver(.hide)
            return
        }
        switch direction {
        case .hide:
            hidePhase = phase
            hideFinished = true
        case .reveal:
            revealPhase = phase
            revealFinished = true
        }
        if let phase {
            let cached = CachedPhase(phase)
            Self.cache.setObject(cached, forKey: cacheKey(direction), cost: cached.cost)
        }
        deliver(direction)
    }

    private func deliver(_ direction: TransitionAnimator.Direction) {
        let pending: [(Phase?) -> Void]
        switch direction {
        case .hide:
            pending = hideCallbacks
            hideCallbacks.removeAll()
        case .reveal:
            pending = revealCallbacks
            revealCallbacks.removeAll()
        }
        let value = phase(direction)
        pending.forEach { $0(value) }
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
        guard !masks.isEmpty, masks.count == outlines.count else { return nil }
        return Phase(mask: masks, outline: outlines)
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
        frames.whenReady(direction) { [weak self] phase in
            guard let self, self.active, !self.started else { return }
            self.work?.cancel()
            guard let phase else {
                NSLog("Snoopy transition frames missing or unreadable; using dissolve")
                self.dissolve(onStart: onStart, completion: completion)
                return
            }
            self.started = true
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
