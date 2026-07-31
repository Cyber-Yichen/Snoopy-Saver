import AppKit
import Foundation

final class RelevancyEngine {
    private struct StoredHistory: Codable {
        var history: [String: [Date]]
        var groupHistory: [String: Date]
        var previousByKind: [String: String]
    }

    private var history: [String: [Date]] = [:]
    private var groupHistory: [String: Date] = [:]
    private var previousByKind: [String: String] = [:]
    private let persistenceKey: String?

    init(persistenceKey: String? = "SnoopyRelevancyHistory.v2") {
        self.persistenceKey = persistenceKey
        guard let persistenceKey,
              let data = UserDefaults.standard.data(forKey: persistenceKey),
              let stored = try? JSONDecoder().decode(StoredHistory.self, from: data)
        else { return }
        history = stored.history
        groupHistory = stored.groupHistory
        previousByKind = stored.previousByKind
    }

    func score(
        _ asset: AssetRecord,
        kind: String,
        environment: EnvironmentSnapshot,
        dependencyEnvironment: [RelevancyClause] = []
    ) -> Double? {
        let info = asset.relevancy.info
        var value = 0.0
        var hasExactDateMatch = false
        if !info.events.isEmpty {
            let match = info.events.intersection(environment.facts.events)
            guard !match.isEmpty else { return nil }
            let exact = match.intersection(EventCalendar.dateSpecificEventNames)
            hasExactDateMatch = !exact.isEmpty
            if hasExactDateMatch {
                value = 4
            } else {
                value += 1
                value += Double(max(0, match.count - 1)) * 0.25
            }
        }
        if !info.timeBands.isEmpty {
            guard !info.timeBands.isDisjoint(with: environment.facts.timeBands) else { return nil }
            if !hasExactDateMatch { value += 1 }
        }
        if !info.routines.isEmpty {
            guard !info.routines.isDisjoint(with: environment.facts.routines) else { return nil }
            if !hasExactDateMatch { value += 1 }
        }
        if !info.weather.isEmpty {
            let match = info.weather.intersection(environment.facts.weather)
            guard !match.isEmpty else { return nil }
            if !hasExactDateMatch {
                value += environment.previousWeather.map {
                    match.contains($0) ? 1 : 1.25
                } ?? 1
            }
        }
        if !info.hourlyEvents.isEmpty {
            guard !info.hourlyEvents.isDisjoint(with: environment.facts.hourlyEvents) else { return nil }
            if !hasExactDateMatch { value += 2 }
        }
        if !info.reactionTriggers.isEmpty {
            guard !info.reactionTriggers.isDisjoint(with: environment.facts.reactionTriggers) else { return nil }
            if !hasExactDateMatch { value += 2 }
        }
        if !asset.relevancy.dependencies.isEmpty {
            let fulfilled = asset.relevancy.dependencies.contains { requirement in
                dependencyEnvironment.contains {
                    $0.category == requirement.category && $0.facts.intersects(requirement.facts)
                }
            }
            guard fulfilled else { return nil }
            if !hasExactDateMatch { value += 1 }
        }
        for exclusion in asset.relevancy.exclusions {
            if dependencyEnvironment.contains(where: {
                $0.category == exclusion.category && $0.facts.intersects(exclusion.facts)
            }) { return nil }
        }
        // Recency is a score decay, not a hard exclusion. A hard exclusion can
        // remove the only palette matching the current time/weather and leave
        // a later IdleScene without its overlay layer.
        if previousByKind[kind] == asset.identifier { value -= 1_000 }
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
        let withoutImmediateRepeat: [(AssetRecord, Double)]
        if scored.count > 1, let previous = previousByKind[kind] {
            let filtered = scored.filter { $0.0.identifier != previous }
            withoutImmediateRepeat = filtered.isEmpty ? scored : filtered
        } else { withoutImmediateRepeat = scored }
        if let maximum = withoutImmediateRepeat.map(\.1).max() {
            return withoutImmediateRepeat.filter { abs($0.1 - maximum) < 0.000_001 }.randomElement()?.0
        }
        let generic = assets.filter { $0.relevancy.info.isEmpty }
        if generic.count > 1, let previous = previousByKind[kind] {
            return generic.filter { $0.identifier != previous }.randomElement() ?? generic.randomElement()
        }
        return generic.randomElement()
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
        persist()
    }

