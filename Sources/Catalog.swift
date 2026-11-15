import AppKit
import Foundation

final class RelevancyEngine {
    private var history: [String: [Date]] = [:]
    private var groupHistory: [String: Date] = [:]
    private var previousByKind: [String: String] = [:]

    func score(
        _ asset: AssetRecord,
        kind: String,
        environment: EnvironmentSnapshot,
        dependencyEnvironment: [RelevancyClause] = []
    ) -> Double? {
        let info = asset.relevancy.info
        var value = 0.0
        if !info.events.isEmpty {
            let match = info.events.intersection(environment.facts.events)
            guard !match.isEmpty else { return nil }
            value += match.isDisjoint(with: EventCalendar.specialEvents(on: environment.date)) ? 1 : 4
        }
        if !info.timeBands.isEmpty {
            guard !info.timeBands.isDisjoint(with: environment.facts.timeBands) else { return nil }
            value += 1
        }
        if !info.routines.isEmpty {
            guard !info.routines.isDisjoint(with: environment.facts.routines) else { return nil }
            value += 1
        }
        if !info.weather.isEmpty {
            let match = info.weather.intersection(environment.facts.weather)
            guard !match.isEmpty else { return nil }
            value += environment.previousWeather.map { match.contains($0) ? 1 : 2 } ?? 1
        }
        if !info.hourlyEvents.isEmpty {
            guard !info.hourlyEvents.isDisjoint(with: environment.facts.hourlyEvents) else { return nil }
            value += 1
        }
        if !asset.relevancy.dependencies.isEmpty {
            let fulfilled = asset.relevancy.dependencies.contains { requirement in
                dependencyEnvironment.contains {
                    $0.category == requirement.category && $0.facts.intersects(requirement.facts)
                }
            }
            guard fulfilled else { return nil }
            value += 1
        }
        for exclusion in asset.relevancy.exclusions {
            if dependencyEnvironment.contains(where: {
                $0.category == exclusion.category && $0.facts.intersects(exclusion.facts)
            }) { return nil }
        }
        // Recency is a score decay, not a hard exclusion. A hard exclusion can
        // remove the only palette matching the current time/weather and leave
        // a later IdleScene without its overlay layer.
        if previousByKind[kind] == asset.identifier { value -= 1 }
        for key in info.groupKeys {
            if let seen = groupHistory["\(kind)|\(key)"],
               environment.date.timeIntervalSince(seen) >= 0,
               environment.date.timeIntervalSince(seen) < 15 * 60 {
                let age = environment.date.timeIntervalSince(seen)
                value -= 0.5 * (1 - age / (15 * 60))
            }
        }
        let timestamps = history[asset.identifier] ?? []
        if let last = timestamps.max() {
            let age = environment.date.timeIntervalSince(last)
            if age >= 0 && age < 15 * 60 { value -= 0.25 * (1 - age / (15 * 60)) }
        }
        let frequency = timestamps.filter {
            environment.date.timeIntervalSince($0) >= 0 && environment.date.timeIntervalSince($0) < 60 * 60
        }.count
        value -= Double(min(4, frequency)) * 0.25
        return value
    }

    func choose(
        _ assets: [AssetRecord],
        kind: String,
        environment: EnvironmentSnapshot,
        dependencyEnvironment: [RelevancyClause] = []
    ) -> AssetRecord? {
        let scored = assets.compactMap { asset in
            score(asset, kind: kind, environment: environment, dependencyEnvironment: dependencyEnvironment)
                .map { (asset, $0) }
        }
        if let maximum = scored.map(\.1).max() {
            return scored.filter { abs($0.1 - maximum) < 0.000_001 }.randomElement()?.0
        }
        return assets.filter { $0.relevancy.info.isEmpty }.randomElement()
    }

    func mark(_ asset: AssetRecord, kind: String, at date: Date) {
        history[asset.identifier, default: []].append(date)
        previousByKind[kind] = asset.identifier
        for key in asset.relevancy.info.groupKeys { groupHistory["\(kind)|\(key)"] = date }
        let cutoff = date.addingTimeInterval(-24 * 60 * 60)
        history = history.compactMapValues {
            let kept = $0.filter { $0 >= cutoff }
            return kept.isEmpty ? nil : kept
        }
    }
}

