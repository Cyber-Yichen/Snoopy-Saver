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
        let scene: AssetRecord
        let transition: TransitionChoice
        let startedAt: Date
    }

    private struct ActiveSelection {
        let scene: AssetRecord
        let transition: TransitionChoice
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
    private var preparedActiveSelection: ActiveSelection?
    private var preservedIdleComposition: IdleComposition?
    private var retiringActives: [ActivePlayback] = []
    private var retiringIdles: [IdleScenePlayback] = []
    private var generation = 0
    private var lastTransitionPairID: String?
    private var lastTransitionRevealPoseID: String?
    private var revealedPlayerID: ObjectIdentifier?
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
        let bundle = Bundle(for: SnoopyScreenSaverView.self)
        CDNMediaUpdater.shared.checkForUpdates(bundle: bundle)
        if catalog != nil { playInitialScene(); return }
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
        idle?.tick(now)
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
    }
    override var hasConfigureSheet: Bool { false }
    override var configureSheet: NSWindow? { nil }

    @objc func forceNextSceneForTesting() { playActive() }
    @objc func forceIdleSceneForTesting() { playIdle(durationOverride: 12) }
    @objc func forceLongIdleSceneForTesting() { playIdle(durationOverride: 120) }
    @objc func idleTargetDurationForTesting() -> Double { idle?.targetDuration ?? 0 }
    @objc func idleCharacterAnimationCountForTesting() -> Int { idle?.specialAnimationCount ?? 0 }
    @objc func idleHalftonePresentForTesting() -> Bool { idle?.debugHasHalftone ?? false }
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

    private func fallbackTransition(_ identifier: String) -> TransitionChoice {
        TransitionChoice(
            categoryID: "fallback", pairID: identifier, style: .dissolve,
            preventsIdleSceneChange: false, hideCharacterPose: nil,
            revealCharacterPose: nil, hideParameters: nil, revealParameters: nil
        )
    }

    private func playIdle(
        durationOverride: TimeInterval? = nil,
        transitionOverride: TransitionChoice? = nil
    ) {
        guard sessionActive, let catalog, let root = layer else { return }
        removeObservers(); watchdog?.cancel(); watchdog = nil
        let oldActive = active, oldIdle = idle
        finishSupersededTransitions(
            keepingActive: oldActive, keepingIdle: oldIdle
        )
        let choice = transitionOverride ?? oldActive?.transition
            ?? fallbackTransition("initial-dissolve")
        let incoming: IdleScenePlayback
        if let preparedIdle {
            incoming = preparedIdle
            self.preparedIdle = nil
        } else {
            let duration = durationOverride ?? Double.random(in: 20...60)
            let composition: IdleComposition?
            if choice.preventsIdleSceneChange, let preservedIdleComposition {
                composition = preservedIdleComposition
            } else {
                composition = catalog.makeIdleComposition(
                    environment: environment.snapshot(), scorer: scorer
                )
            }
            guard let composition else { return }
            incoming = IdleScenePlayback(
                composition: composition, catalog: catalog, scorer: scorer, environment: environment,
                frame: bounds, targetDuration: duration
            )
        }
        preservedIdleComposition = nil
        retainForTransition(oldActive)
        retainForTransition(oldIdle)
        incoming.container.opacity = 0
        incoming.container.removeFromSuperlayer()
        incoming.onFinished = { [weak self, weak incoming] in
            guard let self, let incoming, self.idle === incoming, self.sessionActive else { return }
            self.playActive()
        }
        incoming.onApproachingFinish = { [weak self, weak incoming] in
            guard let self, let incoming, self.idle === incoming, self.sessionActive else { return }
            self.prepareActiveForIdleExit()
        }
        idle = incoming
        active = nil
        root.addSublayer(incoming.container)
        incoming.start()
        if oldActive != nil {
            incoming.playTransitionPose(choice.revealCharacterPose, resumeBaseAfter: true)
        }
        incoming.tick()
        NSLog("Snoopy transition %@ (%@) Active->Idle", choice.style.rawValue, choice.pairID)
        TransitionAnimator.reveal(
            incoming: incoming.container, over: oldActive?.container ?? oldIdle?.container ?? bootstrapLayer,
            style: choice.style, phase: .reveal, parameters: choice.revealParameters, in: bounds
        ) { [weak self, weak incoming] in
            guard let self, let incoming, self.idle === incoming else { return }
            self.finishRetiring(oldActive)
            self.finishRetiring(oldIdle)
            self.bootstrapLayer?.removeFromSuperlayer(); self.bootstrapLayer = nil
            TransitionAnimator.release(choice.revealParameters)
        }
    }

    private func playActive() {
        guard sessionActive, let catalog, let root = layer else { return }
        removeObservers(); watchdog?.cancel(); watchdog = nil
        preparedIdle?.stop(); preparedIdle?.container.removeFromSuperlayer(); preparedIdle = nil
        let outgoingIdle = idle, oldActive = active
        finishSupersededTransitions(
            keepingActive: oldActive, keepingIdle: outgoingIdle
        )
        let snapshot = environment.snapshot()
        let selection: ActiveSelection
        if let preparedActiveSelection {
            selection = preparedActiveSelection
            self.preparedActiveSelection = nil
        } else {
            guard let scene = catalog.selectActive(
                environment: snapshot, scorer: scorer, markSelection: false
            ) else { return }
            selection = ActiveSelection(
                scene: scene,
                transition: catalog.transitionChoice(
                    for: scene, environment: snapshot, scorer: scorer,
                    avoiding: lastTransitionPairID,
                    avoidingRevealPoseID: lastTransitionRevealPoseID
                )
            )
        }
        let scene = selection.scene
        let choice = selection.transition
        guard let sprite = scene.sprites.first, let url = sprite.movieURL else {
            return
        }
        scorer.mark(scene, kind: "activeScene", at: snapshot.date)
        catalog.markTransitionChoice(choice, environment: snapshot, scorer: scorer)
        lastTransitionPairID = choice.pairID
        lastTransitionRevealPoseID = choice.revealCharacterPose?.identifier
        if choice.preventsIdleSceneChange, let outgoingIdle {
            preservedIdleComposition = outgoingIdle.composition
        } else {
            preservedIdleComposition = nil
        }
        TransitionAnimator.preload(choice.hideParameters)
        retainForTransition(oldActive)
        retainForTransition(outgoingIdle)
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
            container: container, player: player, playerLayer: video, scene: scene,
            transition: choice, startedAt: Date()
        )
        active = playback; revealedPlayerID = nil
        let isInitialScene = outgoingIdle == nil && oldActive == nil
        let entryChoice = isInitialScene ? fallbackTransition("initial-dissolve") : choice
        installObservers(item, playback: playback)
        NSLog("Snoopy transition %@ (%@) Idle->Active", entryChoice.style.rawValue, entryChoice.pairID)
        let reveal = { [weak self, weak player] in
            guard let self, let player, self.active?.player === player else { return }
            let id = ObjectIdentifier(player)
            guard self.revealedPlayerID != id else { return }
            self.revealedPlayerID = id
            self.installActiveExitSchedule(item: item, playback: playback, choice: choice)
            outgoingIdle?.playTransitionPose(choice.hideCharacterPose, resumeBaseAfter: false)
            player.play()
            TransitionAnimator.reveal(
                incoming: container, over: oldActive?.container ?? outgoingIdle?.container ?? self.bootstrapLayer,
                style: entryChoice.style, phase: .hide,
                parameters: entryChoice.hideParameters, in: self.bounds
            ) { [weak self, weak player] in
                guard let self, let player, self.active?.player === player else { return }
                self.finishRetiring(oldActive)
                self.finishRetiring(outgoingIdle)
                if let outgoingIdle, self.idle === outgoingIdle { self.idle = nil }
                self.bootstrapLayer?.removeFromSuperlayer(); self.bootstrapLayer = nil
                TransitionAnimator.release(choice.hideParameters)
                TransitionAnimator.preload(choice.revealParameters)
            }
        }
        readiness = item.observe(\.status, options: [.initial, .new]) { [weak self, weak player] item, _ in
            guard item.status == .readyToPlay, let self, let player, self.active?.player === player else { return }
            DispatchQueue.main.async { player.preroll(atRate: 1) { _ in DispatchQueue.main.async(execute: reveal) } }
        }
        let timeout = DispatchWorkItem(block: reveal); watchdog = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: timeout)
    }

    private func installObservers(
        _ item: AVPlayerItem,
        playback: ActivePlayback
    ) {
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self, weak player = playback.player] _ in
            guard let self, let player, self.active?.player === player,
                  let transition = self.active?.transition else { return }
            self.playIdle(transitionOverride: transition)
        }
        failureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
        ) { [weak self, weak player = playback.player] _ in
            guard let self, let player, self.active?.player === player,
                  let transition = self.active?.transition else { return }
            self.playIdle(transitionOverride: transition)
        }
    }

    private func installActiveExitSchedule(
        item: AVPlayerItem,
        playback: ActivePlayback,
        choice: TransitionChoice
    ) {
        let total = item.duration.seconds
        guard total.isFinite, total > 0 else { return }
        let transitionStart = max(
            0.05,
            total - TransitionAnimator.duration(for: choice.style, parameters: choice.revealParameters)
        )
        let preloadStart = max(0.02, transitionStart - 1.0)
        let preloadToken = playback.player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: CMTime(seconds: preloadStart, preferredTimescale: 600))], queue: .main
        ) { [weak self, weak player = playback.player] in
            guard let self, let player, self.active?.player === player else { return }
            let remaining = max(0, total - player.currentTime().seconds)
            NSLog("Snoopy preloaded IdleScene %.2fs before ActiveScene end", remaining)
            self.prepareIdleForActiveExit(choice: choice)
        }
        activeTimeObservers.append((playback.player, preloadToken))
        let transitionToken = playback.player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: CMTime(seconds: transitionStart, preferredTimescale: 600))], queue: .main
        ) { [weak self, weak player = playback.player] in
            guard let self, let player, self.active?.player === player else { return }
            let remaining = max(0, total - player.currentTime().seconds)
            NSLog("Snoopy begins %@ transition with %.2fs remaining", choice.style.rawValue, remaining)
            self.prepareIdleForActiveExit(choice: choice)
            self.playIdle(transitionOverride: choice)
        }
        activeTimeObservers.append((playback.player, transitionToken))
    }

    private func prepareIdleForActiveExit(choice: TransitionChoice) {
        guard sessionActive, preparedIdle == nil, let catalog, let root = layer else { return }
        let duration = Double.random(in: 20...60)
        let composition: IdleComposition?
        if choice.preventsIdleSceneChange, let preservedIdleComposition {
            composition = preservedIdleComposition
        } else {
            composition = catalog.makeIdleComposition(
                environment: environment.snapshot(), scorer: scorer
            )
        }
        guard let composition else { return }
        let incoming = IdleScenePlayback(
            composition: composition, catalog: catalog, scorer: scorer, environment: environment,
            frame: bounds, targetDuration: duration
        )
        incoming.container.opacity = 0
        root.addSublayer(incoming.container); incoming.prepare(); incoming.tick()
        preparedIdle = incoming
    }

    private func prepareActiveForIdleExit() {
        guard sessionActive, preparedActiveSelection == nil, let catalog else { return }
        let snapshot = environment.snapshot()
        guard let scene = catalog.selectActive(
            environment: snapshot, scorer: scorer, markSelection: false
        ) else { return }
        let choice = catalog.transitionChoice(
            for: scene, environment: snapshot, scorer: scorer,
            avoiding: lastTransitionPairID,
            avoidingRevealPoseID: lastTransitionRevealPoseID
        )
        preparedActiveSelection = ActiveSelection(scene: scene, transition: choice)
        TransitionAnimator.preload(choice.hideParameters)
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

    private func retainForTransition(_ playback: ActivePlayback?) {
        guard let playback,
              !retiringActives.contains(where: { $0.player === playback.player }) else { return }
        retiringActives.append(playback)
    }

    private func retainForTransition(_ playback: IdleScenePlayback?) {
        guard let playback,
              !retiringIdles.contains(where: { $0 === playback }) else { return }
        retiringIdles.append(playback)
    }

    private func finishRetiring(_ playback: ActivePlayback?) {
        guard let playback else { return }
        stop(playback)
        retiringActives.removeAll { $0.player === playback.player }
    }

    private func finishRetiring(_ playback: IdleScenePlayback?) {
        guard let playback else { return }
        playback.stop()
        playback.container.removeAllAnimations()
        playback.container.removeFromSuperlayer()
        retiringIdles.removeAll { $0 === playback }
    }

    private func finishSupersededTransitions(
        keepingActive: ActivePlayback?,
        keepingIdle: IdleScenePlayback?
    ) {
        let staleActives = retiringActives.filter {
            guard let keepingActive else { return true }
            return $0.player !== keepingActive.player
        }
        let staleIdles = retiringIdles.filter {
            guard let keepingIdle else { return true }
            return $0 !== keepingIdle
        }
        staleActives.forEach { finishRetiring($0) }
        staleIdles.forEach { finishRetiring($0) }
    }

    private func showBootstrap() {
        guard let root = layer else { return }
        bootstrapLayer?.removeFromSuperlayer()
        let holder = CALayer(); holder.frame = bounds; holder.backgroundColor = NSColor.black.cgColor
        root.addSublayer(holder); bootstrapLayer = holder
    }

    private func shutdown() {
        guard sessionActive || idle != nil || active != nil || preparedIdle != nil
                || preparedActiveSelection != nil
                || !retiringActives.isEmpty || !retiringIdles.isEmpty else {
            _ = releaseActiveSlot()
            return
        }
        sessionActive = false
        generation += 1
        removeObservers()
        watchdog?.cancel(); watchdog = nil

        idle?.stop(); idle?.container.removeAllAnimations(); idle?.container.removeFromSuperlayer()
        preparedIdle?.stop(); preparedIdle?.container.removeAllAnimations(); preparedIdle?.container.removeFromSuperlayer()
        stop(active)
        retiringActives.forEach { stop($0) }
        retiringIdles.forEach {
            $0.stop(); $0.container.removeAllAnimations(); $0.container.removeFromSuperlayer()
        }
        retiringActives.removeAll(); retiringIdles.removeAll()
        idle = nil; active = nil; preparedIdle = nil; preparedActiveSelection = nil
        preservedIdleComposition = nil
        revealedPlayerID = nil
        environment.stop()
        layer?.sublayers?.forEach {
            if let playerLayer = $0 as? AVPlayerLayer { playerLayer.player = nil }
            $0.removeAllAnimations()
            $0.removeFromSuperlayer()
        }
        bootstrapLayer = nil
        if releaseActiveSlot() {
            TransitionAnimator.purgeCaches()
            SpriteAssetPlayer.purgeCaches()
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
