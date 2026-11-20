import Foundation

@main
struct ThemeSmokeTests {
    static func main() throws {
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let resources = fixture.appendingPathComponent("Resources")
        let assets = resources.appendingPathComponent("Assets")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

        let movie = try addAsset(
            "DefaultAssetBundle/A", kind: "activeScene", in: assets, includeMovie: true,
            fields: ["transitionCategoryIDs": ["Keep", "Replace"]]
        )
        _ = try addAsset("Optional/A", kind: "activeScene", in: assets)
        _ = try addAsset("Optional/B", kind: "activeScene", in: assets)
        let rain: [[String: Any]] = [["weather": ["condition": "rainy"]]]
        let excludesRain: [[String: Any]] = [["category": "sceneFullscreenEffectVisitor", "info": rain]]
        _ = try addAsset("DefaultAssetBundle/Idle", kind: "idleScene", in: assets, includeMovie: true,
                         fields: ["relevancyData": ["exclusions": excludesRain]])
        let baseMovie = try addAsset("DefaultAssetBundle/Pose", kind: "characterBasePose", in: assets, includeMovie: true)
        let badSprite: [String: Any] = [
            "atlas": ["assetBaseName": "broken"], "spriteType": "frameSequence",
            "customTiming": ["start": 1.0e100, "end": 10],
        ]
        _ = try addAsset("Optional/Pose", kind: "characterBasePose", in: assets, fields: [
            "assetContainer": ["content": ["oneShotSprites": ["oneShotSprites": ["sprites": [badSprite]]]]],
        ])
        var incompleteSprite = badSprite
        incompleteSprite["customTiming"] = ["start": 0, "end": 2]
        let incomplete = try addAsset("DefaultAssetBundleV2/Pose", kind: "characterBasePose", in: assets, fields: [
            "assetContainer": ["content": ["oneShotSprites": ["oneShotSprites": ["sprites": [incompleteSprite]]]]],
        ]).deletingLastPathComponent()
        for frame in ["00", "02"] {
            try Data().write(to: incomplete.appendingPathComponent("broken_\(frame).heic"))
        }
        _ = try addAsset("RainEffect", kind: "idleSceneVisitor", in: assets, includeMovie: true,
                         fields: ["isFullscreenEffect": true, "relevancyData": ["info": rain]])
        _ = try addAsset("Visitor", kind: "idleSceneVisitor", in: assets, includeMovie: true,
                         fields: ["relevancyData": ["exclusions": excludesRain]])
        _ = try addAsset("LongVisitor", kind: "idleSceneVisitor", in: assets, includeMovie: true, fields: [
            "relevancyData": ["info": [["weather": ["condition": "sunny"]]]],
        ])
        for (id, end) in [("ShortPoseChange", "Short"), ("LongPoseChange", "Long")] {
            _ = try addAsset(id, kind: "characterPoseTransition", in: assets, includeMovie: true,
                             fields: ["startCharacterBasePoseID": "Pose", "endCharacterBasePoseID": end])
        }
        let color = ["red": 255, "green": 200, "blue": 100, "alpha": 1]
        _ = try addAsset("WrongPalette", kind: "scenePalette", in: assets, fields: [
            "backgroundColor": color, "parentIdleSceneIDs": ["DifferentScene"], "relevancyData": ["info": rain],
        ])
        _ = try addAsset("IdlePalette", kind: "scenePalette", in: assets,
                         fields: ["backgroundColor": color, "parentIdleSceneIDs": ["Idle"]])
        try addTransitionFixture(in: assets)

        let catalog = try AssetCatalog(resources: resources)
        let environment = EnvironmentSnapshot(
            date: Date(), facts: RelevancyFacts(), previousWeather: nil, sunrise: nil, sunset: nil
        )
        let scorer = RelevancyEngine()
        var wetFacts = RelevancyFacts()
        wetFacts.weather = ["rainy"]
        let wetEnvironment = EnvironmentSnapshot(
            date: environment.date, facts: wetFacts, previousWeather: nil, sunrise: nil, sunset: nil
        )
        let wetComposition = catalog.makeIdleComposition(environment: wetEnvironment, scorer: RelevancyEngine())
        precondition(wetComposition?.scene.identifier == "Idle" && wetComposition?.fullscreenEffect == nil)
        precondition(wetComposition?.basePose.activeMovieURL == baseMovie)
        precondition(wetComposition?.palette?.identifier == "IdlePalette")
        if let scene = wetComposition?.scene {
            let rainPlaying = RelevancyClause(category: "sceneFullscreenEffectVisitor", facts: wetFacts)
            precondition(catalog.selectVisitor(
                scene: scene, environment: wetEnvironment, dependencyEnvironment: [rainPlaying],
                scorer: RelevancyEngine()
            ) == nil)
            precondition(catalog.selectVisitor(
                scene: scene, environment: wetEnvironment, dependencyEnvironment: [], scorer: RelevancyEngine()
            )?.identifier == "Visitor")
            var sun = RelevancyFacts()
            sun.weather = ["sunny"]
            let sunny = EnvironmentSnapshot(date: environment.date, facts: sun, previousWeather: nil, sunrise: nil, sunset: nil)
            precondition(catalog.selectVisitor(
                scene: scene, environment: sunny, dependencyEnvironment: [], scorer: RelevancyEngine()
            )?.identifier == "LongVisitor")
            precondition(catalog.selectVisitor(
                scene: scene, environment: sunny, dependencyEnvironment: [], scorer: RelevancyEngine(),
                eligible: { $0.identifier != "LongVisitor" }
            )?.identifier == "Visitor")
        }
        let fetched = environment.date
        let sunrise = fetched.addingTimeInterval(2 * 60 * 60)
        let cached = WeatherCache(fetchedAt: fetched, current: "rainy", previous: "snowy", sunrise: sunrise, sunset: nil)
        let fresh = EnvironmentProvider.snapshot(at: sunrise.addingTimeInterval(-1), cachedWeather: cached)
        precondition(fresh.facts.weather.contains("rainy") && fresh.previousWeather == "snowy"
            && fresh.facts.hourlyEvents.contains("sunrise"))
        let expired = EnvironmentProvider.snapshot(at: sunrise, cachedWeather: cached)
        precondition(!expired.facts.weather.contains("rainy") && expired.previousWeather == nil
            && expired.sunrise == nil && !expired.facts.hourlyEvents.contains("sunrise"))
        precondition(!cached.isFresh(at: fetched.addingTimeInterval(-1)))
        precondition(EnvironmentProvider.shouldRefresh(at: fetched, fetchedAt: sunrise, lastAttempt: sunrise))
        precondition(!EnvironmentProvider.shouldRefresh(
            at: fetched, fetchedAt: sunrise, lastAttempt: fetched.addingTimeInterval(-60)
        ))
        precondition(!EnvironmentProvider.shouldRefresh(
            at: fetched, fetchedAt: fetched.addingTimeInterval(-60), lastAttempt: .distantPast
        ))
        let short = catalog.selectPoseTransition(from: "Pose", eligible: { $0.endPoseID == "Short" })
        precondition(short?.identifier == "ShortPoseChange")
        precondition(catalog.assets(.activeScene).map(\.identifier) == ["A"])
        let active = catalog.assets(.activeScene)[0]
        precondition(active.activeMovieURL == movie)
        let keeping = catalog.transitionChoice(
            for: active, environment: environment, scorer: scorer,
            avoiding: "PlainPair", avoidingRevealPose: nil, allowIdlePreservation: true
        )
        precondition(keeping?.pairID == "KeepPair" && keeping?.preventsIdleSceneChange == true)
        precondition(keeping?.hidePose?.identifier == "HidePose" && keeping?.revealPose?.identifier == "RevealPose")
        precondition(keeping?.hidePose?.hideStartPoseID == "Pose" && keeping?.revealPose?.hideStartPoseID == nil)
        precondition(keeping?.hide.duration == 1.0 && keeping?.reveal.duration == 1.25)
        let replacement = catalog.transitionChoice(
            for: active, environment: environment, scorer: scorer,
            avoiding: "KeepPair", avoidingRevealPose: "RevealPose", allowIdlePreservation: false
        )
        precondition(replacement?.pairID == "PlainPair" && replacement?.preventsIdleSceneChange == false)
        try FileManager.default.removeItem(at: movie)
        precondition(catalog.selectActive(environment: environment, scorer: scorer) == nil)
        let idleOnly = try AssetCatalog(resources: resources)
        precondition(idleOnly.makeIdleComposition(environment: environment, scorer: scorer) != nil)
        print("Theme fixture passed: media precedence, transitions, weather expiry and exclusions, short-slot visitor fallback, parent palettes, and missing-media fallback.")

        if CommandLine.arguments.count > 2 {
            let actualResources = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
            let actual = try AssetCatalog(resources: actualResources)
            let compatibleHides = actual.assets(.characterSceneTransitionPose).filter { $0.hideStartPoseID != nil }
            precondition(Set(compatibleHides.map(\.identifier)).isSuperset(of: ["104_ST006_Hide_A", "104_ST006_Hide_B"]))
            let environments = [1, 4, 8, 10, 12].compactMap { month in
                Calendar.current.date(from: DateComponents(year: 2026, month: month, day: 10, hour: 15))
            }
            for date in environments {
                let snapshot = EnvironmentProvider().snapshot(at: date)
                precondition(actual.selectActive(environment: snapshot, scorer: RelevancyEngine())?.activeMovieURL != nil)
                precondition(actual.makeIdleComposition(environment: snapshot, scorer: RelevancyEngine())?.palette != nil)
            }
            print("Bundled catalog passed: \(actual.assets(.activeScene).count) playable ActiveScenes, \(actual.assets(.idleScene).count) IdleScenes, \(environments.count) dates.")
        }
    }