final class AssetCatalog {
    private(set) var records: [AssetRecord] = []
    private var byKind: [AssetKind: [AssetRecord]] = [:]
    private var byID: [String: AssetRecord] = [:]

    convenience init(bundle: Bundle) throws {
        guard let resources = bundle.resourceURL else { throw CatalogError.missingResources }
        try self.init(resources: resources)
    }

    init(resources: URL) throws {
        let root = resources.appendingPathComponent("Assets", isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else { throw CatalogError.missingAssets }
        let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )
        var preferred: [String: AssetRecord] = [:]
        while let directory = enumerator?.nextObject() as? URL {
            guard directory.pathExtension == "icasset" else { continue }
            enumerator?.skipDescendants()
            guard let record = Self.parse(directory) else { continue }
            if record.kind == .activeScene, record.activeMovieURL == nil { continue }
            let key = "\(record.kind.rawValue)/\(record.identifier)"
            if let old = preferred[key], old.sourcePriority >= record.sourcePriority { continue }
            preferred[key] = record
        }
        records = preferred.values.sorted { ($0.kind.rawValue, $0.identifier) < ($1.kind.rawValue, $1.identifier) }
        byKind = Dictionary(grouping: records, by: \.kind)
        byID = Dictionary(uniqueKeysWithValues: records.map { ("\($0.kind.rawValue)/\($0.identifier)", $0) })
        guard !assets(.idleScene).isEmpty else { throw CatalogError.noScenes }
    }

    func assets(_ kind: AssetKind) -> [AssetRecord] { byKind[kind] ?? [] }

    func selectActive(environment: EnvironmentSnapshot, scorer: RelevancyEngine) -> AssetRecord? {
        let playable = assets(.activeScene).filter { $0.activeMovieURL != nil }
        guard let result = scorer.choose(playable, kind: "activeScene", environment: environment) else { return nil }
        scorer.mark(result, kind: "activeScene", at: environment.date)
        return result
    }

    func makeIdleComposition(environment: EnvironmentSnapshot, scorer: RelevancyEngine) -> IdleComposition? {
        guard let scene = scorer.choose(assets(.idleScene), kind: "idleScene", environment: environment) else { return nil }
        scorer.mark(scene, kind: "idleScene", at: environment.date)
        let effects = assets(.idleSceneVisitor).filter {
            $0.isFullscreenEffect && !scene.excludedVisitors.contains($0.identifier)
        }
        let effect = scorer.choose(effects, kind: "fullscreenEffect", environment: environment)
        if let effect { scorer.mark(effect, kind: "fullscreenEffect", at: environment.date) }
        let dependency: [RelevancyClause] = effect.map {
            [RelevancyClause(category: "sceneFullscreenEffectVisitor", facts: $0.relevancy.info)]
        } ?? []
        let palettes = assets(.scenePalette).filter { !scene.excludedPalettes.contains($0.identifier) }
        let palette = scorer.choose(
            palettes, kind: "scenePalette", environment: environment, dependencyEnvironment: dependency
        )
        if let palette { scorer.mark(palette, kind: "scenePalette", at: environment.date) }
        guard let base = scorer.choose(
            assets(.characterBasePose), kind: "basePose", environment: environment,
            dependencyEnvironment: dependency
        ) else { return nil }
        scorer.mark(base, kind: "basePose", at: environment.date)
        return IdleComposition(scene: scene, palette: palette, basePose: base, fullscreenEffect: effect)
    }

