import AppKit
import QuartzCore

private final class PreparedTransitionFrames {
    let masks: [CGImage]
    let outlines: [CGImage]
    let duration: CFTimeInterval

    init(masks: [CGImage], outlines: [CGImage], duration: CFTimeInterval) {
        self.masks = masks
        self.outlines = outlines
        self.duration = duration
    }
}

private final class TransitionFrameStore {
    private final class Load {
        let clientID = UUID()
        var masks: [CGImage?]
        var outlines: [CGImage?]
        var remaining: Int
        var completions: [(PreparedTransitionFrames?) -> Void] = []
        let duration: CFTimeInterval

        init(maskCount: Int, outlineCount: Int, duration: CFTimeInterval) {
            masks = Array(repeating: nil, count: maskCount)
            outlines = Array(repeating: nil, count: outlineCount)
            remaining = maskCount + outlineCount
            self.duration = duration
        }
    }

    static let shared = TransitionFrameStore()
    private let maximumPixelSize = 960
    private var cache: [String: PreparedTransitionFrames] = [:]
    private var cacheOrder: [String] = []
    private var inFlight: [String: Load] = [:]

    func prepare(_ asset: AssetRecord, completion: ((PreparedTransitionFrames?) -> Void)? = nil) {
        dispatchPrecondition(condition: .onQueue(.main))
        let key = cacheKey(asset)
        if let cached = cache[key] {
            completion?(cached)
            return
        }
        if let loading = inFlight[key] {
            if let completion { loading.completions.append(completion) }
            return
        }
        guard let mask = asset.sprites.first(where: { $0.plane == "mask" }) else {
            completion?(nil)
            return
        }
        let outline = asset.sprites.first(where: { $0.plane != "mask" })
        let frameCount = max(mask.frameCount, outline?.frameCount ?? 0)
        let loading = Load(
            maskCount: mask.frameCount,
            outlineCount: outline?.frameCount ?? 0,
            duration: Double(max(1, frameCount)) / 30
        )
        if let completion { loading.completions.append(completion) }
        inFlight[key] = loading

        for index in 0..<mask.frameCount {
            guard let url = mask.frameURL(mask.startFrame + index) else {
                completeMissingFrame(key: key)
                continue
            }
            FrameDecoder.shared.request(
                url, maxPixelSize: maximumPixelSize, clientID: loading.clientID
            ) { [weak self, weak loading] image in
                guard let self, let loading, self.inFlight[key] === loading else { return }
                loading.masks[index] = image
                self.completeFrame(key: key, loading: loading)
            }
        }
        if let outline {
            for index in 0..<outline.frameCount {
                guard let url = outline.frameURL(outline.startFrame + index) else {
                    completeMissingFrame(key: key)
                    continue
                }
                FrameDecoder.shared.request(
                    url, maxPixelSize: maximumPixelSize, clientID: loading.clientID
                ) { [weak self, weak loading] image in
                    guard let self, let loading, self.inFlight[key] === loading else { return }
                    loading.outlines[index] = image
                    self.completeFrame(key: key, loading: loading)
                }
            }
        }
        if loading.remaining == 0 { finish(key: key, loading: loading) }
    }

    func prepared(_ asset: AssetRecord?) -> PreparedTransitionFrames? {
        guard let asset else { return nil }
        return cache[cacheKey(asset)]
    }

    func purge() {
        for loading in inFlight.values {
            FrameDecoder.shared.cancelRequests(for: loading.clientID)
        }
        inFlight.removeAll()
        cache.removeAll()
        cacheOrder.removeAll()
    }

    func release(_ asset: AssetRecord?) {
        guard let asset else { return }
        let key = cacheKey(asset)
        cache.removeValue(forKey: key)
        cacheOrder.removeAll { $0 == key }
        if let loading = inFlight.removeValue(forKey: key) {
            FrameDecoder.shared.cancelRequests(for: loading.clientID)
            loading.completions.forEach { $0(nil) }
        }
    }

    private func completeMissingFrame(key: String) {
        guard let loading = inFlight[key] else { return }
        completeFrame(key: key, loading: loading)
    }

    private func completeFrame(key: String, loading: Load) {
        loading.remaining -= 1
        if loading.remaining == 0 { finish(key: key, loading: loading) }
    }

    private func finish(key: String, loading: Load) {
        guard inFlight.removeValue(forKey: key) === loading else { return }
        let masks = loading.masks.compactMap { $0 }
        let outlines = loading.outlines.compactMap { $0 }
        let prepared: PreparedTransitionFrames?
        if masks.count == loading.masks.count && outlines.count == loading.outlines.count {
            let value = PreparedTransitionFrames(
                masks: masks, outlines: outlines, duration: loading.duration
            )
            cache[key] = value
            cacheOrder.removeAll { $0 == key }
            cacheOrder.append(key)
            while cacheOrder.count > 2 {
                cache.removeValue(forKey: cacheOrder.removeFirst())
            }
            prepared = value
        } else {
            prepared = nil
        }
        loading.completions.forEach { $0(prepared) }
    }

