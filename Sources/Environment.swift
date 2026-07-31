import CoreLocation
import Foundation

enum EventCalendar {
    private static let notable: [String: Set<String>] = [
        "02-11": ["peanutsCharlieBrownDay"], "07-20": ["peanutsMoonlanding"],
        "08-10": ["peanutsSnoopysBirthday"], "10-02": ["peanutsFirstComicStrip"],
        "10-04": ["peanutsSnoopyDebut"], "11-26": ["peanutsGoodGrief"],
        "12-16": ["peanutsBeethovensBirthday"],
    ]
    static func specialEvents(on date: Date, calendar: Calendar = .current) -> Set<String> {
        let key = String(format: "%02d-%02d", calendar.component(.month, from: date), calendar.component(.day, from: date))
        var result = notable[key] ?? []
        if isNthWeekday(date, month: 11, weekday: 5, ordinal: 4, calendar: calendar) {
            result.insert("peanutsCharlieBrownThanksgiving")
        }
        return result
    }
    static func activeEvents(on date: Date, calendar: Calendar = .current) -> Set<String> {
        let month = calendar.component(.month, from: date), day = calendar.component(.day, from: date)
        var result = specialEvents(on: date, calendar: calendar)
        let fixed: [String: String] = [
            "01-01":"newYearsDay", "02-14":"valentinesDay", "04-01":"aprilFoolsDay",
            "04-22":"earthDay", "07-04":"fourthOfJuly", "08-19":"aviationDay",
            "10-31":"halloween", "12-24":"christmasEve", "12-25":"christmas", "12-31":"newYearsEve",
        ]
        let key = String(format: "%02d-%02d", month, day)
        if let event = fixed[key] { result.insert(event) }
        if month == 10 { result.insert("halloweenSeason") }
        if month == 12 && day <= 26 { result.insert("christmasSeason") }
        if isNthWeekday(date, month: 11, weekday: 5, ordinal: 4, calendar: calendar) { result.insert("thanksgiving") }
        if isNthWeekday(date, month: 5, weekday: 1, ordinal: 2, calendar: calendar) { result.insert("mothersDay") }
        if isNthWeekday(date, month: 6, weekday: 1, ordinal: 3, calendar: calendar) { result.insert("fathersDay") }
        switch month { case 3...5: result.insert("spring"); case 6...8: result.insert("summer");
        case 9...11: result.insert("fall"); default: result.insert("winter") }
        if key == "03-20" { result.insert("startOfSpring") }
        if key == "06-21" { result.insert("startOfSummer") }
        if key == "09-22" { result.insert("startOfFall") }
        if key == "12-21" { result.insert("startOfWinter") }
        let chinese = Calendar(identifier: .chinese).dateComponents([.month, .day], from: date)
        if chinese.month == 1 && chinese.day == 1 { result.insert("lunarNewYear") }
        return result
    }
    private static func isNthWeekday(_ date: Date, month: Int, weekday: Int, ordinal: Int, calendar: Calendar) -> Bool {
        let c = calendar.dateComponents([.month, .weekday, .weekdayOrdinal], from: date)
        return c.month == month && c.weekday == weekday && c.weekdayOrdinal == ordinal
    }
}

enum RoutineCalendar {
    static func active(on date: Date, calendar: Calendar = .current) -> Set<String> {
        let hour = calendar.component(.hour, from: date)
        let weekday = calendar.component(.weekday, from: date)
        let weekend = weekday == 1 || weekday == 7
        var result: Set<String> = []
        if (5..<10).contains(hour) { result.insert("morning") }
        if (12..<17).contains(hour) { result.insert("afternoon") }
        if (7..<10).contains(hour) {
            if weekend { result.insert("brunch") }
            else { result.formUnion(["goingToWork", "goingToSchool"]) }
        }
        if (11..<14).contains(hour) { result.insert("lunch") }
        if (17..<21).contains(hour) { result.insert("dinner") }
        if hour >= 21 || hour < 1 { result.insert("bedtime") }
        if hour >= 23 || hour < 5 { result.insert("lateNight") }
        return result
    }
}

