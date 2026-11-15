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
    private var transitionPoseVisible = false
    private var previousCharacter: SpriteAssetPlayer?
    private var basePoseReady = false
    private var visitor: SpriteAssetPlayer?
    private var weather: SpriteAssetPlayer?
    private var weatherEnds: CFTimeInterval?
    private var weatherReady = false
    private var sceneEnds: CFTimeInterval?
    private var eventEnds: CFTimeInterval?
    private var nextCharacterAt: CFTimeInterval = 0
    private var nextVisitorAt: CFTimeInterval = 0
    private var visitorSlots: [Range<CFTimeInterval>] = []
    private var pulse: DispatchWorkItem?
    private(set) var currentPoseID: String
    private var animationCounts: [AssetKind: Int] = [.characterBasePose: 1]
    private var prepared = false
    var debugHasHalftone: Bool {
        halftone.superlayer === container && halftone.mask === halftoneMask && halftoneMask.contents != nil
    }
    var debugActivity: Int {
        let character = eventEnds != nil && !basePoseReady ? 1 : 0
        let visitor = visitor == nil ? 0 : 2
        let transition = transitionCharacter == nil ? 0 : 4
        return character | visitor | transition
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
        let scene = player(offset: composition.scene.sceneOffset)
        scene.play(composition.scene); permanent.append(scene)
        startBasePose(replacing: nil)
    }

    func start(firstScene: Bool) {
        prepare()
        guard sceneEnds == nil else { return }
        let now = CACurrentMediaTime()
        sceneEnds = now + targetDuration
        nextCharacterAt = now + Double.random(in: 6...9)
        nextVisitorAt = now
        // Local pacing policy. tvOS has distinct first-scene visitor pools,
        // scheduling blocks and edge buffers; their exact values are unknown.
        let count = firstScene ? (targetDuration >= 34 ? 1 : 0)
            : (targetDuration >= 48 ? 2 : targetDuration >= 24 ? 1 : 0)
        if count > 0 {
            let block = (targetDuration - 14) / Double(count)
            visitorSlots = (0..<count).map { index in
                let start = now + 8 + Double(index) * block
                return (start + Double.random(in: 0...2))..<(start + block)
            }
        }
        startWeather(now: now)
        schedulePulse()
    }

    func tick() {
        permanent.forEach { $0.tick() }
        character?.tick(); previousCharacter?.tick(); transitionCharacter?.tick()
        visitor?.tick(); weather?.tick()
    }

    func playTransitionPose(_ pose: AssetRecord?) {
        guard let pose else { return }
        let action = player(offset: composition.scene.sceneOffset)
        transitionCharacter?.stop()
        transitionPoseVisible = false
        transitionCharacter = action
        action.onReady = { [weak self, weak action] in
            guard let self, let action, self.transitionCharacter === action else { return }
            self.transitionPoseVisible = true
            self.character?.setHidden(true)
            self.previousCharacter?.setHidden(true)
        }
        action.play(pose)
    }

    func clearTransitionPose() {
        transitionCharacter?.stop()
        transitionCharacter = nil
        transitionPoseVisible = false
        character?.setHidden(false)
        previousCharacter?.setHidden(false)
    }

    func resize(_ frame: CGRect) {
        container.frame = frame; background.frame = container.bounds; halftone.frame = container.bounds; halftoneMask.frame = container.bounds
        permanent.forEach { $0.resize() }
        character?.resize(); previousCharacter?.resize(); transitionCharacter?.resize()
        visitor?.resize(); weather?.resize()
    }
    func stop() {
        stopScheduling()
        clearTransitionPose()
        permanent.forEach { $0.stop() }; character?.stop(); previousCharacter?.stop()
        weather?.stop()
        permanent.removeAll(); character = nil; previousCharacter = nil
        weather = nil; weatherEnds = nil
        prepared = false
    }

    func stopScheduling() {
        pulse?.cancel(); pulse = nil
        sceneEnds = nil; eventEnds = nil
        visitorSlots.removeAll()
        visitor?.stop(); visitor = nil
    }

    private func startBasePose(replacing old: SpriteAssetPlayer?) {
        let base = catalog.assets(.characterBasePose).first { $0.identifier == currentPoseID }
            ?? composition.basePose
        let next = player(offset: composition.scene.sceneOffset)
        // Overlay sprites cut only after the incoming first frame is ready.
        // The official Idle composition does not dissolve these layers.
        basePoseReady = false
        previousCharacter = old
        character = next
        next.onReady = { [weak self, weak next] in
            guard let self, let next, self.character === next else { return }
            self.previousCharacter?.stop()
            self.previousCharacter = nil
            next.setHidden(self.transitionPoseVisible)
            self.basePoseReady = true
        }
        next.play(base, repeatWhole: true)
    }

    private func startWeather(now: CFTimeInterval) {
        guard let effect = composition.fullscreenEffect,
              let duration = SpriteAssetPlayer.playbackDuration(for: effect, target: 12, available: targetDuration - 2)
        else { return }
        let p = player(offset: effect.ignoresSceneOffset ? .zero : composition.scene.sceneOffset)
        weather = p
        weatherEnds = now + duration + 2
        p.onReady = { [weak self] in
            self?.weatherReady = true
            self?.weatherEnds = CACurrentMediaTime() + duration
        }
        p.play(effect, targetDuration: duration) { [weak self, weak p] in
            guard let self, let p, self.weather === p else { return }
            self.endWeather()
        }
    }

    private func endWeather() {
        weather?.stop(); weather = nil; weatherEnds = nil; weatherReady = false
    }

    private func schedulePulse() {
        let task = DispatchWorkItem { [weak self] in
            guard let self, self.sceneEnds != nil else { return }
            self.advance(at: CACurrentMediaTime())
            if self.sceneEnds != nil { self.schedulePulse() }
        }
        pulse = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: task)
    }

    private func advance(at now: CFTimeInterval) {
        guard let deadline = sceneEnds else { return }
        if let weatherEnds, now >= weatherEnds + 0.5 { endWeather() }
        if let eventEnds, now >= eventEnds {
            if visitor != nil { endVisitor() }
            else if let character { endCharacter(character, endingPose: nil) }
        }
        if now >= deadline {
            stopScheduling()
            onFinished?()
            return
        }
        guard transitionCharacter == nil, basePoseReady, eventEnds == nil else { return }
        visitorSlots.removeAll { $0.upperBound <= now }
        let slot = visitorSlots.first
        let available = deadline - now - 3
        if let slot, slot.contains(now), now >= nextVisitorAt, weather == nil {
            visitorSlots.removeFirst()
            beginVisitor(at: now, available: min(available, slot.upperBound - now))
            return
        }
        guard now >= nextCharacterAt, weather == nil || weatherReady else { return }
        // Leave room for planned visitors. If a weather cue is playing, only
        // a character animation explicitly paired with it may share the stage.
        let beforeVisitor = weather == nil ? (slot.map { $0.lowerBound - now - 3 } ?? available) : available
        beginCharacter(at: now, available: min(available, beforeVisitor))
    }

    private func beginCharacter(at now: CFTimeInterval, available: TimeInterval) {
        guard available >= 1 else { return }
        let snapshot = environment.snapshot()
        let effect = weather.flatMap { _ in composition.fullscreenEffect }
        let dependency = effect.map {
            [RelevancyClause(category: "sceneFullscreenEffectVisitor", facts: $0.relevancy.info)]
        } ?? []
        let kind = nextAnimationKind()
        var scheduledKind = kind
        var animation: AssetRecord?
        if kind != .characterBasePose || effect != nil {
            let specialKind = kind == .characterBasePose ? .characterAdditionalPose : kind
            animation = catalog.selectCharacterAnimation(
                from: currentPoseID, kind: specialKind, scene: composition.scene,
                environment: snapshot, dependencyEnvironment: dependency, scorer: scorer,
                eligible: { asset in dependency.isEmpty || asset.relevancy.dependencies.contains {
                    clause in dependency.contains { $0.category == clause.category && $0.facts.intersects(clause.facts) }
                } }
            )
            scheduledKind = specialKind
        }
        let compatibleWindow = weatherEnds.map { min(available, $0 - now - 2) } ?? available
        let target = Double.random(in: 6...10)
        var duration = animation.flatMap {
            SpriteAssetPlayer.playbackDuration(for: $0, target: target, available: compatibleWindow)
        }
        if duration == nil, effect == nil {
            animation = catalog.selectPoseTransition(from: currentPoseID)
            duration = animation.flatMap {
                SpriteAssetPlayer.playbackDuration(for: $0, target: target, available: available)
            }
            scheduledKind = .characterBasePose
        }
        guard let animation, let duration else { nextCharacterAt = now + 2; return }

        let next = player(offset: composition.scene.sceneOffset)
        previousCharacter = character
        character = next
        basePoseReady = false
        eventEnds = now + duration + 2
        let actionKind = scheduledKind
        next.onReady = { [weak self, weak next] in
            guard let self, let next, self.character === next else { return }
            self.previousCharacter?.stop()
            self.previousCharacter = nil
            self.animationCounts[actionKind, default: 0] += 1
            if actionKind != .characterBasePose {
                self.scorer.mark(animation, kind: actionKind.rawValue, at: Date())
                self.specialAnimationCount += 1
            }
        }
        next.play(animation, targetDuration: duration) { [weak self, weak next] in
            guard let self, let next, self.character === next, self.sceneEnds != nil else { return }
            self.endCharacter(next, endingPose: animation.endPoseID)
        }
    }

    private func endCharacter(_ action: SpriteAssetPlayer, endingPose: String?) {
        eventEnds = nil
        nextCharacterAt = CACurrentMediaTime() + Double.random(in: 6...12)
        if let previousCharacter {
            // No first frame was displayed. Keep the original pose.
            action.stop()
            character = previousCharacter
            self.previousCharacter = nil
            basePoseReady = true
        } else {
            currentPoseID = endingPose ?? currentPoseID
            startBasePose(replacing: action)
        }
    }

    private func beginVisitor(at now: CFTimeInterval, available: TimeInterval) {
        guard let asset = catalog.selectVisitor(
            scene: composition.scene, environment: environment.snapshot(), dependencyEnvironment: [], scorer: scorer
        ), let duration = SpriteAssetPlayer.playbackDuration(for: asset, target: Double.random(in: 5...9), available: available)
        else { return }
        let p = player(offset: asset.ignoresSceneOffset ? .zero : composition.scene.sceneOffset)
        visitor = p
        eventEnds = now + duration + 2
        p.onReady = { [weak self] in
            self?.nextVisitorAt = CACurrentMediaTime() + 12
            self?.scorer.mark(asset, kind: "visitor", at: Date())
        }
        p.play(asset, targetDuration: duration) { [weak self, weak p] in
            guard let self, let p, self.visitor === p else { return }
            self.endVisitor()
        }
    }

    private func endVisitor() {
        visitor?.stop(); visitor = nil
        eventEnds = nil
        nextCharacterAt = max(nextCharacterAt, CACurrentMediaTime() + 1)
    }

    private func nextAnimationKind() -> AssetKind {
        let targets: [(AssetKind, Double)] = [(.characterBasePose, 0.5), (.characterAdditionalPose, 0.25), (.characterMoment, 0.25)]
        let total = max(1, animationCounts.values.reduce(0, +))
        let deficits = targets.map { ($0.0, $0.1 - Double(animationCounts[$0.0, default: 0]) / Double(total)) }
        let maxDeficit = deficits.map(\.1).max() ?? 0
        return deficits.filter { abs($0.1 - maxDeficit) < 0.000_001 }.randomElement()?.0 ?? .characterBasePose
    }
    private func player(offset: CGPoint) -> SpriteAssetPlayer {
        SpriteAssetPlayer(host: container, sceneOffset: offset) { [weak self] in self?.container.bounds ?? .zero }
    }
}