    func selectCharacterAnimation(
        from poseID: String,
        kind: AssetKind,
        scene: AssetRecord,
        environment: EnvironmentSnapshot,
        dependencyEnvironment: [RelevancyClause],
        scorer: RelevancyEngine
    ) -> AssetRecord? {
        let candidates = assets(kind).filter {
            $0.startPoseID == poseID
                && (kind != .characterMoment || !scene.excludedMoments.contains($0.identifier))
                && (kind != .characterAdditionalPose || !scene.excludedAdditionalPoses.contains($0.identifier))
        }
        guard let result = scorer.choose(
            candidates, kind: kind.rawValue, environment: environment,
            dependencyEnvironment: dependencyEnvironment
        ) else { return nil }
        scorer.mark(result, kind: kind.rawValue, at: environment.date)
        return result
    }

    func selectPoseTransition(from poseID: String) -> AssetRecord? {
        assets(.characterPoseTransition).filter { $0.startPoseID == poseID && $0.endPoseID != poseID }.randomElement()
    }

    func selectVisitor(
        scene: AssetRecord,
        environment: EnvironmentSnapshot,
        dependencyEnvironment: [RelevancyClause],
        scorer: RelevancyEngine
    ) -> AssetRecord? {
        let candidates = assets(.idleSceneVisitor).filter {
            !$0.isFullscreenEffect && !scene.excludedVisitors.contains($0.identifier)
        }
        guard let result = scorer.choose(
            candidates, kind: "visitor", environment: environment,
            dependencyEnvironment: dependencyEnvironment
        ) else { return nil }
        scorer.mark(result, kind: "visitor", at: environment.date)
        return result
    }

    func transitionChoice(
        for activeScene: AssetRecord,
        environment: EnvironmentSnapshot,
        scorer: RelevancyEngine,
        avoiding pairID: String?,
        avoidingRevealPose poseID: String?,
        allowIdlePreservation: Bool
    ) -> TransitionChoice? {
        var options: [(pair: AssetRecord, choice: TransitionChoice, score: Double)] = []
        for categoryID in activeScene.transitionCategoryIDs {
            guard let category = byID["sceneTransitionCategory/\(categoryID)"],
                  allowIdlePreservation || !category.preventsIdleSceneChange else { continue }
            let hidePose = transitionPoses(category.hideCharacterPoseIDs, phase: "hide").randomElement()
            let revealPoses = transitionPoses(category.revealCharacterPoseIDs, phase: "reveal")
            let revealPose = revealPoses.filter { $0.identifier != poseID }.randomElement()
                ?? revealPoses.randomElement()
            for transitionID in category.transitionPairIDs {
                guard let pair = byID["sceneTransitionPair/\(transitionID)"],
                      let hide = transitionSequence(pair.hideTransitionID),
                      let reveal = transitionSequence(pair.revealTransitionID),
                      let score = scorer.score(pair, kind: "sceneTransitionPair", environment: environment)
                else { continue }
                let choice = TransitionChoice(
                    pairID: pair.identifier, style: Self.transitionStyle(pair.identifier),
                    preventsIdleSceneChange: category.preventsIdleSceneChange,
                    hide: hide, reveal: reveal, hidePose: hidePose, revealPose: revealPose
                )
                options.append((pair, choice, score))
            }
        }
        let freshPoses = options.filter { $0.choice.revealPose?.identifier != poseID }
        if poseID != nil, !freshPoses.isEmpty { options = freshPoses }
        let freshPairs = options.filter { $0.pair.identifier != pairID }
        if !freshPairs.isEmpty { options = freshPairs }
        guard let maximum = options.map(\.score).max(),
              let selected = options.filter({ abs($0.score - maximum) < 0.000_001 }).randomElement()
        else { return nil }
        scorer.mark(selected.pair, kind: "sceneTransitionPair", at: environment.date)
        return selected.choice
    }

    private func transitionSequence(_ id: String?) -> TransitionSequence? {
        guard let id, let record = byID["spriteTransitionParameters/\(id)"] else { return nil }
        return TransitionSequence(record.sprites)
    }

    private func transitionPoses(_ ids: [String], phase: String) -> [AssetRecord] {
        ids.compactMap { byID["characterSceneTransitionPose/\($0)"] }
            .filter { $0.transitionPhase == phase && $0.activeMovieURL != nil }
    }