    private func cacheKey(_ asset: AssetRecord) -> String {
        "\(asset.identifier)#\(maximumPixelSize)"
    }
}

enum TransitionAnimator {
    static func preload(_ parameters: AssetRecord?) {
        guard let parameters else { return }
        TransitionFrameStore.shared.prepare(parameters)
    }

    static func purgeCaches() {
        TransitionFrameStore.shared.purge()
    }

    static func release(_ parameters: AssetRecord?) {
        TransitionFrameStore.shared.release(parameters)
    }

    static func duration(
        for style: OfficialTransitionStyle,
        parameters: AssetRecord? = nil
    ) -> CFTimeInterval {
        if let parameters {
            let frames = parameters.sprites.map(\.frameCount).max() ?? 0
            if frames > 0 { return Double(frames) / 30 }
        }
        switch style {
        case .dissolve: return 1.5
        case .horizontalWipe: return 1.9
        case .clockWipe: return 2.15
        case .circularWipe: return 2.0
        case .thoughtBubble: return 2.25
        case .sleepingDreamBubble: return 2.4
        }
    }

    static func reveal(
        incoming: CALayer,
        over outgoing: CALayer?,
        style: OfficialTransitionStyle,
        phase: SceneTransitionPhase = .reveal,
        parameters: AssetRecord? = nil,
        in bounds: CGRect,
        completion: @escaping () -> Void
    ) {
        guard let outgoing else {
            incoming.opacity = 0
            fade(incoming: incoming, outgoing: nil, completion: completion)
            return
        }
        if let prepared = TransitionFrameStore.shared.prepared(parameters),
           !prepared.masks.isEmpty {
            assetTransition(
                incoming: incoming, outgoing: outgoing, phase: phase,
                prepared: prepared, bounds: bounds, completion: completion
            )
            return
        }
        switch style {
        case .dissolve:
            fade(incoming: incoming, outgoing: outgoing, completion: completion)
        case .horizontalWipe:
            maskReveal(
                incoming, paths: horizontalPaths(bounds),
                duration: duration(for: style), completion: completion
            )
        case .clockWipe:
            maskReveal(
                incoming, paths: clockPaths(bounds),
                duration: duration(for: style), completion: completion
            )
        case .circularWipe:
            maskReveal(
                incoming, paths: circularPaths(bounds),
                duration: duration(for: style), completion: completion
            )
        case .thoughtBubble:
            maskReveal(
                incoming, paths: bubblePaths(bounds, sleeping: false),
                duration: duration(for: style), completion: completion
            )
        case .sleepingDreamBubble:
            maskReveal(
                incoming, paths: bubblePaths(bounds, sleeping: true),
                duration: duration(for: style), completion: completion
            )
        }
    }

    private static func assetTransition(
        incoming: CALayer,
        outgoing: CALayer,
        phase: SceneTransitionPhase,
        prepared: PreparedTransitionFrames,
        bounds: CGRect,
        completion: @escaping () -> Void
    ) {
        guard let root = incoming.superlayer ?? outgoing.superlayer else {
            completion()
            return
        }
        let target: CALayer
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        incoming.opacity = 1
        if phase == .hide {
            root.insertSublayer(incoming, below: outgoing)
            target = outgoing
        } else {
            root.addSublayer(incoming)
            target = incoming
        }

        let mask = CALayer()
        mask.frame = target.bounds
        mask.contentsGravity = .resizeAspectFill
        mask.contents = prepared.masks.first
        target.mask = mask

        let outline = CALayer()
        outline.frame = bounds
        outline.contentsGravity = .resizeAspectFill
        outline.zPosition = 10_000
        outline.contents = prepared.outlines.first
        if !prepared.outlines.isEmpty { root.addSublayer(outline) }
        CATransaction.commit()

        addContentsAnimation(
            to: mask, values: prepared.masks, duration: prepared.duration,
            key: "officialTransitionMask"
        )
        if !prepared.outlines.isEmpty {
            addContentsAnimation(
                to: outline, values: prepared.outlines, duration: prepared.duration,
                key: "officialTransitionOutline"
            )
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + prepared.duration) {
            guard target.mask === mask else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            target.mask = nil
            outline.removeFromSuperlayer()
            if phase == .hide {
                outgoing.opacity = 0
                root.addSublayer(incoming)
            }
            CATransaction.commit()
            completion()
        }
    }

