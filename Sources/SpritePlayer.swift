import AppKit
import AVFoundation
import ImageIO
import QuartzCore

private final class FrameCache {
    static let shared = FrameCache()
    private let cache = NSCache<NSString, NSImage>()
    private init() {
        cache.countLimit = 32
        cache.totalCostLimit = 192 * 1024 * 1024
    }
    func image(_ url: URL) -> NSImage? {
        let key = url.path as NSString
        if let image = cache.object(forKey: key) { return image }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let image = NSImage(cgImage: cg, size: .zero)
        cache.setObject(image, forKey: key, cost: cg.width * cg.height * 4)
        return image
    }
    func removeAll() { cache.removeAllObjects() }
}

final class SpriteAssetPlayer {
    private let host: CALayer
    private let hostBounds: () -> CGRect
    private let sceneOffset: CGPoint
    private var layers: [CALayer] = []
    private var layerDescriptors: [ObjectIdentifier: SpriteDescriptor] = [:]
    private var players: [AVPlayer] = []
    private var observers: [NSObjectProtocol] = []
    private var observations: [NSKeyValueObservation] = []
    private var workItems: [DispatchWorkItem] = []
    private var frameLayer: CALayer?
    private var frameDescriptor: SpriteDescriptor?
    private var frameStarted = Date()
    private(set) var isPlaying = false
    var debugLayerCount: Int { layers.count }
    var onReady: (() -> Void)?

    init(host: CALayer, sceneOffset: CGPoint, hostBounds: @escaping () -> CGRect) {
        self.host = host; self.sceneOffset = sceneOffset; self.hostBounds = hostBounds
    }

    deinit { stop() }

    static func purgeCaches() { FrameCache.shared.removeAll() }

    func play(
        _ asset: AssetRecord,
        targetDuration: TimeInterval = 10,
        repeatWhole: Bool = false,
        completion: (() -> Void)? = nil
    ) {
        // `play` resets any previous media but must preserve the readiness
        // callback the caller just installed for an atomic layer handoff.
        let readinessCallback = onReady
        stop(); onReady = readinessCallback; isPlaying = true
        let phased = asset.sprites.contains { $0.phase != .oneShot }
        if phased, asset.sprites.allSatisfy({ $0.mediaType == .video }) {
            playSeamlessVideoPhases(asset.sprites, targetDuration: targetDuration, completion: completion)
        } else if phased, asset.sprites.allSatisfy({ $0.mediaType == .frameSequence }) {
            playSeamlessFramePhases(asset.sprites, targetDuration: targetDuration, completion: completion)
        } else if let sprite = asset.sprites.first(where: { $0.phase == .oneShot }) {
            playOneShot(sprite, repeatWhole: repeatWhole, completion: completion)
        } else {
            isPlaying = false; completion?()
        }
    }

    func tick(_ date: Date = Date()) {
        guard let descriptor = frameDescriptor, let layer = frameLayer else { return }
        let elapsed = Int(max(0, date.timeIntervalSince(frameStarted)) * 30)
        let local = descriptor.loops ? elapsed % descriptor.frameCount : min(descriptor.frameCount - 1, elapsed)
        if let url = descriptor.frameURL(descriptor.startFrame + local), let image = FrameCache.shared.image(url) {
            layer.contents = image
        }
    }

    func resize() {
        for layer in layers {
            guard let descriptor = layerDescriptors[ObjectIdentifier(layer)] else { continue }
            layer.frame = ViewportLayout.spriteFrame(descriptor, in: hostBounds(), sceneOffset: sceneOffset)
        }
    }

    func stop() {
        isPlaying = false
        onReady = nil
        workItems.forEach { $0.cancel() }; workItems.removeAll()
        observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
        observations.forEach { $0.invalidate() }; observations.removeAll()
        players.forEach {
            $0.cancelPendingPrerolls(); $0.pause(); $0.replaceCurrentItem(with: nil)
        }
        players.removeAll()
        layers.forEach { $0.removeFromSuperlayer() }; layers.removeAll()
        layerDescriptors.removeAll()
        frameLayer = nil; frameDescriptor = nil
    }