enum LunarPhase {
    static func condition(on date: Date) -> WeatherCondition {
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let reference = utc.date(from: DateComponents(year: 2000, month: 1, day: 6, hour: 18, minute: 14))!
        var phase = (date.timeIntervalSince(reference) / 86_400 / 29.530588853).truncatingRemainder(dividingBy: 1)
        if phase < 0 { phase += 1 }
        switch phase { case 0..<0.0625, 0.9375...1: return .moonNew; case 0.0625..<0.1875: return .moonWaxingCrescent;
        case 0.1875..<0.3125: return .moonFirstQuarter; case 0.3125..<0.4375: return .moonWaxingGibbous;
        case 0.4375..<0.5625: return .moonFull; case 0.5625..<0.6875: return .moonWaningGibbous;
        case 0.6875..<0.8125: return .moonLastQuarter; default: return .moonWaningCrescent }
    }
}

final class EnvironmentProvider: NSObject, CLLocationManagerDelegate {
    var onUpdate: (() -> Void)?
    private let manager = CLLocationManager()
    private var cache: WeatherCache?
    private var lastAttempt = Date.distantPast
    private var fetching = false
    private var session: URLSession?

    override init() {
        super.init(); manager.delegate = self; manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        if let data = UserDefaults.standard.data(forKey: "SnoopyWeatherCache.v3") {
            cache = try? JSONDecoder().decode(WeatherCache.self, from: data)
        }
    }
    deinit { stop() }
    func stop() {
        manager.stopUpdatingLocation()
        session?.invalidateAndCancel(); session = nil; fetching = false
    }
    func start() {
        onUpdate?()
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        else if manager.authorizationStatus == .authorized || manager.authorizationStatus == .authorizedAlways { manager.requestLocation() }
        else { fetch(fallbackLocation()) }
    }
    func refreshIfNeeded() {
        guard Date().timeIntervalSince(cache?.fetchedAt ?? .distantPast) > 30 * 60,
              Date().timeIntervalSince(lastAttempt) > 5 * 60 else { return }
        manager.requestLocation()
    }
    func snapshot(at date: Date = Date()) -> EnvironmentSnapshot {
        var facts = RelevancyFacts()
        facts.events = EventCalendar.activeEvents(on: date)
        facts.timeBands = [TimeBand.current(date).rawValue]
        facts.routines = RoutineCalendar.active(on: date)
        if let condition = cache?.current { facts.weather.insert(condition) }
        facts.weather.insert(LunarPhase.condition(on: date).rawValue)
        if Calendar.current.component(.hour, from: date) == 0 && Calendar.current.component(.minute, from: date) < 15 {
            facts.hourlyEvents.insert("midnight")
        }
        if let sunrise = cache?.sunrise, abs(date.timeIntervalSince(sunrise)) <= 15 * 60 { facts.hourlyEvents.insert("sunrise") }
        if let sunset = cache?.sunset, abs(date.timeIntervalSince(sunset)) <= 15 * 60 { facts.hourlyEvents.insert("sunset") }
        return EnvironmentSnapshot(date: date, facts: facts, previousWeather: cache?.previous,
                                   sunrise: cache?.sunrise, sunset: cache?.sunset)
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorized || manager.authorizationStatus == .authorizedAlways { manager.requestLocation() }
        else if manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted { fetch(fallbackLocation()) }
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let location = locations.last { fetch(location) }
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) { fetch(fallbackLocation()) }

