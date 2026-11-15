import AppKit
import AVFoundation
import ImageIO
import QuartzCore

/// Decodes HEIC frames away from the Core Animation commit path. `NSImage`
/// keeps its ImageIO source lazy, so merely creating one on the main thread
/// still leaves the expensive HEIF decompression for `CALayer` to perform.
/// The immediate thumbnail below guarantees that layers only ever receive
/// decoded pixels. A bounded shared cache and two workers limit memory and CPU.
final class FrameDecoder {
    private final class Entry {
        let image: CGImage
        let cost: Int
        init(_ image: CGImage) {
            self.image = image
            cost = image.bytesPerRow * image.height
        }
    }

    static let shared = FrameDecoder()

    typealias Callback = (CGImage?) -> Void
    private final class Request {
        var clients: Set<UUID> = []
        var callbacks: [UUID: [Callback]] = [:]
        var operation: BlockOperation?
    }

    private let cache = NSCache<NSString, Entry>()
    private let queue: OperationQueue
    private let decode: (URL, Int) -> CGImage?
    private let lock = NSLock()
    private var inFlight: [String: Request] = [:]

    init(decode: @escaping (URL, Int) -> CGImage? = FrameDecoder.decodeImage) {
        self.decode = decode
        cache.countLimit = 64
        cache.totalCostLimit = 256 * 1024 * 1024
        queue = OperationQueue()
        queue.name = "local.snoopy.frame-decoder"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 2
    }

    func key(for url: URL, maxPixelSize: Int) -> String {
        "\(url.path)#\(maxPixelSize)"
    }

    func cachedImage(for url: URL, maxPixelSize: Int) -> CGImage? {
        cache.object(forKey: key(for: url, maxPixelSize: maxPixelSize) as NSString)?.image
    }

    func request(
        _ url: URL,
        maxPixelSize: Int,
        clientID: UUID,
        completion: Callback? = nil
    ) {
        let cacheKey = key(for: url, maxPixelSize: maxPixelSize)
        lock.lock()
        if let image = cache.object(forKey: cacheKey as NSString)?.image {
            lock.unlock()
            completion?(image)
            return
        }

        if let request = inFlight[cacheKey] {
            request.clients.insert(clientID)
            if let completion { request.callbacks[clientID, default: []].append(completion) }
            lock.unlock()
            return
        }
        let request = Request()
        request.clients.insert(clientID)
        if let completion { request.callbacks[clientID] = [completion] }
        let operation = BlockOperation()
        request.operation = operation
        inFlight[cacheKey] = request
        lock.unlock()

        operation.addExecutionBlock { [weak self, weak request] in
            guard let self, let request, request.operation?.isCancelled == false else { return }
            let image = autoreleasepool {
                self.decode(url, maxPixelSize)
            }
            self.finish(cacheKey, request: request, image: image)
        }
        queue.addOperation(operation)
    }

    func cancelRequests(for clientID: UUID) {
        lock.lock()
        for key in Array(inFlight.keys) {
            guard let request = inFlight[key] else { continue }
            request.clients.remove(clientID)
            request.callbacks.removeValue(forKey: clientID)
            if request.clients.isEmpty {
                request.operation?.cancel()
                inFlight.removeValue(forKey: key)
            }
        }
        lock.unlock()
    }

    func removeAll() {
        lock.lock()
        let operations = inFlight.values.compactMap(\.operation)
        inFlight.removeAll()
        cache.removeAllObjects()
        lock.unlock()
        operations.forEach { $0.cancel() }
    }

    private func finish(_ cacheKey: String, request: Request, image: CGImage?) {
        lock.lock()
        guard inFlight[cacheKey] === request else {
            lock.unlock()
            return
        }
        inFlight.removeValue(forKey: cacheKey)
        if let image {
            let entry = Entry(image)
            cache.setObject(entry, forKey: cacheKey as NSString, cost: entry.cost)
        }
        let callbacks = request.callbacks.values.flatMap { $0 }
        lock.unlock()
        guard !callbacks.isEmpty else { return }
        OperationQueue.main.addOperation {
            callbacks.forEach { $0(image) }
        }
    }