    private func persist() {
        guard let persistenceKey,
              let data = try? JSONEncoder().encode(StoredHistory(
                history: history, groupHistory: groupHistory, previousByKind: previousByKind
              )) else { return }
        UserDefaults.standard.set(data, forKey: persistenceKey)
    }
}

final class AssetCatalog {
    private(set) var records: [AssetRecord] = []
    private var byKind: [AssetKind: [AssetRecord]] = [:]
    private var byID: [String: AssetRecord] = [:]
    private var consecutiveTransitionsPreventingIdleSceneChange = 0
    private let maximumConsecutiveTransitionsPreventingIdleSceneChange = 2

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
        var candidates: [String: [AssetRecord]] = [:]
        while let directory = enumerator?.nextObject() as? URL {
            guard directory.pathExtension == "icasset" else { continue }
            enumerator?.skipDescendants()
            guard let record = Self.parse(directory) else { continue }
            let key = "\(record.kind.rawValue)/\(record.identifier)"
            candidates[key, default: []].append(record)
        }
        let packageWindows = Self.loadPackageWindows(resources: resources)
        let availabilityReferences = Self.loadAvailabilityReferences(root: root)
        records = candidates.values.compactMap { group -> AssetRecord? in
            guard var preferred = group.max(by: {
                ($0.sourcePriority, $0.directoryURL.path) < ($1.sourcePriority, $1.directoryURL.path)
            }) else { return nil }
            preferred.availability = Self.availability(
                for: preferred.identifier,
                candidates: group,
                packageWindows: packageWindows,
                availabilityReferences: availabilityReferences
            )
            return preferred
        }.sorted { ($0.kind.rawValue, $0.identifier) < ($1.kind.rawValue, $1.identifier) }
        byKind = Dictionary(grouping: records, by: \.kind)
        byID = Dictionary(uniqueKeysWithValues: records.map { ("\($0.kind.rawValue)/\($0.identifier)", $0) })
        guard !playableAssets(.activeScene).isEmpty, !playableAssets(.idleScene).isEmpty else {
            throw CatalogError.noScenes
        }
    }

    func assets(_ kind: AssetKind) -> [AssetRecord] { byKind[kind] ?? [] }
    func assets(_ kind: AssetKind, availableOn date: Date) -> [AssetRecord] {
        assets(kind).filter { $0.availability.contains(date) }
    }

    private func playableAssets(_ kind: AssetKind, availableOn date: Date? = nil) -> [AssetRecord] {
        let candidates = date.map { assets(kind, availableOn: $0) } ?? assets(kind)
        return candidates.filter(\.hasPlayableMedia)
    }

    func selectActive(
        environment: EnvironmentSnapshot,
        scorer: RelevancyEngine,
        markSelection: Bool = true
    ) -> AssetRecord? {
        guard let result = scorer.choose(
            playableAssets(.activeScene, availableOn: environment.date),
            kind: "activeScene", environment: environment
        ) else { return nil }
        if markSelection { scorer.mark(result, kind: "activeScene", at: environment.date) }
        return result
    }

    func makeIdleComposition(environment: EnvironmentSnapshot, scorer: RelevancyEngine) -> IdleComposition? {
        guard let scene = scorer.choose(
            playableAssets(.idleScene, availableOn: environment.date),
            kind: "idleScene", environment: environment
        ) else { return nil }
        scorer.mark(scene, kind: "idleScene", at: environment.date)
        let effects = playableAssets(.idleSceneVisitor, availableOn: environment.date).filter {
            $0.isFullscreenEffect && !scene.excludedVisitors.contains($0.identifier)
        }
        let effect = scorer.choose(effects, kind: "fullscreenEffect", environment: environment)
        if let effect { scorer.mark(effect, kind: "fullscreenEffect", at: environment.date) }
        let dependency: [RelevancyClause] = effect.map {
            [RelevancyClause(category: "sceneFullscreenEffectVisitor", facts: $0.relevancy.info)]
        } ?? []
        let palettes = playableAssets(.scenePalette, availableOn: environment.date).filter {
            !scene.excludedPalettes.contains($0.identifier)
        }
        let palette = scorer.choose(
            palettes, kind: "scenePalette", environment: environment, dependencyEnvironment: dependency
        )
        if let palette { scorer.mark(palette, kind: "scenePalette", at: environment.date) }
        guard let base = scorer.choose(
            playableAssets(.characterBasePose, availableOn: environment.date),
            kind: "basePose", environment: environment,
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
        let candidates = playableAssets(kind, availableOn: environment.date).filter {
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
        playableAssets(.characterPoseTransition).filter {
            $0.startPoseID == poseID && $0.endPoseID != poseID
        }.randomElement()
    }

    func selectVisitor(
        scene: AssetRecord,
        environment: EnvironmentSnapshot,
        dependencyEnvironment: [RelevancyClause],
        scorer: RelevancyEngine
    ) -> AssetRecord? {
        let candidates = playableAssets(.idleSceneVisitor, availableOn: environment.date).filter {
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
        avoidingRevealPoseID: String? = nil
    ) -> TransitionChoice {
        var categories = activeScene.transitionCategoryIDs.compactMap {
            byID["sceneTransitionCategory/\($0)"]
        }
        if consecutiveTransitionsPreventingIdleSceneChange
            >= maximumConsecutiveTransitionsPreventingIdleSceneChange {
            let changing = categories.filter { !$0.preventsIdleSceneChange }
            if !changing.isEmpty { categories = changing }
        }

        var options: [(category: AssetRecord, pair: AssetRecord, score: Double)] = []
        for category in categories {
            for transitionID in category.transitionPairIDs {
                guard let pair = byID["sceneTransitionPair/\(transitionID)"],
                      let score = scorer.score(pair, kind: "sceneTransitionPair", environment: environment)
                else { continue }
                options.append((category, pair, score))
            }
        }
        if options.count > 1, let pairID {
            let withoutRepeat = options.filter { $0.pair.identifier != pairID }
            if !withoutRepeat.isEmpty { options = withoutRepeat }
        }
        if let maximum = options.map(\.score).max(),
           let selected = options.filter({ abs($0.score - maximum) < 0.000_001 }).randomElement() {
            let hidePose = transitionPose(
                ids: selected.category.hideCharacterPoseIDs, avoiding: nil
            )
            let revealPose = transitionPose(
                ids: selected.category.revealCharacterPoseIDs, avoiding: avoidingRevealPoseID
            )
            return TransitionChoice(
                categoryID: selected.category.identifier,
                pairID: selected.pair.identifier,
                style: Self.transitionStyle(selected.pair.identifier),
                preventsIdleSceneChange: selected.category.preventsIdleSceneChange,
                hideCharacterPose: hidePose,
                revealCharacterPose: revealPose,
                hideParameters: selected.pair.hideTransitionParametersID.flatMap {
                    byID["spriteTransitionParameters/\($0)"]
                }.flatMap { $0.hasPlayableMedia ? $0 : nil },
                revealParameters: selected.pair.revealTransitionParametersID.flatMap {
                    byID["spriteTransitionParameters/\($0)"]
                }.flatMap { $0.hasPlayableMedia ? $0 : nil }
            )
        }
        consecutiveTransitionsPreventingIdleSceneChange = 0
        return TransitionChoice(
            categoryID: "fallback", pairID: "fallback-dissolve", style: .dissolve,
            preventsIdleSceneChange: false, hideCharacterPose: nil, revealCharacterPose: nil,
            hideParameters: nil, revealParameters: nil
        )
    }

    func markTransitionChoice(
        _ choice: TransitionChoice,
        environment: EnvironmentSnapshot,
        scorer: RelevancyEngine
    ) {
        if let pair = byID["sceneTransitionPair/\(choice.pairID)"] {
            scorer.mark(pair, kind: "sceneTransitionPair", at: environment.date)
        }
        if choice.preventsIdleSceneChange {
            consecutiveTransitionsPreventingIdleSceneChange += 1
        } else {
            consecutiveTransitionsPreventingIdleSceneChange = 0
        }
    }

    private func transitionPose(ids: [String], avoiding identifier: String?) -> AssetRecord? {
        let poses = ids.compactMap {
            byID["characterSceneTransitionPose/\($0)"]
        }.filter(\.hasPlayableMedia)
        if poses.count > 1, let identifier {
            return poses.filter { $0.identifier != identifier }.randomElement() ?? poses.randomElement()
        }
        return poses.randomElement()
    }

    private static func loadPackageWindows(resources: URL) -> [String: AssetAvailability] {
        let url = resources.appendingPathComponent("optional-assets.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let packages = root["assets"] as? [[String: Any]]
        else { return [:] }
        var result: [String: AssetAvailability] = [:]
        for package in packages {
            guard let name = package["name"] as? String else { continue }
            guard let annual = package["annualWindow"] as? [String: Any],
                  let start = parseMonthDay(annual["startMonthDay"] as? String),
                  let end = parseMonthDay(annual["endMonthDay"] as? String)
            else {
                result[name] = AssetAvailability(isYearRound: true, annualWindows: [])
                continue
            }
            result[name] = AssetAvailability(
                isYearRound: false,
                annualWindows: [AnnualWindow(
                    startMonth: start.month, startDay: start.day,
                    endMonth: end.month, endDay: end.day
                )]
            )
        }
        return result
    }

    private static func loadAvailabilityReferences(root: URL) -> [String: Set<String>] {
        let references = root.appendingPathComponent("Availability", isDirectory: true)
        guard let packages = try? FileManager.default.contentsOfDirectory(
            at: references, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [:] }
        var result: [String: Set<String>] = [:]
        for package in packages {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: package, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { continue }
            for file in files {
                result[file.deletingPathExtension().lastPathComponent, default: []]
                    .insert(package.lastPathComponent)
            }
        }
        return result
    }

    private static func availability(
        for identifier: String,
        candidates: [AssetRecord],
        packageWindows: [String: AssetAvailability],
        availabilityReferences: [String: Set<String>]
    ) -> AssetAvailability {
        var packageNames = availabilityReferences[identifier] ?? []
        var hasDefaultCandidate = false
        for candidate in candidates {
            let components = candidate.directoryURL.pathComponents
            if let index = components.firstIndex(of: "Optional"), index + 1 < components.count {
                packageNames.insert(components[index + 1])
            } else if !components.contains("Resolved") {
                hasDefaultCandidate = true
            }
        }
        if packageNames.isEmpty { hasDefaultCandidate = true }
        var result = AssetAvailability(isYearRound: hasDefaultCandidate, annualWindows: [])
        for package in packageNames {
            guard let availability = packageWindows[package] else {
                result.isYearRound = true
                continue
            }
            if availability.isYearRound { result.isYearRound = true }
            result.annualWindows.formUnion(availability.annualWindows)
        }
        return result
    }

    private static func parseMonthDay(_ value: String?) -> (month: Int, day: Int)? {
        guard let value else { return nil }
        let parts = value.split(separator: "-")
        guard parts.count == 2, let month = Int(parts[0]), let day = Int(parts[1]) else { return nil }
        return (month, day)
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
            ("characterSceneTransitionPose", .characterSceneTransitionPose),
            ("spriteTransitionParameters", .spriteTransitionParameters),
            ("sceneTransitionCategory", .sceneTransitionCategory),
            ("sceneTransitionPair", .sceneTransitionPair), ("scenePalette", .scenePalette),
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
        let hideStyle = (payload["hideStyle"] as? [String: Any])?["sprite"] as? [String: Any]
        let revealStyle = (payload["revealStyle"] as? [String: Any])?["sprite"] as? [String: Any]
        let palette: Palette?
        if let background = color(payload["backgroundColor"]) {
            palette = Palette(background: background, overlay: color(payload["overlayColor"]))
        } else { palette = nil }
        return AssetRecord(
            identifier: directory.deletingPathExtension().lastPathComponent,
            kind: match.1, directoryURL: directory, sourcePriority: priority,
            availability: AssetAvailability(),
            sprites: parseSprites(content, directory: directory),
            relevancy: parseRelevancy(payload["relevancyData"]),
            startPoseID: payload["startCharacterBasePoseID"] as? String,
            endPoseID: payload["endCharacterBasePoseID"] as? String,
            transitionCategoryIDs: payload["transitionCategoryIDs"] as? [String] ?? [],
            transitionPairIDs: payload["sceneTransitionPairIDs"] as? [String] ?? [],
            hideCharacterPoseIDs: payload["hideCharacterPoseIDs"] as? [String] ?? [],
            revealCharacterPoseIDs: payload["revealCharacterPoseIDs"] as? [String] ?? [],
            transitionPhase: (payload["transitionPhase"] as? String).flatMap(SceneTransitionPhase.init),
            hideTransitionParametersID: hideStyle?["parametersID"] as? String,
            revealTransitionParametersID: revealStyle?["parametersID"] as? String,
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
