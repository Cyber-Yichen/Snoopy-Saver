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
    case sceneTransitionCategory, sceneTransitionPair, scenePalette, switcherScene
}

enum SpritePhase: String, CaseIterable { case oneShot, intro, loop, outro }
enum SpriteMediaType: String { case video, frameSequence }

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
        let url = directoryURL.appendingPathComponent(baseName).appendingPathExtension("mov")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    func frameURL(_ frame: Int) -> URL? {
        let number = String(format: "%0*d", digitCount, frame)
        let url = directoryURL.appendingPathComponent("\(baseName)_\(number).heic")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

struct Palette {
    let background: NSColor
    let overlay: NSColor?
}

struct AssetRecord {
    var activeMovieURL: URL? {
        sprites.lazy.filter { $0.mediaType == .video }.compactMap(\.movieURL).first
    }

    let identifier: String
    let kind: AssetKind
    let directoryURL: URL
    let sourcePriority: Int
    let sprites: [SpriteDescriptor]
    let relevancy: RelevancyRecord
    let startPoseID: String?
    let endPoseID: String?
    let transitionCategoryIDs: Set<String>
    let transitionPairIDs: Set<String>
    let preventsIdleSceneChange: Bool
    let sceneOffset: CGPoint
    let ignoresSceneOffset: Bool
    let isFullscreenEffect: Bool
    let excludedAdditionalPoses: Set<String>
    let excludedMoments: Set<String>
    let excludedPalettes: Set<String>
    let excludedVisitors: Set<String>
    let palette: Palette?
}

enum OfficialTransitionStyle: String, CaseIterable {
    case horizontalWipe, clockWipe, circularWipe, thoughtBubble, sleepingDreamBubble, dissolve
}

struct TransitionChoice {
    let pairID: String
    let style: OfficialTransitionStyle
    let preventsIdleSceneChange: Bool
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
