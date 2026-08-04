import Foundation
import Testing
@testable import DigestCore

@Suite struct ConfigTests {
    @Test func defaultsMatchReadme() throws {
        let c = try JSONDecoder().decode(Config.self, from: Data("{}".utf8))
        #expect(c == Config())
        #expect(c.categories == ["cs.LG", "cs.AI", "cs.MA", "cs.CL", "cs.CV", "cs.RO", "math.DG", "math.AT", "math.PR", "math.ST", "stat.ML"])
        #expect(c.topN == 15)
        #expect(c.minScore == 6)
        #expect(c.models.triage == "claude-haiku-5-5")
        #expect(c.models.digest == "claude-opus-5-5")
        #expect(c.models.chat == "claude-sonnet-5-5")
        #expect(c.dailyBudgetUsd == 4.0)
        #expect(c.schedule == Config.Schedule(windowStart: 3, windowEnd: 9, showAt: 10, idleMinutes: 15))
        #expect(c.language == "ru")
        #expect(c.explanationLevel == "engineer")
        #expect(c.windowCapDays == 7)
        #expect(c.announceLagDays == 4)
        #expect(c.includeReversions == false)
        #expect(c.promptPins.isEmpty)
        #expect(c.sources == Config.Sources(openalex: true, hfPapers: true))
        #expect(c.openalexSubfields == ["1702", "1707", "2608", "2613"])
        #expect(c.openalexMaxPerRun == 1000 && c.hfTopK == 10)
        #expect(c.interestProfile.hasPrefix("ML engineer. Reads eagerly:"))
        #expect(c.interestProfile.hasSuffix("surveys, position papers."))
    }

    @Test func snakeCaseRoundTrip() throws {
        var c = Config()
        c.topN = 3
        c.promptPins = ["triage": 1]
        c.schedule.idleMinutes = 30
        c.includeReversions = true
        let data = try JSONEncoder().encode(c)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["interest_profile", "top_n", "min_score", "daily_budget_usd", "explanation_level", "window_cap_days", "announce_lag_days", "include_reversions", "prompt_pins"] {
            #expect(object[key] != nil, "missing \(key)")
        }
        let schedule = try #require(object["schedule"] as? [String: Any])
        #expect(schedule["idle_minutes"] as? Int == 30)
        #expect(try JSONDecoder().decode(Config.self, from: data) == c)
    }

    @Test func partialFileAndUnknownKeys() throws {
        let json = #"{"top_n": 5, "schedule": {"window_end": 8}, "models": {"triage": "x"}, "future_key": [1,2], "language": "en"}"#
        let c = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        #expect(c.topN == 5)
        #expect(c.schedule.windowEnd == 8)
        #expect(c.schedule.windowStart == 3)
        #expect(c.models.triage == "x")
        #expect(c.models.digest == "claude-opus-5-5")
        #expect(c.language == "en")
        #expect(c.minScore == 6)
    }

    @Test func loadFromHome() throws {
        let home = try TestSupport.tempDirectory()
        #expect(try Config.load(home: home) == Config())
        try Data(#"{"min_score": 8}"#.utf8).write(to: home.appendingPathComponent("config.json"))
        #expect(try Config.load(home: home).minScore == 8)
        try Data("not json".utf8).write(to: home.appendingPathComponent("config.json"))
        #expect(throws: ConfigError.self) { try Config.load(home: home) }
    }

    @Test func brainmaxxingHomeOverride() {
        let custom = AppPaths.resolve(environment: ["BRAINMAXXING_HOME": "/tmp/bm-home"])
        #expect(custom.home.path == "/tmp/bm-home")
        #expect(custom.database.path == "/tmp/bm-home/digest.sqlite")
        let standard = AppPaths.resolve(environment: [:])
        #expect(standard.home.path.hasSuffix("Library/Application Support/brainmaxxing"))
        #expect(AppPaths.resolve(environment: ["BRAINMAXXING_HOME": ""]) == standard)
    }

    @Test func localDateUsesCalendarTimeZoneNotUTC() throws {
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = try #require(TimeZone(identifier: "Asia/Tokyo"))
        // Local midnight in Tokyo is 15:00 UTC the previous day; `.iso8601` would print the UTC date.
        let day = tokyo.startOfDay(for: try TestSupport.date("2026-10-21T03:00:00Z"))
        #expect(day.formatted(.iso8601.year().month().day()) == "2026-10-20")
        #expect(LocalDate.string(day, calendar: tokyo) == "2026-10-21")
        var la = Calendar(identifier: .gregorian)
        la.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        #expect(LocalDate.string(try TestSupport.date("2026-10-21T03:00:00Z"), calendar: la) == "2026-10-20")
    }
}