    static func decodeImage(_ url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(
            url as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(64, maxPixelSize),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let sourceImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        // `ShouldCacheImmediately` makes this a decoded thumbnail rather than
        // the lazy ImageIO-backed image used by the old implementation.
        return sourceImage
    }
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
    private var frameGeneration = 0
    private var frameReady = false
    private var desiredFrameKey: String?
    private var pendingFrameKey: String?
    private var decoderClientID = UUID()
    private var frameURLs: [String: URL] = [:]
    private(set) var isPlaying = false
    var debugLayerCount: Int { layers.count }
    var onReady: (() -> Void)?

    init(host: CALayer, sceneOffset: CGPoint, hostBounds: @escaping () -> CGRect) {
        self.host = host; self.sceneOffset = sceneOffset; self.hostBounds = hostBounds
    }

    deinit { stop() }

    static func purgeCaches() { FrameDecoder.shared.removeAll() }

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
        guard frameReady, let descriptor = frameDescriptor, let layer = frameLayer else { return }
        let elapsed = Int(max(0, date.timeIntervalSince(frameStarted)) * 30)
        let local = descriptor.loops ? elapsed % descriptor.frameCount : min(descriptor.frameCount - 1, elapsed)
        requestFrame(descriptor.startFrame + local, descriptor: descriptor, layer: layer, generation: frameGeneration)
        prefetch(descriptor, after: local, count: 6)
    }

    func resize() {
        for layer in layers {
            guard let descriptor = layerDescriptors[ObjectIdentifier(layer)] else { continue }
            layer.frame = ViewportLayout.spriteFrame(descriptor, in: hostBounds(), sceneOffset: sceneOffset)
        }
    }

