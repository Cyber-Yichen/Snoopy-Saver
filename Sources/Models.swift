import AppKit
import Foundation

enum TimeBand: String, CaseIterable {
    case morning, afternoon, evening, lateNight
    static func current(_ date: Date = Date(), calendar: Calendar = .current) -> TimeBand {
        switch calendar.component(.hour, from: date) {
        case 5..<12: return .morning
        case 12..<17: return .afternoon
        case 17..<22: return .evening
        default: return .lateNight
        }
    }
}

enum AssetKind: String, CaseIterable {
    case activeScene, idleScene, idleSceneVisitor, characterBasePose
    case characterAdditionalPose, characterMoment, characterPoseTransition
    case characterSceneTransitionPose, spriteTransitionParameters
    case sceneTransitionCategory, sceneTransitionPair, scenePalette, switcherScene
}

enum SpritePhase: String, CaseIterable { case oneShot, intro, loop, outro }
enum SpriteMediaType: String { case video, frameSequence }
enum SceneTransitionPhase: String { case hide, reveal }

enum MediaLibrary {
    /// CDN-downloaded media is kept outside the saver bundle so a lightweight
    /// build can gain new scenes without reinstalling the plug-in. The
    /// environment override is also useful for offline smoke tests.
    static var externalRoots: [URL] {
        var roots: [URL] = []
        if let override = ProcessInfo.processInfo.environment["SNOOPY_MEDIA_ROOT"],
           !override.isEmpty {
            roots.append(URL(fileURLWithPath: (override as NSString).expandingTildeInPath))
        }
        let userSupport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
        roots.append(
            userSupport.appendingPathComponent("Snoopy", isDirectory: true)
                .appendingPathComponent("Assets", isDirectory: true)
                .appendingPathComponent("Resolved", isDirectory: true)
        )
        if let processSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first, processSupport.standardizedFileURL != userSupport.standardizedFileURL {
            roots.append(
                processSupport.appendingPathComponent("Snoopy", isDirectory: true)
                    .appendingPathComponent("Assets", isDirectory: true)
                    .appendingPathComponent("Resolved", isDirectory: true)
            )
        }
        return roots
    }

    static func resolve(fileName: String, bundledDirectory: URL) -> URL? {
        let safeAssetDirectory = bundledDirectory.lastPathComponent
        let safeFileName = URL(fileURLWithPath: fileName).lastPathComponent
        guard !safeAssetDirectory.isEmpty, !safeFileName.isEmpty else { return nil }
        let shouldLogResolution = URL(fileURLWithPath: safeFileName)
            .pathExtension.lowercased() == "mov"
        // Full and 1080p bundles must not be silently overridden by media
        // downloaded by a previously installed CDN-lite build. An old
        // non-alpha cache would otherwise turn transparent IdleScene sprites
        // into black rectangles even when the bundled movie is correct.
        let bundled = bundledDirectory.appendingPathComponent(safeFileName)
        if isRegularFile(bundled) {
            if shouldLogResolution {
                SnoopyDiagnostics.shared.logOnce(
                    key: "media:bundled:\(safeAssetDirectory)/\(safeFileName)",
                    category: "media",
                    message: "bundled \(safeAssetDirectory)/\(safeFileName)"
                )
            }
            return bundled
        }
        for root in externalRoots {
            let candidate = root.appendingPathComponent(
                safeAssetDirectory, isDirectory: true
            ).appendingPathComponent(safeFileName)
            if isRegularFile(candidate) {
                if shouldLogResolution {
                    SnoopyDiagnostics.shared.logOnce(
                        key: "media:external:\(safeAssetDirectory)/\(safeFileName)",
                        category: "media",
                        message: "cache fallback \(safeAssetDirectory)/\(safeFileName)"
                    )
                }
                return candidate
            }
        }
        if shouldLogResolution {
            SnoopyDiagnostics.shared.logOnce(
                key: "media:missing:\(safeAssetDirectory)/\(safeFileName)",
                category: "media",
                message: "missing \(safeAssetDirectory)/\(safeFileName)"
            )
        }
        return nil
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        let values = try? url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        return values?.isRegularFile == true && values?.isSymbolicLink != true
    }
}

struct AnnualWindow: Codable, Equatable, Hashable {
    let startMonth: Int
    let startDay: Int
    let endMonth: Int
    let endDay: Int

    func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        let components = calendar.dateComponents([.month, .day], from: date)
        guard let month = components.month, let day = components.day else { return false }
        let value = month * 100 + day
        let start = startMonth * 100 + startDay
        let end = endMonth * 100 + endDay
        // Apple's quarterly windows meet on the same boundary day. Several
        // date-specific scenes (notably Halloween on October 31) live in the
        // window that ends that day, so both endpoints must remain available.
        if start < end { return value >= start && value <= end }
        return value >= start || value <= end
    }
}

struct AssetAvailability: Equatable {
    var isYearRound = true
    var annualWindows: Set<AnnualWindow> = []

    func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        isYearRound || annualWindows.contains { $0.contains(date, calendar: calendar) }
    }
}