    private func playSeamlessVideoPhases(
        _ sprites: [SpriteDescriptor],
        targetDuration: TimeInterval,
        completion: (() -> Void)?
    ) {
        guard let first = sprites.first, let firstURL = first.movieURL else { isPlaying = false; completion?(); return }
        let intro = sprites.first { $0.phase == .intro }
        let loop = sprites.first { $0.phase == .loop }
        let outro = sprites.first { $0.phase == .outro }
        let introDuration = intro.flatMap(\.movieURL).map(duration) ?? 0
        let loopDuration = max(0.1, loop.flatMap(\.movieURL).map(duration) ?? 0.1)
        let outroDuration = outro.flatMap(\.movieURL).map(duration) ?? 0
        let desiredLoop = max(loopDuration, targetDuration - introDuration - outroDuration)
        let loopCount = max(1, Int((desiredLoop / loopDuration).rounded()))
        var entries: [(SpriteDescriptor, URL)] = []
        if let intro, let url = intro.movieURL { entries.append((intro, url)) }
        if let loop, let url = loop.movieURL { for _ in 0..<loopCount { entries.append((loop, url)) } }
        if let outro, let url = outro.movieURL { entries.append((outro, url)) }
        if entries.isEmpty { entries = [(first, firstURL)] }
        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { isPlaying = false; completion?(); return }
        var cursor = CMTime.zero
        var insertedAny = false
        for (_, url) in entries {
            let sourceAsset = AVURLAsset(url: url)
            guard let sourceTrack = sourceAsset.tracks(withMediaType: .video).first else { continue }
            let sourceDuration = sourceAsset.duration
            guard sourceDuration.isValid, sourceDuration.seconds.isFinite, sourceDuration.seconds > 0 else { continue }
            do {
                try compositionTrack.insertTimeRange(
                    CMTimeRange(start: .zero, duration: sourceDuration), of: sourceTrack, at: cursor
                )
                if !insertedAny { compositionTrack.preferredTransform = sourceTrack.preferredTransform }
                cursor = CMTimeAdd(cursor, sourceDuration); insertedAny = true
            } catch {
                NSLog("Snoopy sprite composition error: %@", String(describing: error))
            }
        }
        guard insertedAny else { isPlaying = false; completion?(); return }
        let item = AVPlayerItem(asset: composition)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true; player.volume = 0; player.actionAtItemEnd = .pause
        let layer = AVPlayerLayer(player: player)
        configure(layer, sprite: entries[0].0); layer.opacity = 0
        players.append(player)
        observers.append(NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            guard let self, self.isPlaying else { return }
            self.isPlaying = false; completion?()
        })
        observeReady(item, player: player, layer: layer)
    }

    private func playSeamlessFramePhases(
        _ sprites: [SpriteDescriptor],
        targetDuration: TimeInterval,
        completion: (() -> Void)?
    ) {
        guard let intro = sprites.first(where: { $0.phase == .intro }),
              let loop = sprites.first(where: { $0.phase == .loop }),
              let outro = sprites.first(where: { $0.phase == .outro }) else {
            if let first = sprites.first { playOneShot(first, repeatWhole: first.loops, completion: completion) }
            return
        }
        let layer = CALayer(); layer.contentsGravity = .resizeAspect
        configure(layer, sprite: intro); frameLayer = layer
        activateFrame(intro, on: layer); reveal(layer)
        let introDuration = Double(intro.frameCount) / 30
        let outroDuration = Double(outro.frameCount) / 30
        let loopDuration = max(Double(loop.frameCount) / 30, targetDuration - introDuration - outroDuration)
        schedule(introDuration) { [weak self, weak layer] in
            guard let self, let layer, self.isPlaying else { return }
            // Keep the same CALayer and replace contents only after the first
            // incoming frame has decoded. There is no remove/add blank frame.
            self.activateFrame(loop, on: layer)
            self.schedule(loopDuration) { [weak self, weak layer] in
                guard let self, let layer, self.isPlaying else { return }
                self.activateFrame(outro, on: layer)
                self.schedule(outroDuration) { [weak self] in
                    guard let self, self.isPlaying else { return }
                    self.isPlaying = false; completion?()
                }
            }
        }
    }

    private func playOneShot(_ sprite: SpriteDescriptor, repeatWhole: Bool, completion: (() -> Void)?) {
        if sprite.mediaType == .frameSequence {
            let layer = CALayer(); layer.contentsGravity = .resizeAspect
            configure(layer, sprite: sprite); frameLayer = layer
            var descriptor = sprite
            if repeatWhole && !sprite.loops {
                descriptor = SpriteDescriptor(baseName: sprite.baseName, directoryURL: sprite.directoryURL,
                    mediaType: sprite.mediaType, phase: sprite.phase, assetSize: sprite.assetSize,
                    alignment: sprite.alignment, plane: sprite.plane, loops: true,
                    startFrame: sprite.startFrame, endFrame: sprite.endFrame, digitCount: sprite.digitCount)
            }
            activateFrame(descriptor, on: layer); reveal(layer)
            if !repeatWhole && !sprite.loops {
                schedule(Double(sprite.frameCount) / 30) { [weak self] in self?.isPlaying = false; completion?() }
            }
        } else if let url = sprite.movieURL {
            let item = AVPlayerItem(url: url), player = AVPlayer(playerItem: item)
            player.isMuted = true; player.volume = 0; player.actionAtItemEnd = .pause
            let layer = AVPlayerLayer(player: player); configure(layer, sprite: sprite); layer.opacity = 0
            players.append(player)
            observers.append(NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
            ) { [weak self, weak player] _ in
                guard let self, self.isPlaying else { return }
                if repeatWhole || sprite.loops {
                    player?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero); player?.play()
                } else { self.isPlaying = false; completion?() }
            })
            observeReady(item, player: player, layer: layer)
        }
    }

    private func observeReady(_ item: AVPlayerItem, player: AVPlayer, layer: CALayer) {
        observations.append(item.observe(\.status, options: [.initial, .new]) { [weak self, weak player, weak layer] item, _ in
            guard item.status == .readyToPlay, let self, let player, let layer, self.isPlaying else { return }
            DispatchQueue.main.async {
                player.preroll(atRate: 1) { [weak self, weak player, weak layer] _ in
                    DispatchQueue.main.async {
                        guard let self, let player, let layer, self.isPlaying else { return }
                        self.reveal(layer); player.play()
                    }
                }
            }
        })
    }

    private func reveal(_ layer: CALayer) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.opacity = 1
        CATransaction.commit()
        onReady?(); onReady = nil
    }
    private func activateFrame(_ descriptor: SpriteDescriptor, on layer: CALayer) {
        if let url = descriptor.frameURL(descriptor.startFrame), let image = FrameCache.shared.image(url) {
            layer.contents = image
        }
        frameDescriptor = descriptor; frameStarted = Date()
        layerDescriptors[ObjectIdentifier(layer)] = descriptor
        layer.frame = ViewportLayout.spriteFrame(descriptor, in: hostBounds(), sceneOffset: sceneOffset)
    }
    private func configure(_ layer: CALayer, sprite: SpriteDescriptor) {
        layer.frame = ViewportLayout.spriteFrame(sprite, in: hostBounds(), sceneOffset: sceneOffset)
        layer.zPosition = PlaneOrder.z(sprite.plane); layer.masksToBounds = false
        layerDescriptors[ObjectIdentifier(layer)] = sprite
        if let video = layer as? AVPlayerLayer { video.videoGravity = .resizeAspect }
        host.addSublayer(layer); layers.append(layer)
    }
    private func duration(_ url: URL) -> TimeInterval {
        let value = AVURLAsset(url: url).duration.seconds
        return value.isFinite && value > 0 ? value : 3
    }
    private func schedule(_ delay: TimeInterval, _ block: @escaping () -> Void) {
        let item = DispatchWorkItem(block: block); workItems.append(item)
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.01, delay), execute: item)
    }
}
