import Foundation

private enum SmokeFailure: Error, CustomStringConvertible {
    case failed(String)
    var description: String {
        switch self { case .failed(let message): return message }
    }
}

@main
struct ThemeSmokeTests {
    static var calendar: Calendar = {
        var value = Calendar(identifier: .gregorian)
        value.locale = Locale(identifier: "en_US_POSIX")
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }()

    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw SmokeFailure.failed("usage: ThemeSmokeTests RESOURCES_PATH")
        }
        let resources = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let catalog = try AssetCatalog(resources: resources)
        try testCalendarFacts()
        try testRoutineFacts()
        try testWeatherMapping()
        try testCatalogThemes(catalog)
        try testRelevancyAndFrecency(catalog)
        try testAnnualWindows(catalog)
        try testOfficialTransitions(catalog)
        try testExternalMediaResolution()
        print("Theme smoke tests passed: \(catalog.records.count) unique assets")
    }

    private static func date(_ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        date(year: 2026, month: month, day: day, hour: hour)
    }

    private static func date(
        year: Int, month: Int, day: Int, hour: Int = 12
    ) -> Date {
        calendar.date(from: DateComponents(
            calendar: calendar, timeZone: calendar.timeZone,
            year: year, month: month, day: day, hour: hour
        ))!
    }

    private static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw SmokeFailure.failed(message) }
    }

    private static func lunarNewYear(in year: Int) throws -> Date {
        var chineseCalendar = Calendar(identifier: .chinese)
        chineseCalendar.timeZone = calendar.timeZone
        for dayOffset in 0..<45 {
            let start = date(year: year, month: 1, day: 20)
            let candidate = calendar.date(byAdding: .day, value: dayOffset, to: start)!
            let chinese = chineseCalendar.dateComponents(
                [.month, .day], from: candidate
            )
            if chinese.month == 1 && chinese.day == 1 { return candidate }
        }
        throw SmokeFailure.failed("unable to locate lunar new year fixture")
    }

    private static func testCalendarFacts() throws {
        let fixtures: [(String, Date)] = [
            ("spring", date(3, 21)), ("summer", date(6, 22)),
            ("fall", date(9, 23)), ("winter", date(12, 22)),
            ("startOfSpring", date(3, 20)), ("startOfSummer", date(6, 21)),
            ("startOfFall", date(9, 22)), ("startOfWinter", date(12, 21)),
            ("christmasEve", date(12, 24)), ("christmas", date(12, 25)),
            ("halloween", date(10, 31)), ("thanksgiving", date(11, 26)),
            ("newYearsDay", date(1, 1)), ("newYearsEve", date(12, 31)),
            ("valentinesDay", date(2, 14)), ("earthDay", date(4, 22)),
            ("aviationDay", date(8, 19)), ("mothersDay", date(5, 10)),
            ("fathersDay", date(6, 21)), ("fourthOfJuly", date(7, 4)),
            ("peanutsMoonlanding", date(7, 20)),
            ("peanutsFirstComicStrip", date(10, 2)),
            ("peanutsSnoopyDebut", date(10, 4)),
            ("peanutsSnoopysBirthday", date(8, 10)),
            ("peanutsBeethovensBirthday", date(12, 16)),
        ]
        for (event, fixture) in fixtures {
            try require(
                EventCalendar.activeEvents(on: fixture, calendar: calendar).contains(event),
                "calendar fixture did not activate \(event)"
            )
        }
        let lunarFixture = try lunarNewYear(in: 2026)
        try require(
            EventCalendar.activeEvents(on: lunarFixture, calendar: calendar).contains("lunarNewYear"),
            "lunar new year was not activated"
        )
        try require(
            EventCalendar.activeEvents(on: date(10, 15), calendar: calendar)
                .contains("halloweenSeason"),
            "Halloween season was not activated"
        )
        try require(
            EventCalendar.activeEvents(on: date(11, 15), calendar: calendar)
                .contains("thanksgivingSeason"),
            "Thanksgiving season was not activated"
        )
        try require(
            EventCalendar.activeEvents(on: date(12, 10), calendar: calendar)
                .contains("christmasSeason"),
            "Christmas season was not activated"
        )
    }

    private static func testRoutineFacts() throws {
        let fixtures: [(String, Date)] = [
            ("morning", date(7, 27, 8)),
            ("goingToWork", date(7, 27, 8)),
            ("goingToSchool", date(7, 27, 8)),
            ("brunch", date(8, 1, 9)),
            ("lunch", date(7, 27, 12)),
            ("afternoon", date(7, 27, 15)),
            ("dinner", date(7, 27, 18)),
            ("bedtime", date(7, 27, 22)),
            ("lateNight", date(7, 27, 23)),
        ]
        for (routine, fixture) in fixtures {
            try require(
                RoutineCalendar.active(on: fixture, calendar: calendar).contains(routine),
                "routine fixture did not activate \(routine)"
            )
        }
    }

    private static func testWeatherMapping() throws {
        let fixtures: [(WeatherCondition, WeatherCondition)] = [
            (EnvironmentProvider.map(code: 0, day: true, temperature: 20, wind: 1), .sunny),
            (EnvironmentProvider.map(code: 0, day: false, temperature: 20, wind: 1), .clear),
            (EnvironmentProvider.map(code: 45, day: true, temperature: 10, wind: 1), .foggy),
            (EnvironmentProvider.map(code: 2, day: true, temperature: 10, wind: 45), .windy),
            (EnvironmentProvider.map(code: 61, day: true, temperature: 10, wind: 1), .rainy),
            (EnvironmentProvider.map(code: 95, day: true, temperature: 10, wind: 1), .stormy),
            (EnvironmentProvider.map(code: 56, day: true, temperature: 0, wind: 1), .icy),
            (EnvironmentProvider.map(code: 75, day: true, temperature: -2, wind: 1), .snowy),
        ]
        for (actual, expected) in fixtures {
            try require(actual == expected, "weather mapping expected \(expected), got \(actual)")
        }
    }

    private static func snapshot(
        at date: Date,
        weather: String = WeatherCondition.clear.rawValue
    ) -> EnvironmentSnapshot {
        var facts = RelevancyFacts()
        facts.events = EventCalendar.activeEvents(on: date, calendar: calendar)
        facts.timeBands = [TimeBand.current(date, calendar: calendar).rawValue]
        facts.routines = RoutineCalendar.active(on: date, calendar: calendar)
        facts.weather = [weather]
        return EnvironmentSnapshot(
            date: date, facts: facts, previousWeather: weather, sunrise: nil, sunset: nil
        )
    }

    private static func testCatalogThemes(_ catalog: AssetCatalog) throws {
        var eventFixtures: [(String, Date)] = [
            ("spring", date(3, 21)), ("summer", date(6, 22)),
            ("fall", date(9, 23)), ("winter", date(12, 22)),
            ("christmasEve", date(12, 24)), ("christmas", date(12, 25)),
            ("halloween", date(10, 31)), ("thanksgiving", date(11, 26)),
            ("newYearsDay", date(1, 1)), ("valentinesDay", date(2, 14)),
            ("earthDay", date(4, 22)), ("aviationDay", date(8, 19)),
            ("mothersDay", date(5, 10)), ("fathersDay", date(6, 21)),
            ("fourthOfJuly", date(7, 4)), ("peanutsMoonlanding", date(7, 20)),
            ("peanutsFirstComicStrip", date(10, 2)),
            ("peanutsSnoopyDebut", date(10, 4)),
            ("peanutsSnoopysBirthday", date(8, 10)),
            ("peanutsBeethovensBirthday", date(12, 16)),
        ]
        eventFixtures.append(("lunarNewYear", try lunarNewYear(in: 2026)))
        for (event, fixture) in eventFixtures {
            let candidates = catalog.records.filter {
                $0.availability.contains(fixture) && $0.relevancy.info.events.contains(event)
            }
            try require(!candidates.isEmpty, "no available catalog asset for \(event)")
            try require(
                candidates.contains {
                    candidateIsScoreable($0, on: fixture)
                },
                "catalog assets for \(event) were not scoreable"
            )
            try require(
                themeCanReachTop(
                    catalog, on: fixture,
                    matches: { $0.relevancy.info.events.contains(event) }
                ),
                "catalog theme \(event) could not reach the highest score"
            )
        }

        let routineFixtures: [(String, Date)] = [
            ("morning", date(7, 27, 8)),
            ("goingToWork", date(7, 27, 8)),
            ("goingToSchool", date(7, 27, 8)),
            ("brunch", date(8, 1, 9)),
            ("lunch", date(7, 27, 12)),
            ("afternoon", date(7, 27, 15)),
            ("dinner", date(7, 27, 18)),
            ("bedtime", date(7, 27, 22)),
            ("lateNight", date(7, 27, 23)),
        ]
        for (routine, fixture) in routineFixtures {
            try require(
                catalog.assets(.activeScene).contains {
                    $0.relevancy.info.routines.contains(routine)
                },
                "catalog is missing routine theme \(routine)"
            )
            try require(
                themeCanReachTop(
                    catalog, on: fixture,
                    matches: { $0.relevancy.info.routines.contains(routine) }
                ),
                "routine theme \(routine) could not reach the highest score"
            )
        }
        for condition in ["sunny", "foggy", "windy", "rainy", "stormy", "icy", "snowy"] {
            try require(
                catalog.assets(.activeScene).contains {
                    $0.relevancy.info.weather.contains(condition)
                },
                "catalog is missing weather theme \(condition)"
            )
            try require(
                (1...12).contains { month in
                    themeCanReachTop(
                        catalog, on: date(month, 15, 14), weather: condition,
                        matches: { $0.relevancy.info.weather.contains(condition) }
                    )
                },
                "weather theme \(condition) could not reach the highest score"
            )
        }
        let timeTagged = catalog.assets(.activeScene).filter {
            !$0.relevancy.info.timeBands.isEmpty
        }
        try require(
            timeTagged.count == 5,
            "expected 5 time-of-day ActiveScenes, got \(timeTagged.count)"
        )
        let knownBands = Set(TimeBand.allCases.map(\.rawValue))
        try require(
            timeTagged.allSatisfy {
                $0.relevancy.info.timeBands.isSubset(of: knownBands)
            },
            "catalog contains an unknown time-of-day label"
        )
    }

    private static func themeCanReachTop(
        _ catalog: AssetCatalog,
        on date: Date,
        weather: String? = nil,
        matches: (AssetRecord) -> Bool
    ) -> Bool {
        let hours = [7, 9, 12, 14, 18, 22, 23]
        let weatherFixtures = weather.map { [$0] }
            ?? ["clear", "sunny", "foggy", "windy", "rainy", "stormy", "icy", "snowy"]
        for hour in hours {
            guard let fixture = calendar.date(
                bySettingHour: hour, minute: 0, second: 0, of: date
            ) else { continue }
            for condition in weatherFixtures {
                let environment = snapshot(at: fixture, weather: condition)
                let scorer = RelevancyEngine(persistenceKey: nil)
                let scored = catalog.assets(.activeScene, availableOn: fixture).compactMap {
                    asset in scorer.score(
                        asset, kind: "activeScene", environment: environment
                    ).map { (asset, $0) }
                }
                guard let maximum = scored.map(\.1).max() else { continue }
                if scored.contains(where: {
                    matches($0.0) && abs($0.1 - maximum) < 0.000_001
                }) { return true }
            }
        }
        return false
    }

    private static func candidateIsScoreable(_ candidate: AssetRecord, on date: Date) -> Bool {
        let hours = [7, 14, 19, 23]
        let weather = ["clear", "sunny", "foggy", "windy", "rainy", "stormy", "icy", "snowy"]
        for hour in hours {
            guard let fixture = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: date) else {
                continue
            }
            for condition in weather {
                let scorer = RelevancyEngine(persistenceKey: nil)
                if scorer.score(
                    candidate, kind: candidate.kind.rawValue,
                    environment: snapshot(at: fixture, weather: condition),
                    dependencyEnvironment: candidate.relevancy.dependencies
                ) != nil { return true }
            }
        }
        return false
    }

    private static func testAnnualWindows(_ catalog: AssetCatalog) throws {
        let fixtures = [date(11, 15), date(2, 15), date(5, 15), date(8, 15)]
        let counts = fixtures.map { catalog.assets(.activeScene, availableOn: $0).count }
        for count in counts {
            try require((45...50).contains(count), "annual ActiveScene count out of range: \(count)")
        }
        try require(Set(counts).count > 1, "annual windows did not change the ActiveScene pool")
    }

    private static func testRelevancyAndFrecency(_ catalog: AssetCatalog) throws {
        let fixture = date(8, 10, 14)
        let environment = snapshot(at: fixture, weather: "clear")
        guard let birthday = catalog.assets(.activeScene, availableOn: fixture).first(where: {
            $0.relevancy.info.events.contains("peanutsSnoopysBirthday")
                && candidateIsScoreable($0, on: fixture)
        }), let generic = catalog.assets(.activeScene, availableOn: fixture).first(where: {
            $0.relevancy.info.isEmpty
        }) else {
            throw SmokeFailure.failed("missing birthday or generic ActiveScene fixture")
        }
        let scorer = RelevancyEngine(persistenceKey: nil)
        let birthdayScore = scorer.score(birthday, kind: "activeScene", environment: environment)
        let genericScore = scorer.score(generic, kind: "activeScene", environment: environment)
        try require(
            (birthdayScore ?? -.infinity) > (genericScore ?? -.infinity),
            "exact-date scene did not outrank generic content"
        )
        scorer.mark(birthday, kind: "activeScene", at: fixture)
        let next = scorer.choose(
            [birthday, generic], kind: "activeScene", environment: environment
        )
        try require(
            next?.identifier == generic.identifier,
            "immediately previous scene was not fully downranked"
        )
    }

    private static func testOfficialTransitions(_ catalog: AssetCatalog) throws {
        let categories = catalog.assets(.sceneTransitionCategory)
        let pairs = catalog.assets(.sceneTransitionPair)
        let parameters = catalog.assets(.spriteTransitionParameters)
        try require(categories.count == 16, "expected 16 transition categories, got \(categories.count)")
        try require(pairs.count == 13, "expected 13 transition pairs, got \(pairs.count)")
        try require(parameters.count == 14, "expected 14 hide/reveal parameter assets, got \(parameters.count)")
        try require(
            categories.filter(\.preventsIdleSceneChange).count == 8,
            "expected 8 background-preserving transition categories"
        )
        try require(
            categories.filter { !$0.preventsIdleSceneChange }.count == 8,
            "expected 8 background-changing transition categories"
        )
        let parameterIDs = Set(parameters.map(\.identifier))
        for pair in pairs {
            try require(
                pair.hideTransitionParametersID.map(parameterIDs.contains) == true,
                "\(pair.identifier) is missing hide parameters"
            )
            try require(
                pair.revealTransitionParametersID.map(parameterIDs.contains) == true,
                "\(pair.identifier) is missing reveal parameters"
            )
        }

        let morningClear = snapshot(at: date(7, 27, 9), weather: "clear")
        let lateRain = snapshot(at: date(7, 27, 23), weather: "rainy")
        let scorer = RelevancyEngine(persistenceKey: nil)
        for pair in pairs where pair.identifier.contains("ExcludeLateNight") {
            try require(
                scorer.score(pair, kind: "transition", environment: lateRain) == nil,
                "\(pair.identifier) incorrectly allowed late night"
            )
        }
        for pair in pairs where pair.identifier.contains("ExcludeBadWeather") {
            try require(
                scorer.score(pair, kind: "transition", environment: lateRain) == nil,
                "\(pair.identifier) incorrectly allowed bad weather"
            )
        }

        let activeScenes = catalog.assets(.activeScene, availableOn: morningClear.date)
        for scene in activeScenes {
            let choice = catalog.transitionChoice(
                for: scene, environment: morningClear,
                scorer: RelevancyEngine(persistenceKey: nil), avoiding: nil
            )
            try require(choice.pairID != "fallback-dissolve", "\(scene.identifier) had no transition")
            try require(choice.hideParameters != nil, "\(scene.identifier) had no hide parameters")
            try require(choice.revealParameters != nil, "\(scene.identifier) had no reveal parameters")
        }
    }

    private static func testExternalMediaResolution() throws {
        guard let rootPath = ProcessInfo.processInfo.environment["SNOOPY_MEDIA_ROOT"] else {
            throw SmokeFailure.failed("SNOOPY_MEDIA_ROOT fixture was not configured")
        }
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        let assetDirectory = root.appendingPathComponent("ExternalFixture.icasset")
        try FileManager.default.createDirectory(
            at: assetDirectory, withIntermediateDirectories: true
        )
        let externalMovie = assetDirectory.appendingPathComponent("ExternalFixture.mov")
        try Data([0]).write(to: externalMovie)
        let bundledDirectory = root.appendingPathComponent("BundleResources", isDirectory: true)
            .appendingPathComponent("BundledFixture.icasset", isDirectory: true)
        try FileManager.default.createDirectory(
            at: bundledDirectory, withIntermediateDirectories: true
        )
        let bundledMovie = bundledDirectory.appendingPathComponent("BundledFixture.mov")
        try Data([1]).write(to: bundledMovie)
        let staleExternalDirectory = root.appendingPathComponent(
            "BundledFixture.icasset", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: staleExternalDirectory, withIntermediateDirectories: true
        )
        try Data([2]).write(
            to: staleExternalDirectory.appendingPathComponent("BundledFixture.mov")
        )
        let descriptor = SpriteDescriptor(
            baseName: "ExternalFixture",
            directoryURL: URL(fileURLWithPath: "/missing/ExternalFixture.icasset"),
            mediaType: .video,
            phase: .oneShot,
            assetSize: CGSize(width: 1920, height: 1080),
            alignment: "center",
            plane: "centerpiece",
            loops: false,
            startFrame: 0,
            endFrame: 0,
            digitCount: 2
        )
        try require(
            descriptor.movieURL?.standardizedFileURL == externalMovie.standardizedFileURL,
            "external CDN media did not override a missing bundled file"
        )
        try require(descriptor.hasPlayableMedia, "external media was not considered playable")
        let bundledDescriptor = SpriteDescriptor(
            baseName: "BundledFixture",
            directoryURL: bundledDirectory,
            mediaType: .video,
            phase: .oneShot,
            assetSize: CGSize(width: 1920, height: 1080),
            alignment: "center",
            plane: "centerpiece",
            loops: false,
            startFrame: 0,
            endFrame: 0,
            digitCount: 2
        )
        try require(
            bundledDescriptor.movieURL?.standardizedFileURL == bundledMovie.standardizedFileURL,
            "external CDN media overrode a bundled file"
        )
    }
}
