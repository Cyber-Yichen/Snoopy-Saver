import Foundation

private enum LiteFailure: Error, CustomStringConvertible {
    case failed(String)
    var description: String {
        switch self { case .failed(let message): return message }
    }
}

@main
struct LiteCatalogSmoke {
    static func main() throws {
        guard (2...3).contains(CommandLine.arguments.count) else {
            throw LiteFailure.failed(
                "usage: LiteCatalogSmoke RESOURCES_PATH [hydrated]"
            )
        }
        let resources = URL(
            fileURLWithPath: CommandLine.arguments[1], isDirectory: true
        )
        let catalog = try AssetCatalog(resources: resources)
        let active = catalog.assets(.activeScene).filter(\.hasPlayableMedia)
        let idle = catalog.assets(.idleScene).filter(\.hasPlayableMedia)
        let base = catalog.assets(.characterBasePose).filter(\.hasPlayableMedia)
        let transitionPoses = catalog.assets(.characterSceneTransitionPose)
            .filter(\.hasPlayableMedia)
        let parameters = catalog.assets(.spriteTransitionParameters)
            .filter(\.hasPlayableMedia)
        let hydrated = CommandLine.arguments.count == 3
        if hydrated {
            try require(
                active.count == 65,
                "hydrated catalog expected 65 ActiveScenes, got \(active.count)"
            )
            try require(
                idle.count == 39,
                "hydrated catalog expected 39 IdleScenes, got \(idle.count)"
            )
        } else {
            try require(
                active.count == 12,
                "expected 12 offline ActiveScenes, got \(active.count)"
            )
            try require(
                idle.count >= 6,
                "expected at least 6 offline IdleScenes, got \(idle.count)"
            )
        }
        try require(!base.isEmpty, "no offline character base pose")
        try require(!transitionPoses.isEmpty, "no offline transition character pose")
        try require(parameters.count == 14, "official transition masks are incomplete")
        print(
            "CDN-lite catalog passed: active=\(active.count), idle=\(idle.count), "
                + "base=\(base.count), transitionPoses=\(transitionPoses.count), "
                + "parameters=\(parameters.count)"
        )
    }

    private static func require(
        _ value: @autoclosure () -> Bool, _ message: String
    ) throws {
        if !value() { throw LiteFailure.failed(message) }
    }
}
