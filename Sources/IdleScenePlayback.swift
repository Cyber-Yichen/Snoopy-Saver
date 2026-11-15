import AppKit
import QuartzCore

final class IdleScenePlayback {
    let container = CALayer()
    let composition: IdleComposition
    let targetDuration: TimeInterval
    var onFinished: (() -> Void)?
    private(set) var specialAnimationCount = 0

    private let catalog: AssetCatalog
    private let scorer: RelevancyEngine
    private let environment: EnvironmentProvider
    private let background = CALayer()
    private let halftone = CALayer()
    private let halftoneMask = CALayer()
    private var permanent: [SpriteAssetPlayer] = []
    private var character: SpriteAssetPlayer?
    private var transitionCharacter: SpriteAssetPlayer?
    private var visitors: [SpriteAssetPlayer] = []
    private var tasks: [DispatchWorkItem] = []
    private(set) var currentPoseID: String
    private var animationCounts: [AssetKind: Int] = [.characterBasePose: 1]
    private var prepared = false
    private var activated = false
    private var stopped = false
    var debugHasHalftone: Bool {
        halftone.superlayer === container && halftone.mask === halftoneMask && halftoneMask.contents != nil
    }

    init(
        composition: IdleComposition,
        catalog: AssetCatalog,
        scorer: RelevancyEngine,
        environment: EnvironmentProvider,
        frame: CGRect,
        targetDuration: TimeInterval,
        initialPoseID: String? = nil
    ) {
        self.composition = composition; self.catalog = catalog; self.scorer = scorer
        self.environment = environment; self.targetDuration = targetDuration
        currentPoseID = initialPoseID ?? composition.basePose.identifier
        container.frame = frame; container.masksToBounds = true
        background.frame = container.bounds
        background.backgroundColor = composition.palette?.palette?.background.cgColor
            ?? NSColor(calibratedRed: 0.86, green: 0.82, blue: 0.70, alpha: 1).cgColor
        background.zPosition = 0; container.addSublayer(background)
        if let overlay = composition.palette?.palette?.overlay,
           let url = Bundle(for: SnoopyScreenSaverView.self).url(forResource: "halftone_pattern", withExtension: "png"),
           let image = NSImage(contentsOf: url),
           let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            // Official composition: palette background, then overlayColor
            // tinted through halftone_pattern's alpha, then every sprite plane.
            halftone.frame = container.bounds; halftone.backgroundColor = overlay.cgColor; halftone.zPosition = 1
            // CALayer officially retains CGImage contents. Supplying NSImage
            // could render once and then disappear in a later IdleScene.
            halftoneMask.frame = container.bounds; halftoneMask.contents = cgImage; halftoneMask.contentsGravity = .resizeAspectFill
            halftone.mask = halftoneMask; container.addSublayer(halftone)
        }
    }

    func prepare() {
        guard !prepared else { return }
        prepared = true
        stopped = false
        let scene = player(offset: composition.scene.sceneOffset)
        scene.play(composition.scene, repeatWhole: true); permanent.append(scene)
        if let effect = composition.fullscreenEffect {
            let p = player(offset: effect.ignoresSceneOffset ? .zero : composition.scene.sceneOffset)
            p.play(effect, targetDuration: targetDuration, repeatWhole: true); permanent.append(p)
        }
        startBasePose(replacing: nil)
    }

    func start() {
        prepare()
        guard !activated else { return }
        activated = true; stopped = false
        scheduleCharacter(after: Double.random(in: 6...12))
        scheduleVisitor(after: Double.random(in: 3...9))
        schedule(targetDuration) { [weak self] in self?.finish() }
    }

    func tick(_ date: Date = Date()) {
        permanent.forEach { $0.tick(date) }; character?.tick(date); visitors.forEach { $0.tick(date) }
    }

    func playTransitionPose(_ pose: AssetRecord?) {
        guard let pose else { return }
        let action = player(offset: composition.scene.sceneOffset)
        transitionCharacter?.stop()
        transitionCharacter = action
        action.onReady = { [weak self, weak action] in
            guard let self, let action, self.transitionCharacter === action else { return }
            self.character?.setHidden(true)
        }
        action.play(pose)
    }

    func clearTransitionPose() {
        transitionCharacter?.stop()
        transitionCharacter = nil
        character?.setHidden(false)
    }

    func resize(_ frame: CGRect) {
        container.frame = frame; background.frame = container.bounds; halftone.frame = container.bounds; halftoneMask.frame = container.bounds
        permanent.forEach { $0.resize() }; character?.resize(); visitors.forEach { $0.resize() }
        transitionCharacter?.resize()
    }
    func stop() {
        clearTransitionPose()
        stopped = true; tasks.forEach { $0.cancel() }; tasks.removeAll()
        permanent.forEach { $0.stop() }; character?.stop(); visitors.forEach { $0.stop() }
        permanent.removeAll(); visitors.removeAll(); character = nil
        prepared = false; activated = false
    }

    private func startBasePose(replacing old: SpriteAssetPlayer?) {
        let base = catalog.assets(.characterBasePose).first { $0.identifier == currentPoseID }
            ?? composition.basePose
        let next = player(offset: composition.scene.sceneOffset)
        // Overlay sprites cut only after the incoming first frame is ready.
        // The official Idle composition does not dissolve these layers.
        next.onReady = { old?.stop() }
        next.play(base, repeatWhole: true)
        character = next
    }

    private func scheduleCharacter(after delay: TimeInterval) {
        schedule(delay) { [weak self] in
            guard let self, !self.stopped else { return }
            if self.transitionCharacter != nil {
                self.scheduleCharacter(after: 1)
                return
            }
            let snapshot = self.environment.snapshot()
            let dependency = self.dependencyEnvironment()
            let kind = self.nextAnimationKind()
            let animation: AssetRecord?
            if kind == .characterBasePose { animation = self.catalog.selectPoseTransition(from: self.currentPoseID) }
            else {
                animation = self.catalog.selectCharacterAnimation(
                    from: self.currentPoseID, kind: kind, scene: self.composition.scene,
                    environment: snapshot, dependencyEnvironment: dependency, scorer: self.scorer
                )
            }
            guard let animation else { self.scheduleCharacter(after: 5); return }
            let old = self.character
            let next = self.player(offset: self.composition.scene.sceneOffset)
            next.onReady = { old?.stop() }
            self.character = next
            self.animationCounts[kind, default: 0] += 1
            if kind != .characterBasePose { self.specialAnimationCount += 1 }
            next.play(animation, targetDuration: Double.random(in: 7...13)) { [weak self, weak next] in
                guard let self, let next, self.character === next, !self.stopped else { return }
                self.currentPoseID = animation.endPoseID ?? self.currentPoseID
                self.startBasePose(replacing: next)
                self.scheduleCharacter(after: Double.random(in: 6...14))
            }
        }
    }

    private func scheduleVisitor(after delay: TimeInterval) {
        schedule(delay) { [weak self] in
            guard let self, !self.stopped else { return }
            self.visitors.removeAll { !$0.isPlaying }
            if self.visitors.count < 2,
               let visitor = self.catalog.selectVisitor(
                    scene: self.composition.scene, environment: self.environment.snapshot(),
                    dependencyEnvironment: self.dependencyEnvironment(), scorer: self.scorer
               ) {
                let p = self.player(offset: visitor.ignoresSceneOffset ? .zero : self.composition.scene.sceneOffset)
                p.play(visitor, targetDuration: Double.random(in: 7...14)) { [weak p] in p?.stop() }
                self.visitors.append(p)
            }
            self.scheduleVisitor(after: Double.random(in: 16...32))
        }
    }

    private func nextAnimationKind() -> AssetKind {
        let targets: [(AssetKind, Double)] = [(.characterBasePose, 0.5), (.characterAdditionalPose, 0.25), (.characterMoment, 0.25)]
        let total = max(1, animationCounts.values.reduce(0, +))
        let deficits = targets.map { ($0.0, $0.1 - Double(animationCounts[$0.0, default: 0]) / Double(total)) }
        let maxDeficit = deficits.map(\.1).max() ?? 0
        return deficits.filter { abs($0.1 - maxDeficit) < 0.000_001 }.randomElement()?.0 ?? .characterBasePose
    }
    private func dependencyEnvironment() -> [RelevancyClause] {
        composition.fullscreenEffect.map {
            [RelevancyClause(category: "sceneFullscreenEffectVisitor", facts: $0.relevancy.info)]
        } ?? []
    }
    private func player(offset: CGPoint) -> SpriteAssetPlayer {
        SpriteAssetPlayer(host: container, sceneOffset: offset) { [weak self] in self?.container.bounds ?? .zero }
    }
    private func finish() { guard !stopped else { return }; stopped = true; onFinished?() }
    private func schedule(_ delay: TimeInterval, _ block: @escaping () -> Void) {
        let item = DispatchWorkItem(block: block); tasks.append(item)
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.01, delay), execute: item)
    }
}
