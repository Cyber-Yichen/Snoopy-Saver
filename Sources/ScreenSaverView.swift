import AppKit
import AVFoundation
import QuartzCore
import ScreenSaver

@objc(SnoopyScreenSaverView)
final class SnoopyScreenSaverView: ScreenSaverView {
    private struct ActivePlayback {
        let container: CALayer
        let player: AVPlayer
        let scene: AssetRecord
        let startedAt: Date
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
    private var generation = 0
    private var lastTransitionPairID: String?
    private var revealedPlayerID: ObjectIdentifier?

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview); configure()
    }
    required init?(coder: NSCoder) { super.init(coder: coder); configure() }
    private func configure() {
        animationTimeInterval = 1.0 / 30; wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor; layer?.masksToBounds = true
    }

    override func startAnimation() {
        super.startAnimation(); generation += 1; let expected = generation
        showBootstrap()
        environment.start()
        if catalog != nil { playInitialScene(); return }
        let bundle = Bundle(for: SnoopyScreenSaverView.self)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try AssetCatalog(bundle: bundle) }
            DispatchQueue.main.async {
                guard let self, self.isAnimating, self.generation == expected else { return }
                switch result {
                case .success(let catalog): self.catalog = catalog; self.playInitialScene()
                case .failure(let error):
                    NSLog("Snoopy Multi-Layer catalog error: %@", String(describing: error))
                    // Retry once: ScreenSaverEngine may have raced a freshly
                    // replaced bundle on disk.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                        guard let self, self.isAnimating, self.generation == expected else { return }
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
                guard let self, self.isAnimating, self.generation == expected, let result else { return }
                self.catalog = result; self.playInitialScene()
            }
        }
    }

    override func stopAnimation() {
        generation += 1; removeObservers(); watchdog?.cancel(); watchdog = nil
        idle?.stop(); stop(active?.player); preparedIdle?.stop()
        idle = nil; active = nil; preparedIdle = nil
        environment.stop(); SpriteAssetPlayer.purgeCaches()
        layer?.sublayers?.forEach { $0.removeFromSuperlayer() }; bootstrapLayer = nil
        super.stopAnimation()
    }
    override func animateOneFrame() { idle?.tick(); environment.refreshIfNeeded() }
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
    @objc func idleTargetDurationForTesting() -> Double { idle?.targetDuration ?? 0 }
    @objc func idleCharacterAnimationCountForTesting() -> Int { idle?.specialAnimationCount ?? 0 }
    @objc func idleHalftonePresentForTesting() -> Bool { idle?.debugHasHalftone ?? false }

    private func playInitialScene() {
        // Keep the black bootstrap visible until the selected scene is ready,
        // then dissolve in. Each mode has an equal cold-start probability.
        Bool.random() ? playIdle() : playActive()
    }

    private func playIdle(
        durationOverride: TimeInterval? = nil,
        transitionOverride: TransitionChoice? = nil
    ) {
        guard isAnimating, let catalog, let root = layer else { return }
        removeObservers(); watchdog?.cancel(); watchdog = nil
        let oldActive = active, oldIdle = idle
        let incoming: IdleScenePlayback
        if let preparedIdle {
            incoming = preparedIdle
            self.preparedIdle = nil
        } else {
            let duration = durationOverride ?? Double.random(in: 20...60)
            guard let composition = catalog.makeIdleComposition(
                environment: environment.snapshot(), scorer: scorer
            ) else { return }
            incoming = IdleScenePlayback(
                composition: composition, catalog: catalog, scorer: scorer, environment: environment,
                frame: bounds, targetDuration: duration
            )
        }
        incoming.container.opacity = 0
        incoming.container.removeFromSuperlayer()
        idle = incoming; active = nil; root.addSublayer(incoming.container); incoming.start(); incoming.tick()
        incoming.onFinished = { [weak self, weak incoming] in
            guard let self, let incoming, self.idle === incoming, self.isAnimating else { return }
            self.playActive()
        }
        let choice: TransitionChoice
        if let transitionOverride { choice = transitionOverride }
        else if let oldActive {
            choice = catalog.transitionChoice(
                for: oldActive.scene, environment: environment.snapshot(), scorer: scorer,
                avoiding: lastTransitionPairID
            )
        } else { choice = TransitionChoice(pairID:"initial-dissolve", style:.dissolve, preventsIdleSceneChange:false) }
        lastTransitionPairID = choice.pairID
        NSLog("Snoopy transition %@ (%@) Active->Idle", choice.style.rawValue, choice.pairID)
        TransitionAnimator.reveal(
            incoming: incoming.container, over: oldActive?.container ?? oldIdle?.container ?? bootstrapLayer,
            style: choice.style, in: bounds
        ) { [weak self, weak incoming] in
            guard let self, let incoming, self.idle === incoming else { return }
            self.stop(oldActive?.player); oldActive?.container.removeFromSuperlayer()
            oldIdle?.stop(); oldIdle?.container.removeFromSuperlayer(); self.bootstrapLayer?.removeFromSuperlayer(); self.bootstrapLayer = nil
        }
    }

    private func playActive() {
        guard isAnimating, let catalog, let root = layer else { return }
        removeObservers(); watchdog?.cancel(); watchdog = nil
        preparedIdle?.stop(); preparedIdle?.container.removeFromSuperlayer(); preparedIdle = nil
        let outgoingIdle = idle, oldActive = active
        guard let scene = catalog.selectActive(environment: environment.snapshot(), scorer: scorer),
              let sprite = scene.sprites.first, let url = sprite.movieURL else { return }
        let item = AVPlayerItem(url: url), player = AVPlayer(playerItem: item)
        player.isMuted = true; player.volume = 0; player.actionAtItemEnd = .pause
        let container = CALayer(); container.frame = bounds; container.backgroundColor = NSColor.black.cgColor
        container.masksToBounds = true; container.opacity = 0
        let video = AVPlayerLayer(player: player); video.frame = bounds
        // ActiveScene is a single cinematic frame: preserve its aspect ratio
        // while filling the display, accepting only symmetric edge cropping.
        // IdleScene uses the metadata-driven aspect-fit viewport instead.
        video.videoGravity = .resizeAspectFill; container.addSublayer(video); root.addSublayer(container)
        let playback = ActivePlayback(container: container, player: player, scene: scene, startedAt: Date())
        active = playback; revealedPlayerID = nil
        let isInitialScene = outgoingIdle == nil && oldActive == nil
        let choice = isInitialScene
            ? TransitionChoice(pairID:"initial-dissolve", style:.dissolve, preventsIdleSceneChange:false)
            : catalog.transitionChoice(
                for: scene, environment: environment.snapshot(), scorer: scorer, avoiding: lastTransitionPairID
            )
        let exitChoice = catalog.transitionChoice(
            for: scene, environment: environment.snapshot(), scorer: scorer, avoiding: choice.pairID
        )
        installObservers(item, playback: playback, exitChoice: exitChoice)
        lastTransitionPairID = choice.pairID
        NSLog("Snoopy transition %@ (%@) Idle->Active", choice.style.rawValue, choice.pairID)
        let reveal = { [weak self, weak player] in
            guard let self, let player, self.active?.player === player else { return }
            let id = ObjectIdentifier(player)
            guard self.revealedPlayerID != id else { return }
            self.revealedPlayerID = id
            self.installActiveExitSchedule(item: item, playback: playback, choice: exitChoice)
            player.play()
            TransitionAnimator.reveal(
                incoming: container, over: oldActive?.container ?? outgoingIdle?.container ?? self.bootstrapLayer,
                style: choice.style, in: self.bounds
            ) { [weak self, weak player] in
                guard let self, let player, self.active?.player === player else { return }
                self.stop(oldActive?.player); oldActive?.container.removeFromSuperlayer()
                outgoingIdle?.stop(); outgoingIdle?.container.removeFromSuperlayer()
                if let outgoingIdle, self.idle === outgoingIdle { self.idle = nil }
                self.bootstrapLayer?.removeFromSuperlayer(); self.bootstrapLayer = nil
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
        playback: ActivePlayback,
        exitChoice: TransitionChoice
    ) {
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self, weak player = playback.player] _ in
            guard let self, let player, self.active?.player === player else { return }
            self.playIdle(transitionOverride: exitChoice)
        }
        failureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
        ) { [weak self, weak player = playback.player] _ in
            guard let self, let player, self.active?.player === player else { return }
            self.playIdle(transitionOverride: exitChoice)
        }
    }

    private func installActiveExitSchedule(
        item: AVPlayerItem,
        playback: ActivePlayback,
        choice: TransitionChoice
    ) {
        let total = item.duration.seconds
        guard total.isFinite, total > 0 else { return }
        let transitionStart = max(0.05, total - TransitionAnimator.duration(for: choice.style))
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
            NSLog("Snoopy begins %@ transition with %.2fs remaining", choice.style.rawValue, remaining)
            self.prepareIdleForActiveExit()
            self.playIdle(transitionOverride: choice)
        }
        activeTimeObservers.append((playback.player, transitionToken))
    }

    private func prepareIdleForActiveExit() {
        guard preparedIdle == nil, let catalog, let root = layer else { return }
        let duration = Double.random(in: 20...60)
        guard let composition = catalog.makeIdleComposition(
            environment: environment.snapshot(), scorer: scorer
        ) else { return }
        let incoming = IdleScenePlayback(
            composition: composition, catalog: catalog, scorer: scorer, environment: environment,
            frame: bounds, targetDuration: duration
        )
        incoming.container.opacity = 0
        root.addSublayer(incoming.container); incoming.prepare(); incoming.tick()
        preparedIdle = incoming
    }

    private func removeObservers() {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        for observer in activeTimeObservers { observer.player.removeTimeObserver(observer.token) }
        activeTimeObservers.removeAll()
        endObserver = nil; failureObserver = nil; readiness?.invalidate(); readiness = nil
    }

    private func stop(_ player: AVPlayer?) {
        player?.cancelPendingPrerolls(); player?.pause(); player?.replaceCurrentItem(with: nil)
    }

    private func showBootstrap() {
        guard let root = layer else { return }
        bootstrapLayer?.removeFromSuperlayer()
        let holder = CALayer(); holder.frame = bounds; holder.backgroundColor = NSColor.black.cgColor
        root.addSublayer(holder); bootstrapLayer = holder
    }
}
