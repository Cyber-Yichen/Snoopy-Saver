import AppKit
import ScreenSaver

private enum CollisionFailure: Error, CustomStringConvertible {
    case failed(String)
    var description: String {
        switch self { case .failed(let message): return message }
    }
}

@main
private struct VariantCollisionSmoke {
    static func main() throws {
        guard CommandLine.arguments.count >= 3 else {
            throw CollisionFailure.failed(
                "usage: VariantCollisionSmoke SAVER_PATH SAVER_PATH ..."
            )
        }
        var classNames: Set<String> = []
        var retainedBundles: [Bundle] = []
        var retainedViews: [ScreenSaverView] = []
        for path in CommandLine.arguments.dropFirst() {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            guard let bundle = Bundle(url: url), bundle.load(),
                  let type = bundle.principalClass as? ScreenSaverView.Type,
                  let view = type.init(
                    frame: NSRect(x: 0, y: 0, width: 320, height: 200),
                    isPreview: true
                  ) else {
                throw CollisionFailure.failed("unable to load \(path)")
            }
            let className = NSStringFromClass(type)
            guard classNames.insert(className).inserted else {
                throw CollisionFailure.failed(
                    "duplicate Objective-C principal class: \(className)"
                )
            }
            retainedBundles.append(bundle)
            retainedViews.append(view)
            print("loaded \(bundle.bundleIdentifier ?? "unknown") as \(className)")
        }
        withExtendedLifetime((retainedBundles, retainedViews)) {}
        print("Variant collision smoke passed: \(classNames.count) unique principal classes")
    }
}