    func setHidden(_ hidden: Bool) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layers.forEach { $0.isHidden = hidden }
        CATransaction.commit()
    }

    func stop() {
        isPlaying = false
        FrameDecoder.shared.cancelRequests(for: decoderClientID)
        decoderClientID = UUID()
        frameGeneration += 1
        frameReady = false
        desiredFrameKey = nil
        pendingFrameKey = nil
        frameURLs.removeAll(keepingCapacity: false)
        onReady = nil
        workItems.forEach { $0.cancel() }; workItems.removeAll()
        observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
        observations.forEach { $0.invalidate() }; observations.removeAll()
        layers.compactMap { $0 as? AVPlayerLayer }.forEach { $0.player = nil }
        players.forEach {
            $0.cancelPendingPrerolls(); $0.pause(); $0.replaceCurrentItem(with: nil)
        }
        players.removeAll()
        layers.forEach { $0.removeAllAnimations(); $0.removeFromSuperlayer() }; layers.removeAll()
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
        layer.opacity = 0
        configure(layer, sprite: intro); frameLayer = layer
        let introDuration = Double(intro.frameCount) / 30
        let outroDuration = Double(outro.frameCount) / 30
        let loopDuration = max(Double(loop.frameCount) / 30, targetDuration - introDuration - outroDuration)
        activateFrame(intro, on: layer) { [weak self, weak layer] in
            guard let self, let layer, self.isPlaying else { return }
            self.schedule(introDuration) { [weak self, weak layer] in
                guard let self, let layer, self.isPlaying else { return }
                // Keep the same CALayer and retain the previous phase's last
                // frame until the first decoded frame of the next phase is
                // available. This avoids the one-frame transparent gap.
                self.activateFrame(loop, on: layer) { [weak self, weak layer] in
                    guard let self, let layer, self.isPlaying else { return }
                    self.schedule(loopDuration) { [weak self, weak layer] in
                        guard let self, let layer, self.isPlaying else { return }
                        self.activateFrame(outro, on: layer) { [weak self] in
                            guard let self, self.isPlaying else { return }
                            self.schedule(outroDuration) { [weak self] in
                                guard let self, self.isPlaying else { return }
                                self.isPlaying = false; completion?()
                            }
                        }
                    }
                }
            }
        }
    }

    private func playOneShot(_ sprite: SpriteDescriptor, repeatWhole: Bool, completion: (() -> Void)?) {
        if sprite.mediaType == .frameSequence {
            let layer = CALayer(); layer.contentsGravity = .resizeAspect
            layer.opacity = 0
            configure(layer, sprite: sprite); frameLayer = layer
            var descriptor = sprite
            if repeatWhole && !sprite.loops {
                descriptor = SpriteDescriptor(baseName: sprite.baseName, directoryURL: sprite.directoryURL,
                    mediaType: sprite.mediaType, phase: sprite.phase, assetSize: sprite.assetSize,
                    alignment: sprite.alignment, plane: sprite.plane, loops: true,
                    startFrame: sprite.startFrame, endFrame: sprite.endFrame, digitCount: sprite.digitCount)
            }
            activateFrame(descriptor, on: layer) { [weak self] in
                guard let self, self.isPlaying else { return }
                if !repeatWhole && !sprite.loops {
                    self.schedule(Double(sprite.frameCount) / 30) { [weak self] in
                        guard let self, self.isPlaying else { return }
                        self.isPlaying = false; completion?()
                    }
                }
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
    private func activateFrame(
        _ descriptor: SpriteDescriptor,
        on layer: CALayer,
        completion: (() -> Void)? = nil
    ) {
        frameGeneration += 1
        let generation = frameGeneration
        frameDescriptor = descriptor
        frameReady = false
        desiredFrameKey = nil
        pendingFrameKey = nil
        layerDescriptors[ObjectIdentifier(layer)] = descriptor
        layer.frame = ViewportLayout.spriteFrame(descriptor, in: hostBounds(), sceneOffset: sceneOffset)
        requestFrame(
            descriptor.startFrame,
            descriptor: descriptor,
            layer: layer,
            generation: generation
        ) { [weak self, weak layer] in
            guard let self, let layer, self.isPlaying, self.frameGeneration == generation else { return }
            self.frameReady = true
            self.frameStarted = Date()
            self.reveal(layer)
            completion?()
        }
        prefetch(descriptor, after: 0, count: 6)
    }

    private func requestFrame(
        _ frameNumber: Int,
        descriptor: SpriteDescriptor,
        layer: CALayer,
        generation: Int,
        firstFrameCompletion: (() -> Void)? = nil
    ) {
        guard let url = frameURL(frameNumber, descriptor: descriptor) else { return }
        let pixelSize = targetPixelSize(for: descriptor)
        let key = FrameDecoder.shared.key(for: url, maxPixelSize: pixelSize)
        desiredFrameKey = key

        if let image = FrameDecoder.shared.cachedImage(for: url, maxPixelSize: pixelSize) {
            installFrame(
                image,
                key: key,
                layer: layer,
                generation: generation,
                completion: firstFrameCompletion
            )
            return
        }
        guard pendingFrameKey != key else { return }
        pendingFrameKey = key
        FrameDecoder.shared.request(
            url,
            maxPixelSize: pixelSize,
            clientID: decoderClientID
        ) { [weak self, weak layer] image in
            guard let self, let layer else { return }
            if self.pendingFrameKey == key { self.pendingFrameKey = nil }
            guard let image, self.desiredFrameKey == key else { return }
            self.installFrame(
                image,
                key: key,
                layer: layer,
                generation: generation,
                completion: firstFrameCompletion
            )
        }
    }

    private func installFrame(
        _ image: CGImage,
        key: String,
        layer: CALayer,
        generation: Int,
        completion: (() -> Void)?
    ) {
        guard isPlaying, frameGeneration == generation, desiredFrameKey == key, frameLayer === layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = image
        CATransaction.commit()
        completion?()
    }

    private func prefetch(_ descriptor: SpriteDescriptor, after localFrame: Int, count: Int) {
        let pixelSize = targetPixelSize(for: descriptor)
        for offset in 1...count {
            let local: Int
            if descriptor.loops {
                local = (localFrame + offset) % descriptor.frameCount
            } else {
                local = min(descriptor.frameCount - 1, localFrame + offset)
            }
            guard let url = frameURL(descriptor.startFrame + local, descriptor: descriptor) else { continue }
            FrameDecoder.shared.request(url, maxPixelSize: pixelSize, clientID: decoderClientID)
            if !descriptor.loops && local == descriptor.frameCount - 1 { break }
        }
    }

    private func targetPixelSize(for descriptor: SpriteDescriptor) -> Int {
        let frame = ViewportLayout.spriteFrame(descriptor, in: hostBounds(), sceneOffset: sceneOffset)
        // Decode at the logical display size. The line-art assets remain crisp,
        // while a 40-frame base-pose loop can stay resident in the bounded
        // cache instead of being decompressed again on every repetition.
        let longestSide = min(1920, max(frame.width, frame.height))
        // Quantization prevents a resize from generating many nearly identical
        // cache variants while still decoding at the current display size.
        return max(256, Int(ceil(longestSide / 128)) * 128)
    }

    private func frameURL(_ number: Int, descriptor: SpriteDescriptor) -> URL? {
        let key = "\(descriptor.baseName)#\(number)"
        if let url = frameURLs[key] { return url }
        guard let url = descriptor.frameURL(number) else { return nil }
        frameURLs[key] = url
        return url
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