    private func fetch(_ location: CLLocation) {
        guard !fetching else { return }; fetching = true; lastAttempt = Date()
        guard var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast") else {
            fetching = false; return
        }
        c.queryItems = [
            .init(name:"latitude", value:String(format:"%.5f", location.coordinate.latitude)),
            .init(name:"longitude", value:String(format:"%.5f", location.coordinate.longitude)),
            .init(name:"current", value:"weather_code,is_day,temperature_2m,wind_speed_10m"),
            .init(name:"daily", value:"weather_code,sunrise,sunset"), .init(name:"past_days", value:"1"),
            .init(name:"forecast_days", value:"1"), .init(name:"timezone", value:"auto"),
        ]
        guard let url = c.url else { fetching = false; return }
        if session == nil {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 10
            configuration.timeoutIntervalForResource = 20
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            session = URLSession(configuration: configuration)
        }
        session?.dataTask(with: url) { [weak self] data, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode
            let decoded: WeatherResponse? = {
                guard status == 200, let data, data.count <= 1_000_000 else { return nil }
                return try? JSONDecoder().decode(WeatherResponse.self, from: data)
            }()
            guard let decoded else {
                DispatchQueue.main.async { self?.fetching = false }
                return
            }
            let current = Self.map(code: decoded.current.weatherCode, day: decoded.current.isDay == 1,
                                   temperature: decoded.current.temperature, wind: decoded.current.windSpeed)
            let previous = Self.map(code: decoded.daily.weatherCode.first ?? decoded.current.weatherCode,
                                    day: true, temperature: decoded.current.temperature, wind: 0)
            let value = WeatherCache(fetchedAt: Date(), current: current.rawValue, previous: previous.rawValue,
                                     sunrise: decoded.daily.sunrise.last.flatMap(Self.date),
                                     sunset: decoded.daily.sunset.last.flatMap(Self.date))
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.fetching = false; self.cache = value
                if let encoded = try? JSONEncoder().encode(value) {
                    UserDefaults.standard.set(encoded, forKey: "SnoopyWeatherCache.v3")
                }
                self.onUpdate?()
            }
        }.resume()
    }
    static func map(code: Int, day: Bool, temperature: Double, wind: Double) -> WeatherCondition {
        if wind >= 40 { return .windy }
        if temperature <= 1 && [48,56,57,66,67].contains(code) { return .icy }
        switch code { case 0: return day ? .sunny : .clear; case 1: return .clear; case 2,3: return .cloudy;
        case 45...49: return .foggy; case 51...67,80...82: return .rainy; case 71...77,85,86: return .snowy;
        case 95...99: return .stormy; default: return .clear }
    }
    private static func date(_ value: String) -> Date? {
        let f = DateFormatter(); f.locale = Locale(identifier:"en_US_POSIX"); f.timeZone = .current; f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return f.date(from: value)
    }
    private func fallbackLocation() -> CLLocation {
        let id = TimeZone.current.identifier
        if id.hasPrefix("Asia/Shanghai") { return CLLocation(latitude:31.2304, longitude:121.4737) }
        if id.hasPrefix("Asia/Tokyo") { return CLLocation(latitude:35.6762, longitude:139.6503) }
        if id.hasPrefix("Europe/") { return CLLocation(latitude:48.8566, longitude:2.3522) }
        if id.hasPrefix("America/New_York") { return CLLocation(latitude:40.7128, longitude:-74.0060) }
        return CLLocation(latitude:37.3349, longitude:-122.0090)
    }
}

private struct WeatherCache: Codable { let fetchedAt: Date; let current, previous: String; let sunrise, sunset: Date? }
private struct WeatherResponse: Decodable {
    struct Current: Decodable { let weatherCode, isDay: Int; let temperature, windSpeed: Double
        enum CodingKeys: String, CodingKey { case weatherCode="weather_code", isDay="is_day", temperature="temperature_2m", windSpeed="wind_speed_10m" } }
    struct Daily: Decodable { let weatherCode: [Int]; let sunrise, sunset: [String]
        enum CodingKeys: String, CodingKey { case weatherCode="weather_code", sunrise, sunset } }
    let current: Current; let daily: Daily
}