    private static func transitionStyle(_ id: String) -> OfficialTransitionStyle {
        if id.contains("HorizontalWipe") { return .horizontalWipe }
        if id.contains("ClockWipe") { return .clockWipe }
        if id.contains("CircularWipe") { return .circularWipe }
        if id.contains("SleepingDreamBubble") { return .sleepingDreamBubble }
        if id.contains("ThoughtBubble") { return .thoughtBubble }
        return .dissolve
    }

    private static func parse(_ directory: URL) -> AssetRecord? {
        let metadataURL = directory.appendingPathComponent("metadata.icmetadata")
        guard let data = try? Data(contentsOf: metadataURL),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        let supported: [(String, AssetKind)] = [
            ("activeScene", .activeScene), ("idleScene", .idleScene),
            ("idleSceneVisitor", .idleSceneVisitor), ("characterBasePose", .characterBasePose),
            ("characterAdditionalPose", .characterAdditionalPose), ("characterMoment", .characterMoment),
            ("characterPoseTransition", .characterPoseTransition),
            ("sceneTransitionCategory", .sceneTransitionCategory),
            ("sceneTransitionPair", .sceneTransitionPair), ("scenePalette", .scenePalette),
            ("spriteTransitionParameters", .spriteTransitionParameters),
            ("characterSceneTransitionPose", .characterSceneTransitionPose),
            ("switcherScene", .switcherScene),
        ]
        guard let match = supported.first(where: { root[$0.0] != nil }),
              let outer = root[match.0] as? [String: Any],
              let payload = outer["_0"] as? [String: Any] else { return nil }
        let content = ((payload["assetContainer"] as? [String: Any])?["content"] as? [String: Any]) ?? [:]
        let path = directory.path
        let priority = path.contains("/Optional/") ? 3 : (path.contains("DefaultAssetBundleV2") ? 2 : 1)
        let exclusions = payload["exclusions"] as? [String: Any] ?? [:]
        let offset = payload["sceneOffset"] as? [String: Any] ?? [:]
        func parametersID(_ field: String) -> String? {
            let style = payload[field] as? [String: Any]
            return (style?["sprite"] as? [String: Any])?["parametersID"] as? String
        }
        let palette: Palette?
        if let background = color(payload["backgroundColor"]) {
            palette = Palette(background: background, overlay: color(payload["overlayColor"]))
        } else { palette = nil }
        return AssetRecord(
            identifier: directory.deletingPathExtension().lastPathComponent,
            kind: match.1, directoryURL: directory, sourcePriority: priority,
            sprites: parseSprites(content, directory: directory),
            relevancy: parseRelevancy(payload["relevancyData"]),
            startPoseID: payload["startCharacterBasePoseID"] as? String,
            endPoseID: payload["endCharacterBasePoseID"] as? String,
            transitionCategoryIDs: Set(payload["transitionCategoryIDs"] as? [String] ?? []),
            transitionPairIDs: Set(payload["sceneTransitionPairIDs"] as? [String] ?? []),
            hideTransitionID: parametersID("hideStyle"),
            revealTransitionID: parametersID("revealStyle"),
            hideCharacterPoseIDs: payload["hideCharacterPoseIDs"] as? [String] ?? [],
            revealCharacterPoseIDs: payload["revealCharacterPoseIDs"] as? [String] ?? [],
            transitionPhase: payload["transitionPhase"] as? String,
            preventsIdleSceneChange: payload["preventsIdleSceneChange"] as? Bool ?? false,
            sceneOffset: CGPoint(x: number(offset["x"]), y: number(offset["y"])),
            ignoresSceneOffset: payload["ignoresSceneOffset"] as? Bool ?? false,
            isFullscreenEffect: payload["isFullscreenEffect"] as? Bool ?? false,
            excludedAdditionalPoses: Set(exclusions["excludedCharacterAdditionalPoses"] as? [String] ?? []),
            excludedMoments: Set(exclusions["excludedCharacterMoments"] as? [String] ?? []),
            excludedPalettes: Set(exclusions["excludedPalettes"] as? [String] ?? []),
            excludedVisitors: Set(exclusions["excludedVisitors"] as? [String] ?? []),
            palette: palette
        )
    }