    private static func addContentsAnimation(
        to layer: CALayer,
        values: [CGImage],
        duration: CFTimeInterval,
        key: String
    ) {
        guard !values.isEmpty else { return }
        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = values
        animation.keyTimes = values.indices.map {
            NSNumber(value: Double($0) / Double(max(1, values.count - 1)))
        }
        animation.calculationMode = .discrete
        animation.duration = duration
        animation.fillMode = .both
        animation.isRemovedOnCompletion = false
        layer.add(animation, forKey: key)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = values.last
        CATransaction.commit()
    }

    private static func fade(
        incoming: CALayer,
        outgoing: CALayer?,
        completion: @escaping () -> Void
    ) {
        let interval = duration(for: .dissolve)
        let fadeIn = CABasicAnimation(keyPath: "opacity")
        fadeIn.fromValue = 0
        fadeIn.toValue = 1
        fadeIn.duration = interval
        fadeIn.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        let fadeOut = CABasicAnimation(keyPath: "opacity")
        fadeOut.fromValue = outgoing?.presentation()?.opacity ?? outgoing?.opacity ?? 1
        fadeOut.toValue = 0
        fadeOut.duration = interval
        fadeOut.timingFunction = fadeIn.timingFunction
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        incoming.opacity = 1
        outgoing?.opacity = 0
        incoming.add(fadeIn, forKey: "snoopyFadeIn")
        outgoing?.add(fadeOut, forKey: "snoopyFadeOut")
        CATransaction.commit()
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: completion)
    }

    private static func maskReveal(
        _ incoming: CALayer,
        paths: [CGPath],
        duration: CFTimeInterval,
        completion: @escaping () -> Void
    ) {
        guard let first = paths.first, let last = paths.last else {
            completion()
            return
        }
        incoming.opacity = 0
        let mask = CAShapeLayer()
        mask.frame = incoming.bounds
        mask.fillColor = NSColor.white.cgColor
        mask.path = first
        incoming.mask = mask
        let animation = CAKeyframeAnimation(keyPath: "path")
        animation.values = paths
        animation.keyTimes = paths.indices.map {
            NSNumber(value: Double($0) / Double(max(1, paths.count - 1)))
        }
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        animation.fillMode = .both
        animation.isRemovedOnCompletion = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.path = last
        mask.add(animation, forKey: "officialRevealFallback")
        incoming.opacity = 1
        CATransaction.commit()
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            guard incoming.mask === mask else { return }
            incoming.mask = nil
            completion()
        }
    }

    private static func horizontalPaths(_ bounds: CGRect) -> [CGPath] {
        (0...12).map { step in
            let progress = CGFloat(step) / 12
            return CGPath(
                rect: CGRect(
                    x: bounds.minX, y: bounds.minY,
                    width: bounds.width * progress, height: bounds.height
                ),
                transform: nil
            )
        }
    }

    private static func circularPaths(_ bounds: CGRect) -> [CGPath] {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = hypot(bounds.width, bounds.height) * 0.6
        return (0...14).map { step in
            let r = max(0.5, radius * CGFloat(step) / 14)
            return CGPath(
                ellipseIn: CGRect(
                    x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r
                ),
                transform: nil
            )
        }
    }

    private static func clockPaths(_ bounds: CGRect) -> [CGPath] {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = hypot(bounds.width, bounds.height)
        return (0...24).map { step in
            let end = -.pi / 2 + 2 * .pi * CGFloat(step) / 24
            let path = CGMutablePath()
            path.move(to: center)
            path.addLine(to: CGPoint(x: center.x, y: center.y - radius))
            path.addArc(
                center: center, radius: radius,
                startAngle: -.pi / 2, endAngle: end, clockwise: false
            )
            path.closeSubpath()
            return path
        }
    }

    private static func bubblePaths(_ bounds: CGRect, sleeping: Bool) -> [CGPath] {
        let origin = sleeping
            ? CGPoint(x: bounds.maxX * 0.72, y: bounds.minY + bounds.height * 0.25)
            : CGPoint(x: bounds.minX + bounds.width * 0.28, y: bounds.minY + bounds.height * 0.28)
        let direction: CGFloat = sleeping ? -1 : 1
        let finalRadius = hypot(bounds.width, bounds.height)
        return (0...14).map { step in
            let progress = CGFloat(step) / 14
            let path = CGMutablePath()
            for index in 0..<4 {
                let t = min(1, max(0, progress * 1.8 - CGFloat(index) * 0.12))
                let r = (18 + CGFloat(index) * 18) * t
                let center = CGPoint(
                    x: origin.x + direction * CGFloat(index) * bounds.width * 0.08,
                    y: origin.y + CGFloat(index) * bounds.height * 0.09
                )
                path.addEllipse(
                    in: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)
                )
            }
            if progress > 0.38 {
                let t = (progress - 0.38) / 0.62
                let center = CGPoint(x: bounds.midX, y: bounds.midY)
                let r = max(1, finalRadius * t)
                path.addEllipse(
                    in: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)
                )
            }
            return path
        }
    }
}
