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
        _ = try addAsset("DefaultAssetBundle/Idle", kind: "idleScene", in: assets)
        _ = try addAsset("DefaultAssetBundle/Pose", kind: "characterBasePose", in: assets)
        try addTransitionFixture(in: assets)

        let catalog = try AssetCatalog(resources: resources)
        let environment = EnvironmentSnapshot(
            date: Date(), facts: RelevancyFacts(), previousWeather: nil, sunrise: nil, sunset: nil
        )
        let scorer = RelevancyEngine()
        precondition(catalog.assets(.activeScene).map(\.identifier) == ["A"])
        let active = catalog.assets(.activeScene)[0]
        precondition(active.activeMovieURL == movie)
        let keeping = catalog.transitionChoice(
            for: active, environment: environment, scorer: scorer,
            avoiding: "PlainPair", avoidingRevealPose: nil, allowIdlePreservation: true
        )
        precondition(keeping?.pairID == "KeepPair" && keeping?.preventsIdleSceneChange == true)
        precondition(keeping?.hidePose?.identifier == "HidePose" && keeping?.revealPose?.identifier == "RevealPose")
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
        print("Theme fixture passed: bundled media precedence, transition phase and pose resolution, IdleScene preservation filter, and missing-media fallback.")

        if CommandLine.arguments.count > 2 {
            let actualResources = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
            let actual = try AssetCatalog(resources: actualResources)
            let environments = [1, 4, 8, 10, 12].compactMap { month in
                Calendar.current.date(from: DateComponents(year: 2026, month: month, day: 10, hour: 15))
            }
            for date in environments {
                let snapshot = EnvironmentProvider().snapshot(at: date)
                precondition(actual.selectActive(environment: snapshot, scorer: RelevancyEngine())?.activeMovieURL != nil)
                precondition(actual.makeIdleComposition(environment: snapshot, scorer: RelevancyEngine()) != nil)
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
        }
        for (name, phase) in [("HidePose", "hide"), ("RevealPose", "reveal")] {
            _ = try addAsset(name, kind: "characterSceneTransitionPose", in: assets,
                             includeMovie: true, fields: ["transitionPhase": phase])
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