    private static func parseSprites(_ content: [String: Any], directory: URL) -> [SpriteDescriptor] {
        var result: [SpriteDescriptor] = []
        func append(_ value: Any?, phase: SpritePhase) {
            guard let sprites = (value as? [String: Any])?["sprites"] as? [[String: Any]] else { return }
            for sprite in sprites {
                guard let atlas = sprite["atlas"] as? [String: Any],
                      let base = atlas["assetBaseName"] as? String,
                      let rawType = sprite["spriteType"] as? String,
                      let type = SpriteMediaType(rawValue: rawType) else { continue }
                let timing = sprite["customTiming"] as? [String: Any] ?? [:]
                let size = atlas["assetSize"] as? [NSNumber] ?? []
                let placement = (sprite["placement"] as? [String: Any])?["anchored"] as? [String: Any]
                result.append(SpriteDescriptor(
                    baseName: base, directoryURL: directory, mediaType: type, phase: phase,
                    assetSize: CGSize(width: size.first?.doubleValue ?? 1920, height: size.dropFirst().first?.doubleValue ?? 1080),
                    alignment: placement?["alignment"] as? String ?? "center",
                    plane: sprite["plane"] as? String ?? "centerpiece",
                    loops: sprite["endBehavior"] as? String == "loop",
                    startFrame: Int(number(timing["start"])), endFrame: Int(number(timing["end"])),
                    digitCount: (atlas["frameIndexDigitCount"] as? NSNumber)?.intValue ?? 2
                ))
            }
        }
        if let one = (content["oneShotSprites"] as? [String: Any])?["oneShotSprites"] { append(one, phase: .oneShot) }
        if let phased = (content["phasedSprites"] as? [String: Any])?["phasedSprites"] as? [String: Any] {
            append(phased["introSprites"], phase: .intro)
            append(phased["loopSprites"], phase: .loop)
            append(phased["outroSprites"], phase: .outro)
        }
        return result
    }

    private static func parseRelevancy(_ value: Any?) -> RelevancyRecord {
        guard let dictionary = value as? [String: Any] else { return RelevancyRecord() }
        func facts(_ value: Any?) -> RelevancyFacts {
            var result = RelevancyFacts()
            func walk(_ value: Any?) {
                if let dictionary = value as? [String: Any] {
                    for (key, nested) in dictionary {
                        if let string = nested as? String {
                            switch key {
                            case "event": result.events.insert(string)
                            case "timeOfDay": result.timeBands.insert(string)
                            case "routine": result.routines.insert(string)
                            case "condition": result.weather.insert(string)
                            case "reactionTrigger": result.reactionTriggers.insert(string)
                            default: break
                            }
                        }
                        if key == "hourlyEvent", let event = (nested as? [String: Any])?.keys.first {
                            result.hourlyEvents.insert(event)
                        }
                        walk(nested)
                    }
                } else if let array = value as? [Any] { array.forEach(walk) }
            }
            walk(value); return result
        }
        func clauses(_ value: Any?) -> [RelevancyClause] {
            (value as? [[String: Any]] ?? []).map {
                RelevancyClause(category: $0["category"] as? String ?? "unknown", facts: facts($0["info"]))
            }
        }
        return RelevancyRecord(
            info: facts(dictionary["info"]), dependencies: clauses(dictionary["dependencies"]),
            exclusions: clauses(dictionary["exclusions"])
        )
    }

    private static func color(_ value: Any?) -> NSColor? {
        guard let d = value as? [String: Any] else { return nil }
        return NSColor(calibratedRed: number(d["red"]) / 255, green: number(d["green"]) / 255,
                       blue: number(d["blue"]) / 255, alpha: number(d["alpha"]))
    }
    private static func number(_ value: Any?) -> CGFloat { CGFloat((value as? NSNumber)?.doubleValue ?? 0) }
}

enum CatalogError: Error { case missingResources, missingAssets, noScenes }
