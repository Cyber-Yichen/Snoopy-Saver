import Foundation

@main
struct ThemeSmokeTests {
    static func main() throws {
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let resources = fixture.appendingPathComponent("Resources")
        let assets = resources.appendingPathComponent("Assets")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

        let movie = try addAsset("DefaultAssetBundle/A", kind: "activeScene", in: assets, includeMovie: true)
        _ = try addAsset("Optional/A", kind: "activeScene", in: assets)
        _ = try addAsset("Optional/B", kind: "activeScene", in: assets)
        _ = try addAsset("DefaultAssetBundle/Idle", kind: "idleScene", in: assets)
        _ = try addAsset("DefaultAssetBundle/Pose", kind: "characterBasePose", in: assets)

        let catalog = try AssetCatalog(resources: resources)
        let environment = EnvironmentSnapshot(
            date: Date(), facts: RelevancyFacts(), previousWeather: nil, sunrise: nil, sunset: nil
        )
        let scorer = RelevancyEngine()
        precondition(catalog.assets(.activeScene).map(\.identifier) == ["A"])
        precondition(catalog.selectActive(environment: environment, scorer: scorer)?.activeMovieURL == movie)
        try FileManager.default.removeItem(at: movie)
        precondition(catalog.selectActive(environment: environment, scorer: scorer) == nil)
        let idleOnly = try AssetCatalog(resources: resources)
        precondition(idleOnly.makeIdleComposition(environment: environment, scorer: scorer) != nil)
        print("Theme fixture passed: incomplete optional assets are skipped, bundled duplicate is playable, and IdleScene remains available after media removal.")

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
        _ path: String, kind: String, in assets: URL, includeMovie: Bool = false
    ) throws -> URL {
        let directory = assets.appendingPathComponent(path + ".icasset")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sprite: [String: Any] = ["atlas": ["assetBaseName": "clip"], "spriteType": "video"]
        let sprites = ["oneShotSprites": ["oneShotSprites": ["sprites": [sprite]]]]
        let payload: [String: Any] = kind == "activeScene" ? ["assetContainer": ["content": sprites]] : [:]
        try writePlist([kind: ["_0": payload]], to: directory.appendingPathComponent("metadata.icmetadata"))
        let movie = directory.appendingPathComponent("clip.mov")
        if includeMovie { try Data().write(to: movie) }
        return movie
    }

    private static func writePlist(_ payload: [String: Any], to path: URL) throws {
        try PropertyListSerialization.data(fromPropertyList: payload, format: .binary, options: 0).write(to: path)
    }
}
