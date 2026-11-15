import AppKit
import AVFoundation
import QuartzCore
import ScreenSaver

@objc(SnoopyScreenSaverView)
final class SnoopyScreenSaverView: ScreenSaverView {
    private final class WeakView {
        weak var value: SnoopyScreenSaverView?
        init(_ value: SnoopyScreenSaverView) { self.value = value }
    }

    /// Wallpaper mode may construct a replacement view without reliably
    /// stopping the previous one. Keep one live view per display (and one
    /// preview) so stale 30 fps animation loops cannot accumulate for days.
    private static var activeViews: [String: WeakView] = [:]

    private struct ActivePlayback {
        let container: CALayer
        let player: AVPlayer
        let playerLayer: AVPlayerLayer
        let transitionChoice: TransitionChoice?
        let transitionFrames: TransitionFrames?
        let preservedIdle: (composition: IdleComposition, poseID: String)?
    }

    private var catalog: AssetCatalog?
    private let scorer = RelevancyEngine()
    private let environment = EnvironmentProvider()
    private var idle: IdleScenePlayback?
    private var active: ActivePlayback?
    private var endObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?
    private var readiness: NSKeyValueObservation?
    private var activeTimeObservers: [(player: AVPlayer, token: Any)] = []
    private var watchdog: DispatchWorkItem?
    private var bootstrapLayer: CALayer?
    private var preparedIdle: IdleScenePlayback?
    private var retiringActive: ActivePlayback?
    private var retiringIdle: IdleScenePlayback?
    private var generation = 0
    private var lastTransitionPairID: String?
    private var lastRevealPoseID: String?
    // Local policy until the official consecutive-transition limit is verified.
    private static let maxConsecutivePreservedIdleScenes = 2
    private var consecutivePreservedIdleScenes = 0
    private var transition: TransitionAnimator?
    private var revealedPlayerID: ObjectIdentifier?
    private var activeStarted = false
    private var didStartIdleScene = false
    private var sessionActive = false
    private var coordinatorKey: String?
    private var nextEnvironmentRefresh = Date.distantPast

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview); configure()
    }
    required init?(coder: NSCoder) { super.init(coder: coder); configure() }
    deinit { shutdown() }
    private func configure() {
        animationTimeInterval = 1.0 / 30; wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor; layer?.masksToBounds = true
    }

    override func startAnimation() {
        guard !sessionActive else { return }
        super.startAnimation()
        sessionActive = true
        claimActiveSlot()
        generation += 1; let expected = generation
        nextEnvironmentRefresh = Date()
        showBootstrap()
        environment.start()
        if catalog != nil { playInitialScene(); return }
        let bundle = Bundle(for: SnoopyScreenSaverView.self)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try AssetCatalog(bundle: bundle) }
            DispatchQueue.main.async {
                guard let self, self.sessionActive, self.generation == expected else { return }
                switch result {
                case .success(let catalog): self.catalog = catalog; self.playInitialScene()
                case .failure(let error):
                    NSLog("Snoopy Multi-Layer catalog error: %@", String(describing: error))
                    // Retry once: ScreenSaverEngine may have raced a freshly
                    // replaced bundle on disk.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                        guard let self, self.sessionActive, self.generation == expected else { return }
                        self.startCatalogRetry(bundle: bundle, generation: expected)
                    }
                }
            }
        }
    }

    private func startCatalogRetry(bundle: Bundle, generation expected: Int) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = try? AssetCatalog(bundle: bundle)
            DispatchQueue.main.async {
                guard let self, self.sessionActive, self.generation == expected, let result else { return }
                self.catalog = result; self.playInitialScene()
            }
        }
    }

    override func stopAnimation() {
        shutdown()
        super.stopAnimation()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, sessionActive {
            claimActiveSlot()
        } else if window == nil, sessionActive {
            // Deferring avoids treating a transient detach/reattach as the end
            // of a wallpaper session.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window == nil, self.sessionActive else { return }
                self.stopAnimation()
            }
        }
    }

    override func animateOneFrame() {
        guard sessionActive else { return }
        let now = Date()
        idle?.tick()
        retiringIdle?.tick()
        if now >= nextEnvironmentRefresh {
            nextEnvironmentRefresh = now.addingTimeInterval(60)
            environment.refreshIfNeeded()
        }
    }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize); bootstrapLayer?.frame = bounds
        idle?.resize(bounds); active?.container.frame = bounds
        active?.container.sublayers?.forEach {
            if $0 is AVPlayerLayer { $0.frame = bounds }
            else { $0.frame = bounds }
        }
        retiringIdle?.resize(bounds)
        preparedIdle?.resize(bounds)
        retiringActive?.container.frame = bounds
        retiringActive?.playerLayer.frame = bounds
        transition?.resize()
    }
    override var hasConfigureSheet: Bool { false }
    override var configureSheet: NSWindow? { nil }

    @objc func forceNextSceneForTesting() { playActive() }
    @objc func forceIdleSceneForTesting() { playIdle(durationOverride: 12) }
    @objc func forceLongIdleSceneForTesting() { playIdle(durationOverride: 120) }
    @objc func idleTargetDurationForTesting() -> Double { idle?.targetDuration ?? 0 }
    @objc func idleCharacterAnimationCountForTesting() -> Int { idle?.specialAnimationCount ?? 0 }
    @objc func idleHalftonePresentForTesting() -> Bool { idle?.debugHasHalftone ?? false }
    @objc func idleActivityForTesting() -> NSNumber { NSNumber(value: idle?.debugActivity ?? 0) }
    @objc func sessionActiveForTesting() -> Bool { sessionActive }
    @objc class func activeInstanceCountForTesting() -> Int {
        activeViews = activeViews.filter { $0.value.value != nil }
        return activeViews.count
    }

    private func playInitialScene() {
        // Keep the black bootstrap visible until the selected scene is ready,
        // then dissolve in. Each mode has an equal cold-start probability.
        Bool.random() ? playIdle() : playActive()
    }

    private func playIdle(durationOverride: TimeInterval? = nil) {
        guard sessionActive, let root = layer else { return }
        let oldActive = active
        let choice = activeStarted ? oldActive?.transitionChoice : nil
        let incoming: IdleScenePlayback
        if let preparedIdle, durationOverride == nil {
            incoming = preparedIdle
            self.preparedIdle = nil
        } else {
            let duration = durationOverride ?? Double.random(in: 20...60)
            guard let next = makeIdlePlayback(preserving: oldActive?.preservedIdle, duration: duration)
            else { return }
            preparedIdle?.stop()
            preparedIdle = nil
            incoming = next
        }
        consecutivePreservedIdleScenes = oldActive?.preservedIdle == nil ? 0 : consecutivePreservedIdleScenes + 1
        retireCurrentScene()
        incoming.container.opacity = 0
        idle = incoming; root.addSublayer(incoming.container); incoming.prepare(); incoming.tick()
        incoming.onFinished = { [weak self, weak incoming] in
            guard let self, let incoming, self.idle === incoming, self.sessionActive else { return }
            self.playActive()
        }
        let animator = makeTransition(root: root, incoming: incoming.container, palette: incoming.composition.palette?.palette)
        var usesSprite = false
        animator.play(frames: choice == nil ? nil : oldActive?.transitionFrames, onSpriteStart: {
            usesSprite = true
        }, onCut: { [weak self, weak incoming] in
            guard let self, let incoming else { return }
            if usesSprite {
                incoming.playTransitionPose(choice?.revealPose)
                self.lastRevealPoseID = choice?.revealPose?.identifier ?? self.lastRevealPoseID
                self.logSpriteTransition(choice, direction: "Active->Idle")
            }
            incoming.start(firstScene: !self.didStartIdleScene)
            self.didStartIdleScene = true
        }) { [weak self, weak incoming] in
            guard let self, let incoming, self.idle === incoming else { return }
            incoming.clearTransitionPose()
            self.finishTransition()
        }
    }

    private func playActive() {
        guard sessionActive, let catalog, let root = layer else { return }
        guard let scene = catalog.selectActive(environment: environment.snapshot(), scorer: scorer),
              let url = scene.activeMovieURL else {
            if active == nil { playIdle() }
            return
        }
        preparedIdle?.stop(); preparedIdle = nil
        let oldIdle = idle
        let outgoingPalette = oldIdle?.composition.palette?.palette
        let choice = catalog.transitionChoice(
            for: scene, environment: environment.snapshot(), scorer: scorer,
            avoiding: lastTransitionPairID, avoidingRevealPose: lastRevealPoseID,
            allowIdlePreservation: oldIdle != nil
                && consecutivePreservedIdleScenes < Self.maxConsecutivePreservedIdleScenes
        )
        let transitionFrames = choice.map { TransitionFrames(choice: $0, pixelWidth: bounds.width) }
        let preservedIdle = choice?.preventsIdleSceneChange == true
            ? oldIdle.map { ($0.composition, $0.currentPoseID) } : nil
        retireCurrentScene()
        let item = AVPlayerItem(url: url), player = AVPlayer(playerItem: item)
        player.isMuted = true; player.volume = 0; player.actionAtItemEnd = .pause
        let container = CALayer(); container.frame = bounds; container.backgroundColor = NSColor.black.cgColor
        container.masksToBounds = true; container.opacity = 0
        let video = AVPlayerLayer(player: player); video.frame = bounds
        // ActiveScene is a single cinematic frame: preserve its aspect ratio
        // while filling the display, accepting only symmetric edge cropping.
        // IdleScene uses the metadata-driven aspect-fit viewport instead.
        video.videoGravity = .resizeAspectFill; container.addSublayer(video); root.addSublayer(container)
        let playback = ActivePlayback(
            container: container, player: player, playerLayer: video,
            transitionChoice: choice, transitionFrames: transitionFrames, preservedIdle: preservedIdle
        )
        active = playback; revealedPlayerID = nil
        installObservers(item, playback: playback)
        lastTransitionPairID = choice?.pairID
        let reveal = { [weak self, weak player] in
            guard let self, let player, self.active?.player === player else { return }
            let id = ObjectIdentifier(player)
            guard self.revealedPlayerID != id else { return }
            self.revealedPlayerID = id
            self.watchdog?.cancel(); self.watchdog = nil
            let animator = self.makeTransition(root: root, incoming: container, palette: outgoingPalette)
            let frames = self.retiringIdle == nil ? nil : self.active?.transitionFrames
            animator.play(frames: frames, onSpriteStart: { [weak self] in
                self?.retiringIdle?.playTransitionPose(choice?.hidePose)
                self?.logSpriteTransition(choice, direction: "Idle->Active")
            }, onCut: { [weak self, weak player] in
                guard let self, let player, let playback = self.active, playback.player === player else { return }
                self.activeStarted = true
                self.installActiveExitSchedule(item: item, playback: playback)
                player.play()
            }) { [weak self, weak player] in
                guard let self, let player, self.active?.player === player else { return }
                self.finishTransition()
            }
        }
        readiness = item.observe(\.status, options: [.initial, .new]) { [weak self, weak player] item, _ in
            DispatchQueue.main.async {
                guard let self, let player, self.active?.player === player else { return }
                if item.status == .failed {
                    self.playIdle()
                } else if item.status == .readyToPlay {
                    player.preroll(atRate: 1) { success in
                        if success { DispatchQueue.main.async(execute: reveal) }
                    }
                }
            }
        }
        let timeout = DispatchWorkItem { [weak self, weak player] in
            guard let self, let player, self.active?.player === player else { return }
            if item.status == .readyToPlay { reveal() }
            else { self.playIdle() }
        }
        watchdog = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: timeout)
    }

    private func installObservers(
        _ item: AVPlayerItem,
        playback: ActivePlayback
    ) {
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self, weak player = playback.player] _ in
            guard let self, let player, self.active?.player === player else { return }
            self.playIdle()
        }
        failureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
        ) { [weak self, weak player = playback.player] _ in
            guard let self, let player, self.active?.player === player else { return }
            self.playIdle()
        }
    }

    private func installActiveExitSchedule(
        item: AVPlayerItem,
        playback: ActivePlayback
    ) {
        let total = item.duration.seconds
        guard total.isFinite, total > 0 else { return }
        // The cut happens after Hide. Start that phase early enough to reach
        // its nominal end at the end of the outgoing clip.
        let leadTime = playback.transitionChoice?.hide.duration ?? TransitionAnimator.dissolveDuration
        let transitionStart = max(0.05, total - leadTime)
        let preloadStart = max(0.02, transitionStart - 1.0)
        let preloadToken = playback.player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: CMTime(seconds: preloadStart, preferredTimescale: 600))], queue: .main
        ) { [weak self, weak player = playback.player] in
            guard let self, let player, self.active?.player === player else { return }
            let remaining = max(0, total - player.currentTime().seconds)
            NSLog("Snoopy preloaded IdleScene %.2fs before ActiveScene end", remaining)
            self.prepareIdleForActiveExit()
        }
        activeTimeObservers.append((playback.player, preloadToken))
        let transitionToken = playback.player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: CMTime(seconds: transitionStart, preferredTimescale: 600))], queue: .main
        ) { [weak self, weak player = playback.player] in
            guard let self, let player, self.active?.player === player else { return }
            let remaining = max(0, total - player.currentTime().seconds)
            NSLog("Snoopy begins transition with %.2fs remaining", remaining)
            self.prepareIdleForActiveExit()
            self.playIdle()
        }
        activeTimeObservers.append((playback.player, transitionToken))
    }

    private func prepareIdleForActiveExit() {
        guard sessionActive, preparedIdle == nil else { return }
        let duration = Double.random(in: 20...60)
        guard let incoming = makeIdlePlayback(preserving: active?.preservedIdle, duration: duration) else { return }
        incoming.prepare(); incoming.tick()
        preparedIdle = incoming
    }

    private func makeIdlePlayback(
        preserving saved: (composition: IdleComposition, poseID: String)?,
        duration: TimeInterval
    ) -> IdleScenePlayback? {
        guard let catalog, let composition = saved?.composition ?? catalog.makeIdleComposition(
            environment: environment.snapshot(), scorer: scorer
        ) else { return nil }
        return IdleScenePlayback(
            composition: composition, catalog: catalog, scorer: scorer, environment: environment,
            frame: bounds, targetDuration: duration,
            initialPoseID: saved?.poseID
        )
    }

    private func makeTransition(root: CALayer, incoming: CALayer, palette: Palette?) -> TransitionAnimator {
        if retiringLayer != nil {
            bootstrapLayer?.removeFromSuperlayer()
            bootstrapLayer = nil
        }
        let animator = TransitionAnimator(
            root: root, incoming: incoming, outgoing: retiringLayer ?? bootstrapLayer,
            backdrop: palette?.background.cgColor ?? NSColor.black.cgColor
        )
        transition = animator
        return animator
    }

    private func logSpriteTransition(_ choice: TransitionChoice?, direction: String) {
        guard let choice else { return }
        NSLog("Snoopy sprite transition %@ %@ (%@) %.3fs hide / %.3fs reveal", direction,
              choice.style.rawValue, choice.pairID, choice.hide.duration, choice.reveal.duration)
    }

    private func removeObservers() {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        for observer in activeTimeObservers { observer.player.removeTimeObserver(observer.token) }
        activeTimeObservers.removeAll()
        endObserver = nil; failureObserver = nil; readiness?.invalidate(); readiness = nil
    }

    private func stop(_ playback: ActivePlayback?) {
        guard let playback else { return }
        playback.playerLayer.player = nil
        playback.player.cancelPendingPrerolls()
        playback.player.pause()
        playback.player.replaceCurrentItem(with: nil)
        playback.container.removeAllAnimations()
        playback.container.removeFromSuperlayer()
    }

    private var retiringLayer: CALayer? {
        retiringActive?.container ?? retiringIdle?.container
    }

    private func retireCurrentScene() {
        transition?.cancel(); transition = nil
        idle?.stopScheduling()
        idle?.clearTransitionPose()
        removeObservers()
        watchdog?.cancel(); watchdog = nil
        if let active, !activeStarted {
            // Keep the existing outgoing scene while discarding the unseen player.
            stop(active)
        } else {
            clearRetiringScene()
            retiringActive = active
            retiringIdle = idle
            if let retiringLayer { TransitionAnimator.finishReveal(retiringLayer) }
        }
        active = nil
        idle = nil
        revealedPlayerID = nil
        activeStarted = false
    }

    private func finishTransition() {
        transition = nil
        clearRetiringScene()
        bootstrapLayer?.removeFromSuperlayer(); bootstrapLayer = nil
    }

    private func clearRetiringScene() {
        stop(retiringActive)
        retiringIdle?.stop()
        retiringIdle?.container.removeAllAnimations()
        retiringIdle?.container.removeFromSuperlayer()
        retiringActive = nil
        retiringIdle = nil
    }

    private func showBootstrap() {
        guard let root = layer else { return }
        bootstrapLayer?.removeFromSuperlayer()
        let holder = CALayer(); holder.frame = bounds; holder.backgroundColor = NSColor.black.cgColor
        root.addSublayer(holder); bootstrapLayer = holder
    }

    private func shutdown() {
        guard sessionActive || idle != nil || active != nil || preparedIdle != nil
                || retiringLayer != nil else {
            _ = releaseActiveSlot()
            return
        }
        sessionActive = false
        generation += 1
        transition?.cancel(); transition = nil
        removeObservers()
        watchdog?.cancel(); watchdog = nil

        idle?.stop(); idle?.container.removeAllAnimations(); idle?.container.removeFromSuperlayer()
        preparedIdle?.stop(); preparedIdle?.container.removeAllAnimations(); preparedIdle?.container.removeFromSuperlayer()
        stop(active)
        clearRetiringScene()
        idle = nil; active = nil; preparedIdle = nil
        revealedPlayerID = nil
        activeStarted = false
        consecutivePreservedIdleScenes = 0
        didStartIdleScene = false
        lastTransitionPairID = nil; lastRevealPoseID = nil
        environment.stop()
        layer?.sublayers?.forEach {
            if let playerLayer = $0 as? AVPlayerLayer { playerLayer.player = nil }
            $0.removeAllAnimations()
            $0.removeFromSuperlayer()
        }
        bootstrapLayer = nil
        if releaseActiveSlot() {
            SpriteAssetPlayer.purgeCaches()
            TransitionFrames.purgeCache()
        }
    }

    private func claimActiveSlot() {
        let key = activationKey()
        if let previousKey = coordinatorKey, previousKey != key,
           Self.activeViews[previousKey]?.value === self {
            Self.activeViews.removeValue(forKey: previousKey)
        }
        Self.activeViews = Self.activeViews.filter { $0.value.value != nil }
        let previous = Self.activeViews[key]?.value
        coordinatorKey = key
        Self.activeViews[key] = WeakView(self)
        if let previous, previous !== self {
            NSLog("Snoopy stopping stale screen saver view for %@", key)
            previous.stopAnimation()
        }
    }

    @discardableResult
    private func releaseActiveSlot() -> Bool {
        if let key = coordinatorKey, Self.activeViews[key]?.value === self {
            Self.activeViews.removeValue(forKey: key)
        }
        coordinatorKey = nil
        Self.activeViews = Self.activeViews.filter { $0.value.value != nil }
        return Self.activeViews.isEmpty
    }

    private func activationKey() -> String {
        if isPreview { return "preview" }
        let screenNumberKey = NSDeviceDescriptionKey("NSScreenNumber")
        if let number = window?.screen?.deviceDescription[screenNumberKey] as? NSNumber {
            return "screen-\(number.stringValue)"
        }
        return "fullscreen"
    }
}
