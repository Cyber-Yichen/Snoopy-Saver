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
    private var frameReadiness: NSKeyValueObservation?
    private var activeTimeObservers: [(player: AVPlayer, token: Any)] = []
    private var watchdog: DispatchWorkItem?
    private var idleReadyTimeout: DispatchWorkItem?
    private var bootstrapLayer: CALayer?
    private var preparedIdle: IdleScenePlayback?
    private var retiringActive: ActivePlayback?
    private var retiringIdle: IdleScenePlayback?
    private var generation = 0
    /// Bumped when a scene change commits or the session stops. Deferred
    /// end-of-movie callbacks captured the previous value and then no-op.
    private var playbackEpoch = 0
    private var lastTransitionPairID: String?
    // Local policy until the official consecutive-transition limit is verified.
    private static let maxConsecutivePreservedIdleScenes = 2
    private var consecutivePreservedIdleScenes = 0
    private var transition: TransitionAnimator?
    private var revealedPlayerID: ObjectIdentifier?
    private var activeStarted = false
    private var idleStarted = false
    private var didStartIdleScene = false
    private var sessionActive = false
    private var coordinatorKey: String?
    private var nextEnvironmentRefresh: CFTimeInterval = 0
    private var resourcesSuspended = false
    private var sawOnscreenWindow = false
    private var visibilityObserver: NSObjectProtocol?
    private var resumeActivePlayback = false
    private var resumeRetiringPlayback = false

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
        nextEnvironmentRefresh = 0
        showBootstrap()
        environment.start()
        installVisibilityWatch()
        updateResourceSuspension()
        if catalog != nil { playInitialScene(); return }
        let bundle = Bundle(for: SnoopyScreenSaverView.self)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try AssetCatalog(bundle: bundle) }
            let urls = (try? result.get())?.movieURLs() ?? []
            MediaTimingCache.shared.prepare(urls) { [weak self] in
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
    }

    private func startCatalogRetry(bundle: Bundle, generation expected: Int) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = try? AssetCatalog(bundle: bundle)
            MediaTimingCache.shared.prepare(result?.movieURLs() ?? []) { [weak self] in
                DispatchQueue.main.async {
                    guard let self, self.sessionActive, self.generation == expected, let result else { return }
                    self.catalog = result; self.playInitialScene()
                }
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
            installVisibilityWatch()
            updateResourceSuspension()
        } else if window == nil, sessionActive {
            // Deferring avoids treating a transient detach/reattach as the end
            // of a wallpaper session.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window == nil, self.sessionActive else { return }
                self.stopAnimation()
            }
        }
    }

    override func viewDidHide() {
        super.viewDidHide()
        updateResourceSuspension()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        updateResourceSuspension()
    }

    override func animateOneFrame() {
        guard sessionActive, !resourcesSuspended else { return }
        let now = CACurrentMediaTime()
        idle?.tick()
        retiringIdle?.tick()
        if now >= nextEnvironmentRefresh {
            nextEnvironmentRefresh = now + 60
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
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        for scene in [idle, retiringIdle, preparedIdle] {
            scene?.container.contentsScale = backingScale
        }
    }
    private var backingScale: CGFloat { window?.backingScaleFactor ?? layer?.contentsScale ?? 1 }
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
        let oldActive = activeStarted ? active : retiringActive
        let choice = oldActive?.transitionChoice
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
        let preservesIdle = oldActive?.preservedIdle != nil
        playbackEpoch += 1
        retireCurrentScene()
        incoming.container.opacity = 0
        idle = incoming; root.addSublayer(incoming.container); incoming.prepare(); incoming.tick()
        incoming.onFinished = { [weak self, weak incoming] in
            guard let self, let incoming, self.idle === incoming, self.sessionActive else { return }
            self.playActive()
        }
        let begin = { [weak self, weak incoming, weak root, frames = choice == nil ? nil : oldActive?.transitionFrames] in
            guard let self, let incoming, let root, self.idle === incoming, self.idleReadyTimeout != nil else { return }
            self.idleReadyTimeout?.cancel()
            self.idleReadyTimeout = nil
            incoming.onInitialFrameReady = nil
            let animator = self.makeTransition(root: root, incoming: incoming.container)
            animator.play(frames: frames, direction: .reveal, onStart: { [weak self] usesSprite in
                guard let self else { return }
                self.idleStarted = true
                self.consecutivePreservedIdleScenes = preservesIdle ? self.consecutivePreservedIdleScenes + 1 : 0
                // Keep the same prepared base character during and after Reveal.
                if usesSprite { self.logSpriteTransition(choice, direction: .reveal) }
            }) { [weak self, weak incoming] in
                guard let self, let incoming, self.idle === incoming else { return }
                self.finishTransition()
                incoming.start(firstScene: !self.didStartIdleScene)
                self.didStartIdleScene = true
            }
        }
        let timeout = DispatchWorkItem(block: begin)
        idleReadyTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: timeout)
        // Defer even a cached first frame so a replacement in this turn can
        // discard the hidden scene without interrupting the visible one.
        incoming.onInitialFrameReady = { DispatchQueue.main.async(execute: begin) }
    }

    private func playActive() {
        guard sessionActive, let catalog, let root = layer else { return }
        guard let scene = catalog.selectActive(environment: environment.snapshot(), scorer: scorer),
              let url = scene.activeMovieURL else {
            if active == nil { playIdle() }
            return
        }
        preparedIdle?.stop(); preparedIdle = nil
        playbackEpoch += 1
        let oldIdle = idleStarted ? idle : (activeStarted ? nil : retiringIdle)
        let choice = catalog.transitionChoice(
            for: scene, environment: environment.snapshot(), scorer: scorer,
            avoiding: lastTransitionPairID, avoidingRevealPose: nil,
            allowIdlePreservation: oldIdle != nil
                && consecutivePreservedIdleScenes < Self.maxConsecutivePreservedIdleScenes
        )
        let transitionFrames = choice.map {
            let aspect = ViewportLayout.designSize.width / ViewportLayout.designSize.height
            return TransitionFrames(choice: $0, pixelWidth: max(bounds.width, bounds.height * aspect) * backingScale)
        }
        let preservedIdle = choice?.preventsIdleSceneChange == true
            ? oldIdle.map { ($0.composition, $0.currentPoseID) } : nil
        retireCurrentScene()
        retiringIdle?.prepareHidePose(choice?.hidePose)
        let item = AVPlayerItem(url: url), player = AVPlayer(playerItem: item)
        PlayerPolicy.apply(player)
        let container = CALayer(); container.frame = bounds
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
            guard let self, let player, self.active?.player === player, video.isReadyForDisplay else { return }
            let id = ObjectIdentifier(player)
            guard self.revealedPlayerID != id else { return }
            self.revealedPlayerID = id
            self.frameReadiness?.invalidate(); self.frameReadiness = nil
            self.watchdog?.cancel(); self.watchdog = nil
            let animator = self.makeTransition(root: root, incoming: container)
            let frames = self.retiringIdle == nil ? nil : self.active?.transitionFrames
            animator.play(frames: frames, direction: .hide, onStart: { [weak self, weak player] usesSprite in
                guard let self, let player, let playback = self.active, playback.player === player else { return }
                if usesSprite {
                    self.retiringIdle?.startPreparedHidePose()
                    self.logSpriteTransition(choice, direction: .hide)
                } else {
                    self.retiringIdle?.discardPreparedHidePose()
                }
                self.activeStarted = true
                self.installActiveExitSchedule(item: item, playback: playback)
                player.play()
            }) { [weak self, weak player] in
                guard let self, let player, self.active?.player === player else { return }
                self.finishTransition()
            }
        }
        var primingStarted = false
        var rewound = false
        let prepareReveal = { [weak self, weak player, weak video] in
            guard let self, let player, let video, video.isReadyForDisplay,
                  self.active?.player === player else { return }
            // Seeking may temporarily clear readiness. Whichever arrives
            // last, frame readiness or seek completion, can start the cut.
            if rewound { reveal(); return }
            guard !primingStarted else { return }
            primingStarted = true
            player.pause()
            if player.currentTime() <= .zero {
                rewound = true
                reveal()
            } else {
                player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak player] success in
                    DispatchQueue.main.async {
                        guard let self, let player, self.active?.player === player else { return }
                        guard success else { self.playIdle(); return }
                        rewound = true
                        reveal()
                    }
                }
            }
        }
        frameReadiness = video.observe(\.isReadyForDisplay, options: [.initial, .new]) { _, _ in
            DispatchQueue.main.async(execute: prepareReveal)
        }
        readiness = item.observe(\.status, options: [.initial, .new]) { [weak self, weak player, weak video] item, _ in
            DispatchQueue.main.async {
                guard let self, let player, let video, self.active?.player === player else { return }
                if item.status == .failed {
                    self.playIdle()
                } else if item.status == .readyToPlay, !primingStarted {
                    if video.isReadyForDisplay { prepareReveal() }
                    else { player.play() }
                }
            }
        }
        let timeout = DispatchWorkItem { [weak self, weak player] in
            guard let self, let player, self.active?.player === player else { return }
            self.playIdle()
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
        // The outgoing movie stays under Reveal until it is fully covered.
        let leadTime = playback.transitionChoice?.reveal.duration ?? TransitionAnimator.dissolveDuration
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
            let capturedEpoch = self.playbackEpoch
            SceneAdvance.deferBoundaryAdvance(
                sessionActive: { [weak self] in self?.sessionActive == true },
                epoch: { [weak self] in self?.playbackEpoch ?? -1 },
                capturedEpoch: capturedEpoch,
                playerStillCurrent: { [weak self] in self?.active?.player === player },
                advance: { [weak self] in
                    guard let self else { return }
                    self.prepareIdleForActiveExit()
                    self.playIdle()
                }
            )
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
        let playback = IdleScenePlayback(
            composition: composition, catalog: catalog, scorer: scorer, environment: environment,
            frame: bounds, targetDuration: duration,
            initialPoseID: saved?.poseID
        )
        playback.container.contentsScale = backingScale
        return playback
    }

    private func makeTransition(root: CALayer, incoming: CALayer) -> TransitionAnimator {
        if retiringLayer != nil {
            bootstrapLayer?.removeFromSuperlayer()
            bootstrapLayer = nil
        }
        let animator = TransitionAnimator(
            root: root, incoming: incoming, outgoing: retiringLayer ?? bootstrapLayer
        )
        transition = animator
        return animator
    }

    private func logSpriteTransition(_ choice: TransitionChoice?, direction: TransitionAnimator.Direction) {
        guard let choice else { return }
        let phase = direction == .hide ? choice.hide : choice.reveal
        NSLog("Snoopy sprite transition %@ %@ (%@) %.3fs", direction.rawValue,
              choice.style.rawValue, choice.pairID, phase.duration)
    }

    private func removeObservers() {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        for observer in activeTimeObservers { observer.player.removeTimeObserver(observer.token) }
        activeTimeObservers.removeAll()
        endObserver = nil; failureObserver = nil; readiness?.invalidate(); readiness = nil
        frameReadiness?.invalidate(); frameReadiness = nil
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
        idle?.retire()
        removeObservers()
        watchdog?.cancel(); watchdog = nil
        idleReadyTimeout?.cancel(); idleReadyTimeout = nil
        if let active, !activeStarted {
            // Keep the existing outgoing scene while discarding the unseen player.
            stop(active)
        } else if let idle, !idleStarted {
            idle.stop()
            idle.container.removeFromSuperlayer()
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
        idleStarted = false
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
        playbackEpoch += 1
        if let visibilityObserver { NotificationCenter.default.removeObserver(visibilityObserver) }
        visibilityObserver = nil
        resourcesSuspended = false
        sawOnscreenWindow = false
        resumeActivePlayback = false
        resumeRetiringPlayback = false
        transition?.cancel(); transition = nil
        removeObservers()
        watchdog?.cancel(); watchdog = nil
        idleReadyTimeout?.cancel(); idleReadyTimeout = nil

        idle?.stop(); idle?.container.removeAllAnimations(); idle?.container.removeFromSuperlayer()
        preparedIdle?.stop(); preparedIdle?.container.removeAllAnimations(); preparedIdle?.container.removeFromSuperlayer()
        stop(active)
        clearRetiringScene()
        idle = nil; active = nil; preparedIdle = nil
        revealedPlayerID = nil
        activeStarted = false
        idleStarted = false
        consecutivePreservedIdleScenes = 0
        didStartIdleScene = false
        lastTransitionPairID = nil
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
        // A fullscreen view can start before macOS has attached it to a
        // display. Unattached views cannot evict each other provisionally.
        guard let key = activationKey() else {
            _ = releaseActiveSlot()
            return
        }
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

    /// Suspend decode only after the host has shown the window and then taken
    /// it offscreen or hidden the view. A normal fullscreen saver stays
    /// `isVisible` for the whole session, so occlusion by itself must not pause it.
    static func shouldSuspendPlayback(
        sessionActive: Bool,
        sawOnscreenWindow: Bool,
        windowVisible: Bool,
        viewHidden: Bool
    ) -> Bool {
        guard sessionActive else { return false }
        if windowVisible && !viewHidden { return false }
        return sawOnscreenWindow
    }

    private func installVisibilityWatch() {
        if let visibilityObserver { NotificationCenter.default.removeObserver(visibilityObserver) }
        visibilityObserver = nil
        guard let window else { return }
        visibilityObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.updateResourceSuspension()
        }
    }

    private func updateResourceSuspension() {
        if window?.isVisible == true && !isHidden { sawOnscreenWindow = true }
        let suspend = Self.shouldSuspendPlayback(
            sessionActive: sessionActive,
            sawOnscreenWindow: sawOnscreenWindow,
            windowVisible: window?.isVisible == true,
            viewHidden: isHidden
        )
        if suspend {
            if !resourcesSuspended { setResourcesSuspended(true) }
        } else if resourcesSuspended {
            setResourcesSuspended(false)
        }
    }

    private func setResourcesSuspended(_ suspended: Bool) {
        guard resourcesSuspended != suspended else { return }
        resourcesSuspended = suspended
        // The screen-saver timer does not always pick up a new interval immediately.
        // animateOneFrame also returns immediately while suspended.
        animationTimeInterval = suspended ? 5 : 1.0 / 30
        if suspended {
            resumeActivePlayback = (active?.player.rate ?? 0) > 0
            resumeRetiringPlayback = (retiringActive?.player.rate ?? 0) > 0
            active?.player.pause()
            retiringActive?.player.pause()
        }
        idle?.setResourcesPaused(suspended)
        retiringIdle?.setResourcesPaused(suspended)
        preparedIdle?.setResourcesPaused(suspended)
        if !suspended {
            if resumeActivePlayback { active?.player.play() }
            if resumeRetiringPlayback { retiringActive?.player.play() }
            resumeActivePlayback = false
            resumeRetiringPlayback = false
        }
    }

    private func activationKey() -> String? {
        if isPreview { return "preview" }
        let screenNumberKey = NSDeviceDescriptionKey("NSScreenNumber")
        if let number = window?.screen?.deviceDescription[screenNumberKey] as? NSNumber {
            return "screen-\(number.stringValue)"
        }
        return nil
    }
}
