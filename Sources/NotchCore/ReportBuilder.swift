import Foundation

// The habit report's data, built in Swift so StudyNotch needs no Python.
// A line-by-line port of summarise() in scripts/study_report.py: same keys, same rules, same rounding,
// so the one HTML template (Resources/report_template.html) draws either. ReportBuilderTests checks
// the two agree on the same data.
//
// build(store:) reads subjects.json, categories.json and study_sessions.csv from the store's folder.
// forSharing: true leaves out the raw session rows: a shared page shows habits and totals, not
// when each session started and stopped.

public enum ReportBuilder {
    // Same constants as the Python script (STUDY_GOAL_* environment variables override the goals)
    static let days = 14
    static let quickMin = 1.0
    static let heatWeeks = 26
    static var dailyGoal: Double { env("STUDY_GOAL_MIN", 100) }

    static func env(_ key: String, _ fallback: Double) -> Double {
        Double(ProcessInfo.processInfo.environment[key] ?? "") ?? fallback
    }

    struct Row {
        let subject: String, category: String, detail: String
        let planned: Double, actual: Double
        let start: Date, end: Date
        let done: Bool
    }

    // MARK: - Formatting helpers (English names, like Python's strftime with the C locale)

    nonisolated(unsafe) static var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        c.firstWeekday = 2
        return c
    }()

    static func fmt(_ pattern: String, _ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = calendar.timeZone
        f.dateFormat = pattern
        return f.string(from: d)
    }

    static func day(_ d: Date) -> Date { calendar.startOfDay(for: d) }
    static func add(_ n: Int, to d: Date) -> Date { calendar.date(byAdding: .day, value: n, to: d)! }
    // Python round(x, 1) rounds the exact binary value (19.35 is really 19.3500000000000014 → 19.4).
    // "%.1f" does the same; multiplying by 10 first would not.
    static func r1(_ x: Double) -> Double { Double(String(format: "%.1f", x)) ?? x }
    // Python 3.12+ sum() of floats uses Neumaier compensated summation; a plain reduce can land on the
    // other side of a .x5 and round differently (19.35 vs 19.3499…). Same algorithm here, for identical output.
    static func pysum<S: Sequence>(_ xs: S) -> Double where S.Element == Double {
        var s = 0.0, c = 0.0
        for x in xs {
            let t = s + x
            c += abs(s) >= abs(x) ? (s - t) + x : (x - t) + s
            s = t
        }
        return s + c
    }

    static func weekOf(_ today: Date) -> [Date] {
        let wd = (calendar.component(.weekday, from: today) + 5) % 7   // Monday = 0
        let monday = add(-wd, to: today)
        return (0..<7).map { add($0, to: monday) }
    }

    // MARK: - Categories (built-in four, then the user's own)

    struct Cat { let key: String, label: String, goal: Double, color: String? }

    static func categories(custom: [CustomCategory]) -> [Cat] {
        [Cat(key: "academic", label: "Academic", goal: dailyGoal, color: nil),
         Cat(key: "health", label: "Health", goal: env("STUDY_GOAL_HEALTH", 30), color: nil),
         Cat(key: "soul", label: "Soul", goal: env("STUDY_GOAL_SOUL", 25), color: nil),
         Cat(key: "personal", label: "Personal", goal: env("STUDY_GOAL_PERSONAL", 30), color: nil)]
        + custom.map { Cat(key: $0.key, label: $0.label, goal: env("STUDY_GOAL_DEFAULT", 30), color: $0.color) }
    }

    // MARK: - Load

    static func loadRows(_ store: StudyStore, subjects: [Subject], catKeys: Set<String>) -> [Row] {
        guard let text = try? String(contentsOf: store.sessionsURL, encoding: .utf8) else { return [] }
        let lines = text.split(separator: "\n").map(String.init)
        guard let header = lines.first else { return [] }
        let names = StudyStore.parseCSVLine(header)
        let col = { (n: String) in names.firstIndex(of: n) }
        let iso = ISO8601DateFormatter()
        let fallback = Dictionary(subjects.map { ($0.name, $0.category.rawValue) }, uniquingKeysWith: { a, _ in a })
        var rows: [Row] = []
        for line in lines.dropFirst() where !line.isEmpty {
            let c = StudyStore.parseCSVLine(line)
            func v(_ n: String) -> String? { col(n).flatMap { $0 < c.count ? c[$0] : nil } }
            guard let subject = v("subject"), let planned = v("planned_min").flatMap(Double.init),
                  let actual = v("actual_min").flatMap(Double.init),
                  let start = v("started_at").flatMap(iso.date(from:)), let end = v("ended_at").flatMap(iso.date(from:)) else { continue }
            // The row's own category wins; old rows look it up; unknown names were study
            var cat = (v("category").flatMap { $0.isEmpty ? nil : $0 } ?? fallback[subject] ?? "academic")
                .trimmingCharacters(in: .whitespaces)
            if !catKeys.contains(cat) { cat = "academic" }
            rows.append(Row(subject: subject, category: cat, detail: (v("detail") ?? "").trimmingCharacters(in: .whitespaces),
                            planned: planned, actual: actual, start: start, end: end, done: v("completed") == "1"))
        }
        return rows
    }

    // MARK: - Habits

    struct Card { var json: [String: Any]; let done: Set<Date> }

    static func habitCard(name: String, category: String, mine: [Row], today: Date, target: Double,
                          options: [String] = [], studiedCounts: Bool = false, needsAll: Bool = true) -> Card {
        var mins: [Date: Double] = [:], finished: [Date: Set<String>] = [:]
        for r in mine {
            let d = day(r.start)
            mins[d, default: 0] += r.actual
            if r.done { finished[d, default: []].insert(r.detail) }
        }
        let opts = Set(options)
        var done: Set<Date>, partial: Set<Date>
        if !options.isEmpty && !needsAll {
            done = Set(finished.filter { !$0.value.isDisjoint(with: opts) }.keys)
            partial = Set(mins.filter { $0.value >= quickMin }.keys).subtracting(done)
        } else if !options.isEmpty {
            done = Set(finished.filter { opts.isSubset(of: $0.value) }.keys)
            partial = Set(finished.filter { !$0.value.isDisjoint(with: opts) }.keys).subtracting(done)
        } else if studiedCounts {
            done = Set(mins.filter { $0.value >= quickMin }.keys).union(finished.keys)
            partial = []
        } else {
            done = Set(finished.keys)
            partial = Set(mins.filter { $0.value >= quickMin }.keys).subtracting(done)
        }
        var streak = 0, d = done.contains(today) ? today : add(-1, to: today)
        while done.contains(d) { streak += 1; d = add(-1, to: d) }
        let week = weekOf(today), prev = week.map { add(-7, to: $0) }
        func dayJSON(_ x: Date) -> [String: Any] {
            ["wd": fmt("EEE", x), "d": fmt("EEE dd MMM", x), "m": r1(mins[x] ?? 0),
             "n": options.isEmpty ? NSNull() : (finished[x] ?? []).intersection(opts).count as Any,
             "future": x > today, "today": x == today,
             "s": done.contains(x) ? 2 : (partial.contains(x) ? 1 : 0)]
        }
        return Card(json: [
            "name": name, "category": category, "target": target,
            "today": r1(mins[today] ?? 0), "streak": streak,
            "weekDone": week.filter(done.contains).count,
            "weekMin": r1(pysum(week.map { mins[$0] ?? 0 })),
            "options": options, "needsAll": needsAll,
            "todayOptions": options.filter { (finished[today] ?? []).contains($0) },
            "days": week.map(dayJSON), "prevDays": prev.map(dayJSON),
            "prevDone": prev.filter(done.contains).count,
            "prevMin": r1(pysum(prev.map { mins[$0] ?? 0 })),
        ], done: done)
    }

    static func habits(_ rows: [Row], subjects: [Subject], cats: [Cat], today: Date) -> [Card] {
        let weekStart = weekOf(today)[0]
        let info = Dictionary(subjects.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let habitCats = Set(cats.map(\.key)).subtracting(["academic"])
        let out = [habitCard(name: "Study", category: "academic", mine: rows.filter { $0.category == "academic" },
                             today: today, target: dailyGoal, studiedCounts: true)]
        var names = subjects.map(\.name)
        names += Set(rows.filter { day($0.start) >= weekStart }.map(\.subject)).subtracting(names).sorted()
        var cards: [Card] = []
        for name in names {
            let mine = rows.filter { $0.subject == name }
            let latest = mine.max { $0.start < $1.start }
            let entry = info[name]
            let cat = entry?.category.rawValue ?? latest?.category ?? "academic"
            guard habitCats.contains(cat) else { continue }
            if entry?.isHabit == false { continue }   // time only (toilet, coffee)
            let target = entry?.minutes ?? latest?.planned ?? 25
            let needsAll = entry?.needsAll ?? Subject.defaultNeedsAll(for: name)
            cards.append(habitCard(name: name, category: cat, mine: mine, today: today, target: target,
                                   options: entry?.options ?? [], needsAll: needsAll))
        }
        let order = Dictionary(uniqueKeysWithValues: cats.enumerated().map { ($1.key, $0) })
        // stable sort: keeps the list order inside a category
        let sorted = cards.enumerated().sorted { a, b in
            let oa = order[a.element.json["category"] as! String] ?? 99, ob = order[b.element.json["category"] as! String] ?? 99
            return oa != ob ? oa < ob : a.offset < b.offset
        }.map(\.element)
        return out + sorted
    }

    static func heat(_ cards: [Card], today: Date) -> [String: Any] {
        let sets = cards.map(\.done), total = sets.count
        let end = weekOf(today)[6]
        let days = (0..<(heatWeeks * 7)).reversed().map { add(-$0, to: end) }
        var counts: [Date: Int] = [:]
        for d in days where d <= today { counts[d] = sets.filter { $0.contains(d) }.count }
        let perfect = Set(counts.filter { total > 0 && $0.value == total }.keys)
        var streak = 0, d = perfect.contains(today) ? today : add(-1, to: today)
        while perfect.contains(d) { streak += 1; d = add(-1, to: d) }
        var best = 0, run = 0
        for d in days { run = perfect.contains(d) ? run + 1 : 0; best = max(best, run) }
        return ["total": total, "perfect": perfect.count, "streak": streak, "best": best,
                "days": days.map { d -> [String: Any] in
                    ["d": fmt("EEE dd MMM", d), "m": fmt("MMM", d),
                     "first": calendar.component(.day, from: d) <= 7 && calendar.component(.weekday, from: d) == 2,
                     "n": counts[d].map { $0 as Any } ?? NSNull(), "today": d == today] }]
    }

    // MARK: - Summary

    static func build(store: StudyStore, forSharing: Bool = false, now: Date = Date()) -> [String: Any] {
        let subjects = store.loadSubjects()
        let custom = store.loadCategories()
        let cats = categories(custom: custom)
        let rows = loadRows(store, subjects: subjects, catKeys: Set(cats.map(\.key)))
        let today = day(now)
        let dayList = (0..<days).reversed().map { add(-$0, to: today) }

        var subjectOrder: [String] = []
        for r in rows where !subjectOrder.contains(r.subject) { subjectOrder.append(r.subject) }
        var perDay: [Date: [String: Double]] = [:], perDayCat: [Date: [String: Double]] = [:]
        var perSubject: [String: (min: Double, done: Int, stopped: Int)] = [:]
        var subjectCat: [String: String] = [:]
        for r in rows.sorted(by: { $0.start < $1.start }) { subjectCat[r.subject] = r.category }
        for r in rows {
            let d = day(r.start)
            perDay[d, default: [:]][r.subject, default: 0] += r.actual
            perDayCat[d, default: [:]][r.category, default: 0] += r.actual
            var s = perSubject[r.subject] ?? (0, 0, 0)
            s.min += r.actual
            if r.done { s.done += 1 } else if r.actual >= quickMin { s.stopped += 1 }
            perSubject[r.subject] = s
        }
        let real = rows.filter { $0.done || $0.actual >= quickMin }
        let studied = Set(real.map { day($0.start) })
        var streak = 0, d = studied.contains(today) ? today : add(-1, to: today)
        while studied.contains(d) { streak += 1; d = add(-1, to: d) }
        func window(_ a: Int, _ b: Int) -> Double { r1(pysum((a...b).map { pysum(perDay[add(-$0, to: today)].map { Array($0.values) } ?? []) })) }
        func catWindow(_ k: String, _ a: Int, _ b: Int) -> Double { r1(pysum((a...b).map { perDayCat[add(-$0, to: today)]?[k] ?? 0 })) }

        let cards = habits(rows, subjects: subjects, cats: cats, today: today)
        var subjectCategory = Dictionary(subjects.map { ($0.name, $0.category.rawValue) }, uniquingKeysWith: { a, _ in a })
        subjectCategory.merge(subjectCat) { _, new in new }

        var result: [String: Any] = [
            "subjects": subjectOrder,
            "subjectCategory": subjectCategory,
            "habits": cards.map(\.json),
            "heat": heat(cards, today: today),
            "categories": cats.map { c -> [String: Any] in
                ["key": c.key, "label": c.label, "goal": c.goal, "color": c.color.map { $0 as Any } ?? NSNull(),
                 "today": r1(perDayCat[today]?[c.key] ?? 0), "week": catWindow(c.key, 0, 6),
                 "total": r1(pysum(rows.filter { $0.category == c.key }.map(\.actual))),
                 "sessions": real.filter { $0.category == c.key }.count] },
            "days": dayList.map { d -> [String: Any] in
                ["label": fmt("dd MMM", d), "weekday": fmt("EEE", d),
                 "values": Dictionary(uniqueKeysWithValues: subjectOrder.map { ($0, r1(perDay[d]?[$0] ?? 0)) }),
                 "cats": Dictionary(uniqueKeysWithValues: cats.map { ($0.key, r1(perDayCat[d]?[$0.key] ?? 0)) })] },
            "bySubject": subjectOrder.sorted { (perSubject[$0]?.min ?? 0) > (perSubject[$1]?.min ?? 0) }.map { s -> [String: Any] in
                let p = perSubject[s]!, mine = real.filter { $0.subject == s }
                return ["subject": s, "category": subjectCat[s] ?? "academic", "min": r1(p.min), "done": p.done, "stopped": p.stopped,
                        "avg": mine.isEmpty ? 0 : r1(pysum(mine.map(\.actual)) / Double(mine.count)),
                        "last": mine.map(\.start).max().map { fmt("dd MMM", $0) } ?? "-"] },
            "totals": ["minutes": r1(pysum(rows.map(\.actual))),
                       "today": r1(pysum(perDay[today].map { Array($0.values) } ?? [])),
                       "done": rows.filter(\.done).count, "attempts": real.count, "quick": rows.count - real.count,
                       "week": window(0, 6), "lastWeek": window(7, 13), "streak": streak, "goal": dailyGoal],
            "generated": fmt("dd MMM yyyy, HH:mm", now),
        ]
        result["sessions"] = forSharing ? [] : rows.sorted { $0.start > $1.start }.map { r -> [String: Any] in
            let d = day(r.start)
            let group = d == today ? "Today" : (d == add(-1, to: today) ? "Yesterday" : fmt("EEE dd MMM", d))
            return ["subject": r.subject, "category": r.category, "detail": r.detail, "date": fmt("dd MMM", r.start),
                    "hour": calendar.component(.hour, from: r.start), "group": group,
                    "start": fmt("HH:mm", r.start), "end": fmt("HH:mm", r.end),
                    "planned": r.planned, "actual": r.actual, "done": r.done]
        }
        if forSharing { result["shared"] = true }
        return result
    }

    // For host apps: the report JSON for the data in this folder
    public static func json(dataFolder: URL, forSharing: Bool = false, now: Date = Date()) -> Data {
        json(store: StudyStore(folder: dataFolder), forSharing: forSharing, now: now)
    }

    static func json(store: StudyStore, forSharing: Bool = false, now: Date = Date()) -> Data {
        (try? JSONSerialization.data(withJSONObject: build(store: store, forSharing: forSharing, now: now), options: [.sortedKeys])) ?? Data("{}".utf8)
    }
}