    private static func addAsset(
        _ path: String, kind: String, in assets: URL, includeMovie: Bool = false,
        fields: [String: Any] = [:]
    ) throws -> URL {
        let directory = assets.appendingPathComponent(path + ".icasset")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sprite: [String: Any] = ["atlas": ["assetBaseName": "clip"], "spriteType": "video"]
        let sprites = ["oneShotSprites": ["oneShotSprites": ["sprites": [sprite]]]]
        var payload = fields
        if includeMovie { payload["assetContainer"] = ["content": sprites] }
        try writePlist([kind: ["_0": payload]], to: directory.appendingPathComponent("metadata.icmetadata"))
        let movie = directory.appendingPathComponent("clip.mov")
        if includeMovie { try Data().write(to: movie) }
        return movie
    }

    private static func addTransitionFixture(in assets: URL) throws {
        for name in ["KeepPair", "PlainPair"] {
            _ = try addAsset(name, kind: "sceneTransitionPair", in: assets, fields: [
                "hideStyle": ["sprite": ["parametersID": "Hide"]],
                "revealStyle": ["sprite": ["parametersID": "Reveal"]],
            ])
        }
        for (name, endFrame) in [("Hide", 23), ("Reveal", 29)] {
            let sprites: [[String: Any]] = ["mask", "foregroundEffect"].map { plane in
                [
                    "atlas": ["assetBaseName": plane],
                    "plane": plane,
                    "spriteType": "frameSequence",
                    "customTiming": ["start": 0, "end": endFrame],
                ]
            }
            _ = try addAsset(name, kind: "spriteTransitionParameters", in: assets, fields: [
                "assetContainer": ["content": ["oneShotSprites": ["oneShotSprites": ["sprites": sprites]]]],
            ])
            for plane in ["mask", "foregroundEffect"] {
                for frame in 0...endFrame {
                    let url = assets.appendingPathComponent("\(name).icasset/\(plane)_\(String(format: "%02d", frame)).heic")
                    try Data().write(to: url)
                }
            }
        }
        for (name, phase) in [("HidePose", "hide"), ("RevealPose", "reveal")] {
            _ = try addAsset(name, kind: "characterSceneTransitionPose", in: assets,
                             includeMovie: true, fields: ["transitionPhase": phase, "startCharacterBasePoseID": "Pose"])
        }
        _ = try addAsset("Keep", kind: "sceneTransitionCategory", in: assets, fields: [
            "sceneTransitionPairIDs": ["KeepPair"],
            "hideCharacterPoseIDs": ["HidePose"],
            "revealCharacterPoseIDs": ["RevealPose"],
            "preventsIdleSceneChange": true,
        ])
        _ = try addAsset("Replace", kind: "sceneTransitionCategory", in: assets, fields: [
            "sceneTransitionPairIDs": ["PlainPair"],
        ])
    }

    private static func writePlist(_ payload: [String: Any], to path: URL) throws {
        try PropertyListSerialization.data(fromPropertyList: payload, format: .binary, options: 0).write(to: path)
    }
}