struct RelevancyFacts: Codable, Equatable {
    var events: Set<String> = []
    var timeBands: Set<String> = []
    var routines: Set<String> = []
    var weather: Set<String> = []
    var hourlyEvents: Set<String> = []
    var reactionTriggers: Set<String> = []
    var isEmpty: Bool {
        events.isEmpty && timeBands.isEmpty && routines.isEmpty && weather.isEmpty
            && hourlyEvents.isEmpty && reactionTriggers.isEmpty
    }
    var groupKeys: Set<String> {
        Set(events.map { "event:\($0)" }).union(timeBands.map { "time:\($0)" })
            .union(routines.map { "routine:\($0)" }).union(weather.map { "weather:\($0)" })
            .union(hourlyEvents.map { "hourly:\($0)" })
    }
    func intersects(_ other: RelevancyFacts) -> Bool {
        !events.isDisjoint(with: other.events) || !timeBands.isDisjoint(with: other.timeBands)
            || !routines.isDisjoint(with: other.routines) || !weather.isDisjoint(with: other.weather)
            || !hourlyEvents.isDisjoint(with: other.hourlyEvents)
            || !reactionTriggers.isDisjoint(with: other.reactionTriggers)
    }
}

struct RelevancyClause: Codable, Equatable { let category: String; let facts: RelevancyFacts }
struct RelevancyRecord: Codable, Equatable {
    var info = RelevancyFacts()
    var dependencies: [RelevancyClause] = []
    var exclusions: [RelevancyClause] = []
}

enum WeatherCondition: String, Codable {
    case clear, sunny, cloudy, foggy, windy, rainy, stormy, snowy, icy
    case moonNew, moonWaxingCrescent, moonFirstQuarter, moonWaxingGibbous
    case moonFull, moonWaningGibbous, moonLastQuarter, moonWaningCrescent
}

struct EnvironmentSnapshot {
    let date: Date
    let facts: RelevancyFacts
    let previousWeather: String?
    let sunrise: Date?
    let sunset: Date?
}

struct SpriteDescriptor {
    let baseName: String
    let directoryURL: URL
    let mediaType: SpriteMediaType
    let phase: SpritePhase
    let assetSize: CGSize
    let alignment: String
    let plane: String
    let loops: Bool
    let startFrame: Int
    let endFrame: Int
    let digitCount: Int

    var frameCount: Int { max(1, endFrame - startFrame + 1) }
    var movieURL: URL? {
        MediaLibrary.resolve(fileName: "\(baseName).mov", bundledDirectory: directoryURL)
    }
    func frameURL(_ frame: Int) -> URL? {
        let number = String(format: "%0*d", digitCount, frame)
        return MediaLibrary.resolve(
            fileName: "\(baseName)_\(number).heic", bundledDirectory: directoryURL
        )
    }
    var hasPlayableMedia: Bool {
        switch mediaType {
        case .video:
            return movieURL != nil
        case .frameSequence:
            return frameURL(startFrame) != nil && frameURL(endFrame) != nil
        }
    }
}

struct Palette {
    let background: NSColor
    let overlay: NSColor?
}

struct AssetRecord {
    let identifier: String
    let kind: AssetKind
    let directoryURL: URL
    let sourcePriority: Int
    var availability: AssetAvailability
    let sprites: [SpriteDescriptor]
    let relevancy: RelevancyRecord
    let startPoseID: String?
    let endPoseID: String?
    let transitionCategoryIDs: [String]
    let transitionPairIDs: [String]
    let hideCharacterPoseIDs: [String]
    let revealCharacterPoseIDs: [String]
    let transitionPhase: SceneTransitionPhase?
    let hideTransitionParametersID: String?
    let revealTransitionParametersID: String?
    let preventsIdleSceneChange: Bool
    let sceneOffset: CGPoint
    let ignoresSceneOffset: Bool
    let isFullscreenEffect: Bool
    let excludedAdditionalPoses: Set<String>
    let excludedMoments: Set<String>
    let excludedPalettes: Set<String>
    let excludedVisitors: Set<String>
    let palette: Palette?

    var hasPlayableMedia: Bool {
        sprites.isEmpty || sprites.allSatisfy(\.hasPlayableMedia)
    }
}

enum OfficialTransitionStyle: String, CaseIterable {
    case horizontalWipe, clockWipe, circularWipe, thoughtBubble, sleepingDreamBubble, dissolve
}

struct TransitionChoice {
    let categoryID: String
    let pairID: String
    let style: OfficialTransitionStyle
    let preventsIdleSceneChange: Bool
    let hideCharacterPose: AssetRecord?
    let revealCharacterPose: AssetRecord?
    let hideParameters: AssetRecord?
    let revealParameters: AssetRecord?
}

struct IdleComposition {
    let scene: AssetRecord
    let palette: AssetRecord?
    let basePose: AssetRecord
    let fullscreenEffect: AssetRecord?
}

enum PlaneOrder {
    static func z(_ plane: String) -> CGFloat {
        switch plane {
        case "backgroundEffect": return 10
        case "backgroundVisitor": return 20
        case "backgroundCharacter": return 30
        case "centerpiece": return 40
        case "foregroundCharacter": return 50
        case "foregroundVisitor": return 60
        case "foregroundEffect": return 70
        case "mask": return 80
        default: return 45
        }
    }
}
