import AppKit
import SwiftUI

// Study sessions in the notch: hover the notch, pick a subject, a pomodoro starts,
// and every finished or stopped session is saved as one CSV row.
// Data (personal, git-ignored), in the folder ApexAgent is started from:
//   data/subjects.json        the subject list
//   data/study_sessions.csv   one row per session
// After a finished pomodoro, the subject's break starts by itself (breaks are not saved to the CSV).
// APEX_STUDY_MINUTES=0.2 makes every study block and break 12 seconds, for testing.

// MARK: - Storage

// The four parts of the day the notch tracks. Each activity (a "subject") belongs to one.
// Saved by its raw value in subjects.json, so the order and labels can change freely.
enum StudyCategory: String, Codable, CaseIterable, Identifiable {
    case academic, health, soul, personal

    var id: String { rawValue }

    var label: String {
        switch self {
        case .academic: return "Academic"
        case .health: return "Health"
        case .soul: return "Soul"
        case .personal: return "Personal"
        }
    }

    var icon: String {   // SF Symbols
        switch self {
        case .academic: return "book.fill"
        case .health: return "figure.walk"
        case .soul: return "moon.stars.fill"
        case .personal: return "drop.fill"
        }
    }

    // Same four colours as the web report's dark mode (checked for colour-blind separation there):
    // blue #3987e5, teal #199e70, gold #c98500, pink #d55181
    var color: Color {
        switch self {
        case .academic: return Color(red: 0x39 / 255, green: 0x87 / 255, blue: 0xe5 / 255)
        case .health: return Color(red: 0x19 / 255, green: 0x9e / 255, blue: 0x70 / 255)
        case .soul: return Color(red: 0xc9 / 255, green: 0x85 / 255, blue: 0x00 / 255)
        case .personal: return Color(red: 0xd5 / 255, green: 0x51 / 255, blue: 0x81 / 255)
        }
    }

    var next: StudyCategory {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

// One activity: its pomodoro length, break length and category. Editable from the notch (the pencil on each tile).
struct Subject: Codable, Hashable {
    var name: String
    var minutes: Double
    var breakMinutes: Double = 5
    var category: StudyCategory = .academic
    // Optional choices asked when you tap the tile, e.g. Pray → Subuh / Zohor / Asar / Maghrib / Isyak.
    // The choice is saved in the CSV's detail column. Empty = start straight away.
    var options: [String] = []
    // true: the day counts only when every option is done (the five fard prayers).
    // false: any one option done counts the day (sunnah prayers: Dhuha, Tahajjud, ...).
    var needsAll: Bool = true
    // A habit gets a card on the report's Habits page and counts toward a perfect day.
    // Off = time only (toilet, coffee): the time is still counted everywhere else.
    // Academic subjects are never habits on their own (they share the one Study card).
    var isHabit: Bool = true

    init(name: String, minutes: Double, breakMinutes: Double = 5, category: StudyCategory = .academic,
         options: [String] = [], needsAll: Bool = true, isHabit: Bool? = nil) {
        self.name = name
        self.minutes = minutes
        self.breakMinutes = breakMinutes
        self.category = category
        self.options = options
        self.needsAll = needsAll
        self.isHabit = isHabit ?? (category != .academic)
    }

    // Ready-made choices for a new activity, by name:
    //   Pray / Solat      → the five daily prayers, all needed for the day
    //   Sunnah / Nawafil  → common sunnah prayers, any one counts the day
    // Any activity's choices can be changed later in its edit view (the Choices line).
    static func defaultOptions(for name: String) -> [String] {
        switch name.lowercased() {
        case "pray", "solat", "prayer": return ["Subuh", "Zohor", "Asar", "Maghrib", "Isyak"]
        case "sunnah", "sunat", "solat sunat", "sunnah prayer", "nawafil": return ["Dhuha", "Rawatib", "Tahajjud", "Witir", "Hajat"]
        default: return []
        }
    }

    static func defaultNeedsAll(for name: String) -> Bool {
        !["sunnah", "sunat", "solat sunat", "sunnah prayer", "nawafil"].contains(name.lowercased())
    }

    // Older files: no breakMinutes means 5, no category means Academic (everything so far was study)
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        minutes = try c.decode(Double.self, forKey: .minutes)
        breakMinutes = try c.decodeIfPresent(Double.self, forKey: .breakMinutes) ?? 5
        category = (try? c.decodeIfPresent(StudyCategory.self, forKey: .category)) ?? .academic
        options = (try? c.decodeIfPresent([String].self, forKey: .options)) ?? Subject.defaultOptions(for: name)
        needsAll = (try? c.decodeIfPresent(Bool.self, forKey: .needsAll)) ?? Subject.defaultNeedsAll(for: name)
        isHabit = (try? c.decodeIfPresent(Bool.self, forKey: .isHabit)) ?? (category != .academic)
    }
}

struct StudyStore {
    let folder: URL
    var subjectsURL: URL { folder.appendingPathComponent("subjects.json") }
    var sessionsURL: URL { folder.appendingPathComponent("study_sessions.csv") }
    static let header: String = "id,subject,planned_min,actual_min,started_at,ended_at,completed,category,detail\n"
    static let headerBeforeCategories: String = "id,subject,planned_min,actual_min,started_at,ended_at,completed"
    static let headerBeforeDetail: String = "id,subject,planned_min,actual_min,started_at,ended_at,completed,category"

    init() {
        folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("data")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func loadSubjects() -> [Subject] {
        guard let data = try? Data(contentsOf: subjectsURL) else {
            return ["Swift", "SQL", "PSM"].map { Subject(name: $0, minutes: 25) }   // first run
        }
        if let list = try? JSONDecoder().decode([Subject].self, from: data) { return list }
        // older file: just names, so give each the default 25 minutes
        if let names = try? JSONDecoder().decode([String].self, from: data) { return names.map { Subject(name: $0, minutes: 25) } }
        return []
    }

    func saveSubjects(_ list: [Subject]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(list) { try? data.write(to: subjectsURL) }
    }

    // Quotes around the subject so a comma in a name cannot break the columns
    // The category is stored on the row, so moving an activity to another tab later does not rewrite its history
    // detail = the option chosen for this session (which prayer), empty when the activity has none
    func appendSession(subject: String, category: StudyCategory, detail: String?, plannedMin: Double, actualMin: Double,
                       startedAt: Date, endedAt: Date, completed: Bool) {
        let iso = ISO8601DateFormatter()
        iso.timeZone = .current
        let quote = { (s: String) in "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        let row: String = [UUID().uuidString, quote(subject), String(format: "%.1f", plannedMin), String(format: "%.1f", actualMin),
                           iso.string(from: startedAt), iso.string(from: endedAt), completed ? "1" : "0", category.rawValue,
                           detail.map(quote) ?? ""]
            .joined(separator: ",") + "\n"
        if !FileManager.default.fileExists(atPath: sessionsURL.path) {
            try? Self.header.data(using: .utf8)?.write(to: sessionsURL)
        }
        guard let handle = try? FileHandle(forWritingTo: sessionsURL), let bytes = row.data(using: .utf8) else { return }
        handle.seekToEndOfFile()
        handle.write(bytes)
        try? handle.close()
    }

    // Minutes studied today per subject, read back from the CSV (the CSV is the single source of truth)
    func todayMinutes() -> [String: Double] {
        guard let text = try? String(contentsOf: sessionsURL, encoding: .utf8) else { return [:] }
        let iso = ISO8601DateFormatter()
        var totals: [String: Double] = [:]
        for line in text.split(separator: "\n").dropFirst() {
            let cols = Self.parseCSVLine(String(line))
            guard cols.count >= 7, let minutes = Double(cols[3]), let started = iso.date(from: cols[4]) else { continue }
            if Calendar.current.isDateInToday(started) { totals[cols[1], default: 0] += minutes }
        }
        return totals
    }

    // One-time upgrade of a CSV written before categories existed: copy it to a backup, then add a
    // category column to every row, taken from the activity list as it is now (names no longer in
    // the list, e.g. renamed ones, become academic: everything before categories was study).
    // Does nothing once the header has the column, so it is safe to run on every start.
    func upgradeSessionsIfNeeded(categoryOf: (String) -> StudyCategory) {
        guard let text = try? String(contentsOf: sessionsURL, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n").map(String.init)
        guard let first = lines.first?.trimmingCharacters(in: .whitespaces) else { return }
        // Already has categories, only the detail column is new: rewrite the header line. Old rows simply
        // have no detail (readers treat a missing last column as empty), so they stay as they are.
        if first == Self.headerBeforeDetail {
            let rest = text.drop(while: { $0 != "\n" })
            do {
                try (Self.header.dropLast() + rest).write(to: sessionsURL, atomically: true, encoding: .utf8)
                print("📚 study CSV upgraded: added a detail column")
            } catch {
                print("📚 study CSV upgrade failed: \(error.localizedDescription)")
            }
            return
        }
        guard first == Self.headerBeforeCategories else { return }
        let backup = folder.appendingPathComponent("study_sessions.before-categories.csv")
        if !FileManager.default.fileExists(atPath: backup.path) {
            do { try FileManager.default.copyItem(at: sessionsURL, to: backup) }
            catch { print("📚 study CSV upgrade skipped: could not make a backup (\(error.localizedDescription))"); return }
        }
        var out: String = Self.header
        for line in lines.dropFirst() where !line.isEmpty {
            let cols = Self.parseCSVLine(line)
            out += line + "," + (cols.count >= 2 ? categoryOf(cols[1]) : .academic).rawValue + "\n"
        }
        do {
            try out.write(to: sessionsURL, atomically: true, encoding: .utf8)
            print("📚 study CSV upgraded: added a category column to \(lines.count - 1) rows (backup: \(backup.lastPathComponent))")
        } catch {
            print("📚 study CSV upgrade failed: \(error.localizedDescription)")
        }
    }

    // "name|detail" for every option finished today (Pray|Subuh ...), to tick them in the picker
    func todayDoneDetails() -> Set<String> {
        guard let text = try? String(contentsOf: sessionsURL, encoding: .utf8) else { return [] }
        let iso = ISO8601DateFormatter()
        var done: Set<String> = []
        for line in text.split(separator: "\n").dropFirst() {
            let cols = Self.parseCSVLine(String(line))
            guard cols.count >= 9, !cols[8].isEmpty, cols[6] == "1", let started = iso.date(from: cols[4]),
                  Calendar.current.isDateInToday(started) else { continue }
            done.insert(cols[1] + "|" + cols[8])
        }
        return done
    }

    static func parseCSVLine(_ line: String) -> [String] {
        var out: [String] = []
        var field: String = ""
        var quoted: Bool = false
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if quoted {
                if c == "\"" && i + 1 < chars.count && chars[i + 1] == "\"" { field.append("\""); i += 1 }
                else if c == "\"" { quoted = false }
                else { field.append(c) }
            } else if c == "\"" { quoted = true }
            else if c == "," { out.append(field); field = "" }
            else { field.append(c) }
            i += 1
        }
        out.append(field)
        return out
    }
}

// MARK: - Model

@MainActor
final class StudyModel: ObservableObject {
    @Published var subjects: [Subject]
    @Published var todayMinutes: [String: Double]
    @Published var adding: Bool = false
    @Published var newName: String = ""
    // Editing a subject: which one, and the values in the edit boxes
    @Published var editing: String? = nil
    @Published var editName: String = ""
    @Published var editMinutes: String = ""
    @Published var editBreak: String = ""
    @Published var editCategory: StudyCategory = .academic
    @Published var editOptions: String = ""        // "Dhuha, Tahajjud, Witir": the choices, comma separated
    @Published var editIsHabit: Bool = true         // off = time only (toilet, coffee)
    // The category tab open in the picker; new activities go into it
    @Published var category: StudyCategory = .academic
    // The break after a finished pomodoro: whose break it is, and a short "break over" notice
    @Published var breakFor: String? = nil
    @Published var breakOver: Bool = false
    // The running session
    @Published var subject: String? = nil
    @Published var detail: String? = nil          // the option picked for the running session (which prayer)
    @Published var choosing: Subject? = nil       // tapped an activity with options: the picker asks which one
    @Published var todayDone: Set<String> = []    // "Pray|Subuh" etc. finished today
    @Published var choosingTick: Bool = false      // the choice came from ✓ (log it) rather than a tap (start the timer)
    @Published var remaining: TimeInterval = 0
    @Published var paused: Bool = false
    @Published var justFinished: String? = nil

    // APEX_STUDY_MINUTES (testing) overrides every subject's length
    let testMinutes: Double? = Double(ProcessInfo.processInfo.environment["APEX_STUDY_MINUTES"] ?? "")
    private(set) var plannedMinutes: Double = 25   // length of the running session
    let store = StudyStore()
    // Set by the notch window: typing a new subject needs the keyboard
    var onNeedKeyboard: (() -> Void)?
    private var endDate: Date? = nil
    private var startedAt: Date? = nil
    private var tick: Timer? = nil

    init() {
        let loaded = store.loadSubjects()
        subjects = loaded
        store.upgradeSessionsIfNeeded { name in loaded.first { $0.name == name }?.category ?? .academic }
        todayMinutes = store.todayMinutes()
        todayDone = store.todayDoneDetails()
        store.saveSubjects(subjects)
    }

    var running: Bool { subject != nil }
    var resting: Bool { breakFor != nil }
    var showsStatus: Bool { running || resting || justFinished != nil || breakOver }
    // Typing in the + or edit box: keep the notch open even if the mouse wanders off
    var typing: Bool { adding || editing != nil }

    // Tiles shown under the open category tab
    var visibleSubjects: [Subject] { subjects.filter { $0.category == category } }

    // Category of the running (or just-finished / resting) activity, for the status row icon
    func categoryOf(_ name: String) -> StudyCategory {
        subjects.first { $0.name == name }?.category ?? .academic
    }

    var clock: String {
        let s = Int(remaining.rounded(.up))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    // How close the running pomodoro is to its end: drives the clock pill's colour.
    // soon = last 20%, final = last minute (or last 10% of a short test session). Breaks stay calm.
    var urgency: TimerUrgency {
        guard running, !paused else { return .calm }
        let total = plannedMinutes * 60
        if remaining <= min(60, total * 0.1) { return .final }
        if remaining <= total * 0.2 { return .soon }
        return .calm
    }

    func doneToday(_ name: String, _ option: String) -> Bool { todayDone.contains(name + "|" + option) }

    func timeLabel(_ subject: String) -> String {
        let m = todayMinutes[subject] ?? 0
        return m < 60 ? "\(Int(m.rounded()))m" : String(format: "%.1fh", m / 60)
    }

    // "Pray · Asar" while a session with a chosen option runs, otherwise just the name
    var subjectLabel: String? {
        guard let name = subject else { return nil }
        return detail.map { "\(name) · \($0)" } ?? name
    }

    // The ✓ on a habit tile: "I already did it" without running the timer (a walk done away from the Mac).
    // Activities with choices ask which one first (Pray → Asar), then log it the same way.
    func tick(_ item: Subject) {
        if item.options.isEmpty { checkIn(item) } else { choosing = item; choosingTick = true }
    }

    // Logs a finished session of the activity's full length, ending now, as if the timer ran.
    // No break, no sound loop: just saved, a short "✓" in the notch, and the report rebuilt.
    func checkIn(_ item: Subject, detail chosen: String? = nil) {
        choosing = nil
        choosingTick = false
        let end = Date()
        store.appendSession(subject: item.name, category: item.category, detail: chosen, plannedMin: item.minutes,
                            actualMin: item.minutes, startedAt: end.addingTimeInterval(-item.minutes * 60), endedAt: end, completed: true)
        todayMinutes = store.todayMinutes()
        todayDone = store.todayDoneDetails()
        let label: String = chosen.map { "\(item.name) · \($0)" } ?? item.name
        print("📚 checked in: \(label), \(Int(item.minutes)) min")
        NSSound(named: "Glass")?.play()
        if !running && !resting {
            justFinished = label
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                MainActor.assumeIsolated { if self.justFinished == label { self.justFinished = nil } }
            }
        }
        reportSoon()
    }

    // Tapping a tile: activities with options ask first (Pray → which prayer), the rest start now
    func tap(_ item: Subject) {
        choosingTick = false
        if item.options.isEmpty { start(item) } else { choosing = item }
    }

    func start(_ item: Subject, detail chosen: String? = nil) {
        choosing = nil
        if running { stop(completed: false) }
        if resting { endBreak(finished: false) }   // starting a subject ends the break early
        breakOver = false
        plannedMinutes = testMinutes ?? item.minutes
        let name: String = item.name
        subject = name
        detail = chosen
        startedAt = Date()
        remaining = plannedMinutes * 60
        endDate = Date().addingTimeInterval(remaining)
        paused = false
        justFinished = nil
        tick?.invalidate()
        tick = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated { self.update() }
        }
        print("📚 study started: \(subjectLabel ?? name), \(plannedMinutes) min")
    }

    // Uses the end time, not a counter, so the clock stays right even if the Mac is busy
    private func update() {
        guard running || resting, !paused, let end = endDate else { return }
        remaining = max(0, end.timeIntervalSinceNow)
        if remaining <= 0 {
            if resting { endBreak(finished: true) } else { stop(completed: true) }
        }
    }

    func togglePause() {
        guard running || resting else { return }
        if paused {
            endDate = Date().addingTimeInterval(remaining)
            paused = false
        } else {
            paused = true
        }
    }

    // Publish the study report online after a session (opt-in: APEX_STUDY_UPLOAD=1).
    // Runs scripts/study_report.py --upload, which needs STUDY_BUCKET / STUDY_DIST_ID / STUDY_URL
    // in the environment, so start ApexAgent from a terminal that loaded ~/.zshrc.
    // Serial background queue: the notch never waits, and two quick stops upload one after another.
    // Offline is fine: the upload fails, gets logged, and the next one sends the whole report again.
    private let uploadQueue = DispatchQueue(label: "study.upload")

    // Rebuilds data/study_report.html, and uploads it too when APEX_STUDY_UPLOAD=1.
    // Without the upload setting it still rebuilds the local file, so the page on disk is never stale.
    private func uploadReport() {
        let upload: Bool = ProcessInfo.processInfo.environment["APEX_STUDY_UPLOAD"] == "1"
        uploadQueue.async {
            let args = ["python3", "scripts/study_report.py", "--no-open"] + (upload ? ["--upload"] : [])
            let out = runShell("/usr/bin/env", args: args)
            let last = out.split(separator: "\n").last.map(String.init) ?? "(no output)"
            if !upload { print("📄 report rebuilt locally: \(last)") }
            else { print(last.hasPrefix("Live at") ? "☁️ report: \(last)" : "☁️ report upload failed: \(last)") }
        }
    }

    // After adding, editing or removing an activity: rebuild the report so new names, categories,
    // lengths and prayer choices show up. Waits 3 s so a burst of edits makes one upload, not five.
    private var pendingReport: DispatchWorkItem?

    private func reportSoon() {
        pendingReport?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.uploadReport() } }
        pendingReport = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    func stop(completed: Bool) {
        guard let name = subject, let began = startedAt else { return }
        tick?.invalidate()
        let studiedMin: Double = completed ? plannedMinutes : (plannedMinutes * 60 - remaining) / 60
        store.appendSession(subject: name, category: categoryOf(name), detail: detail, plannedMin: plannedMinutes, actualMin: studiedMin,
                            startedAt: began, endedAt: Date(), completed: completed)
        if studiedMin >= 1 { uploadReport() }   // quick taps don't change the report enough to upload
        todayMinutes = store.todayMinutes()
        todayDone = store.todayDoneDetails()
        let label: String = subjectLabel ?? name
        print("📚 study \(completed ? "finished" : "stopped"): \(label), \(String(format: "%.1f", studiedMin)) min saved")
        subject = nil
        detail = nil
        startedAt = nil
        endDate = nil
        paused = false
        if completed {
            NSSound(named: "Glass")?.play()
            let breakLength: Double = testMinutes ?? (subjects.first { $0.name == name }?.breakMinutes ?? 5)
            if breakLength > 0 {
                startBreak(for: name, minutes: breakLength)
            } else {
                justFinished = label   // "Pray · Asar ✓"
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                    MainActor.assumeIsolated { if self.justFinished == label { self.justFinished = nil } }
                }
            }
        }
    }

    private func startBreak(for name: String, minutes: Double) {
        breakFor = name
        breakOver = false
        remaining = minutes * 60
        endDate = Date().addingTimeInterval(remaining)
        paused = false
        tick?.invalidate()
        tick = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated { self.update() }
        }
        print("☕ break started after \(name): \(minutes) min")
    }

    // finished = the break ran out (sound + "break over" notice); false = skipped or replaced by a new session
    func endBreak(finished: Bool) {
        guard resting else { return }
        tick?.invalidate()
        breakFor = nil
        endDate = nil
        paused = false
        print("☕ break \(finished ? "over" : "skipped")")
        if finished {
            NSSound(named: "Hero")?.play()
            breakOver = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                MainActor.assumeIsolated { self.breakOver = false }
            }
        }
    }

    func beginAdding() {
        editing = nil
        adding = true
        onNeedKeyboard?()
    }

    func addSubject() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty && !subjects.contains(where: { $0.name.lowercased() == name.lowercased() }) {
            let clean = String(name.prefix(maxSubjectNameLength))
            subjects.append(Subject(name: clean, minutes: 25, category: category, options: Subject.defaultOptions(for: clean),
                                    needsAll: Subject.defaultNeedsAll(for: clean)))
            store.saveSubjects(subjects)
            reportSoon()   // the web report shows the change too
        }
        newName = ""
        adding = false
    }

    func beginEditing(_ item: Subject) {
        adding = false
        editing = item.name
        editName = item.name
        editMinutes = String(Int(item.minutes))
        editBreak = String(Int(item.breakMinutes))
        editCategory = item.category
        editOptions = item.options.joined(separator: ", ")
        editIsHabit = item.isHabit
        onNeedKeyboard?()
    }

    // Study: 1 to 180 min, -/+ in steps of 5. Break: 0 (no break) to 60 min, -/+ in steps of 1.
    func nudgeMinutes(_ delta: Int) {
        let current: Int = Int(editMinutes) ?? 25
        let stepped: Int = delta > 0 ? (current / 5 + 1) * 5 : ((current - 1) / 5) * 5
        editMinutes = String(max(1, min(180, stepped)))
    }

    func nudgeBreak(_ delta: Int) {
        let current: Int = Int(editBreak) ?? 5
        editBreak = String(max(0, min(60, current + delta)))
    }

    // Renaming keeps old CSV rows under the old name: the history is not rewritten
    func saveEdit() {
        guard let original = editing, let index = subjects.firstIndex(where: { $0.name == original }) else { cancelEdit(); return }
        let name = String(editName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxSubjectNameLength))
        let clash: Bool = subjects.contains { $0.name.lowercased() == name.lowercased() && $0.name != original }
        if !name.isEmpty && !clash { subjects[index].name = name }
        if let minutes = Int(editMinutes.trimmingCharacters(in: .whitespaces)) {
            subjects[index].minutes = Double(max(1, min(180, minutes)))
        }
        if let rest = Int(editBreak.trimmingCharacters(in: .whitespaces)) {
            subjects[index].breakMinutes = Double(max(0, min(60, rest)))
        }
        subjects[index].category = editCategory
        subjects[index].isHabit = editCategory != .academic && editIsHabit
        // Choices: comma separated, blanks and repeats dropped, at most 8 so they fit on one row
        var seen: Set<String> = []
        subjects[index].options = editOptions.split(separator: ",")
            .map { String($0.trimmingCharacters(in: .whitespaces).prefix(14)) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
            .prefix(8).map { $0 }
        category = editCategory   // follow the activity to its new tab
        store.saveSubjects(subjects)
        reportSoon()   // the web report shows the change too
        cancelEdit()
    }

    func cancelEdit() {
        editing = nil
        editName = ""
        editMinutes = ""
        editBreak = ""
        editOptions = ""
    }

    func remove(_ name: String) {
        subjects.removeAll { $0.name == name }
        store.saveSubjects(subjects)
        reportSoon()   // the web report shows the change too
        cancelEdit()
    }
}

// MARK: - Views

// Long enough for names like "RAG LangChain Knowledge"
let maxSubjectNameLength: Int = 24

let studyGreen = Color(red: 0.25, green: 0.73, blue: 0.31)
let studyOrange = Color(red: 0.94, green: 0.53, blue: 0.24)
let studyBlue = Color(red: 0.35, green: 0.65, blue: 1.0)   // breaks
let studyRed = Color(red: 1.0, green: 0.33, blue: 0.30)    // the last minute of a pomodoro

enum TimerUrgency { case calm, soon, final }

// Soft capsule behind the subject name and the clock: tinted glass, never loud.
// strength > 1 brightens it (the final minute breathes with this).
struct SoftPill: ViewModifier {
    let tint: Color
    var strength: Double = 1

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(tint.opacity(0.15 * strength)))
            .overlay(Capsule().strokeBorder(tint.opacity(0.28 * strength), lineWidth: 0.75))
    }
}

// The countdown: calm white, orange in the last 20%, red and breathing in the last minute
// (a faster heartbeat in the last 10 seconds). Paused = orange, break = blue.
struct TimerPill: View {
    @ObservedObject var study: StudyModel

    var body: some View {
        let urgency = study.urgency
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: urgency != .final)) { ctx in
            let speed: Double = study.remaining <= 10 ? 9 : 4.5
            let beat: Double = urgency == .final ? 0.5 + 0.5 * sin(ctx.date.timeIntervalSinceReferenceDate * speed) : 0
            Text(study.clock)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundColor(textColor(urgency))
                .modifier(SoftPill(tint: tint(urgency), strength: 1 + beat * 1.3))
                .shadow(color: studyRed.opacity(urgency == .final ? 0.55 * beat : 0), radius: 6)
                .scaleEffect(1 + 0.04 * beat)
        }
        .animation(.easeInOut(duration: 0.6), value: urgency)
    }

    private func tint(_ u: TimerUrgency) -> Color {
        if study.paused { return studyOrange }
        if study.resting { return studyBlue }
        switch u {
        case .calm: return .white
        case .soon: return studyOrange
        case .final: return studyRed
        }
    }

    private func textColor(_ u: TimerUrgency) -> Color {
        if study.paused { return studyOrange }
        if study.resting { return studyBlue }
        switch u {
        case .calm: return .white
        case .soon: return Color(red: 1.0, green: 0.72, blue: 0.45)
        case .final: return Color(red: 1.0, green: 0.55, blue: 0.52)
        }
    }
}

// Each subject gets its own colour, stable across launches (String.hashValue is random per run)
func subjectAccent(_ name: String) -> Color {
    let sum = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
    return Color(hue: Double(sum % 360) / 360, saturation: 0.6, brightness: 1.0)
}

// Every button in the notch: grows and brightens on hover, squishes on press, springs back
struct LivelyButtonStyle: ButtonStyle {
    var glow: Color = .white
    func makeBody(configuration: Configuration) -> some View {
        LivelyButton(configuration: configuration, glow: glow)
    }
    private struct LivelyButton: View {
        let configuration: ButtonStyle.Configuration
        let glow: Color
        @State private var hover = false
        var body: some View {
            configuration.label
                .brightness(hover ? 0.12 : 0)
                .scaleEffect(configuration.isPressed ? 0.88 : (hover ? 1.1 : 1.0))
                .shadow(color: glow.opacity(hover ? 0.55 : 0), radius: hover ? 7 : 0)
                .animation(.spring(response: 0.25, dampingFraction: 0.55), value: hover)
                .animation(.spring(response: 0.18, dampingFraction: 0.6), value: configuration.isPressed)
                .onHover { hover = $0 }
        }
    }
}

struct SubjectTile: View {
    let item: Subject
    let today: String
    let active: Bool
    let index: Int
    let onTap: () -> Void
    let onEdit: () -> Void
    var onTick: (() -> Void)? = nil   // the ✓ badge; habits only
    @State private var hover = false
    @State private var pressed = false
    @State private var shown = false
    @State private var spot = CGPoint(x: 42, y: 27)   // where the mouse is inside the tile

    var body: some View {
        let accent = subjectAccent(item.name)
        VStack(spacing: 1) {
            // Long names shrink to fit the tile (down to about 7 pt) instead of being cut
            Text(item.name).font(.system(size: 12, weight: .semibold, design: .rounded))
                .lineLimit(1).minimumScaleFactor(0.55)
            Text(item.breakMinutes > 0 ? "\(Int(item.minutes)) + \(Int(item.breakMinutes)) min" : "\(Int(item.minutes)) min").font(.system(size: 10, weight: .medium, design: .rounded)).foregroundColor(.white.opacity(0.75))
            HStack(spacing: 2) {
                // Time-only activities (toilet, coffee) get a small clock so they read as "not a habit"
                if !item.isHabit && item.category != .academic {
                    Image(systemName: "clock").font(.system(size: 7.5, weight: .semibold))
                }
                Text("\(today) today").font(.system(size: 9, weight: .medium, design: .rounded))
            }
            .foregroundColor(.white.opacity(0.45))
        }
        .foregroundColor(.white)
        .padding(.horizontal, 4)
        .frame(width: 84, height: 54)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 9).fill(active ? studyGreen.opacity(0.35) : Color.white.opacity(hover ? 0.14 : 0.10))
                // Spotlight that follows the mouse, in the subject's colour
                if hover {
                    RadialGradient(colors: [accent.opacity(0.55), .clear], center: .init(x: spot.x / 84, y: spot.y / 54),
                                   startRadius: 0, endRadius: 46)
                        .transition(.opacity)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 9))
        )
        // Rim: green when running, a light edge in the subject's colour on hover
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(active ? AnyShapeStyle(studyGreen)
                               : AnyShapeStyle(LinearGradient(colors: [accent.opacity(hover ? 0.95 : 0), .white.opacity(hover ? 0.35 : 0)],
                                                              startPoint: .top, endPoint: .bottom)),
                        lineWidth: hover || active ? 1.5 : 0)
        )
        .overlay(alignment: .topTrailing) {
            if hover {
                Button(action: onEdit) {
                    Image(systemName: "pencil").font(.system(size: 9, weight: .bold)).foregroundColor(.white)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(accent.opacity(0.85)))
                }
                .buttonStyle(LivelyButtonStyle(glow: accent))
                .offset(x: 4, y: -4)
                .transition(.scale(scale: 0.2).combined(with: .opacity))
            }
        }
        // ✓ on habit tiles (not study): "already did it", logs it without running the timer
        .overlay(alignment: .topLeading) {
            if hover, let onTick, item.category != .academic {
                Button(action: onTick) {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundColor(.white)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(item.category.color))
                }
                .buttonStyle(LivelyButtonStyle(glow: item.category.color))
                .help("Done already: log it without the timer")
                .offset(x: -4, y: -4)
                .transition(.scale(scale: 0.2).combined(with: .opacity))
            }
        }
        // Lift toward you on hover, sink on press, glow in the subject's colour
        .scaleEffect(pressed ? 0.94 : (hover ? 1.07 : 1.0))
        .offset(y: hover && !pressed ? -2 : 0)
        .shadow(color: accent.opacity(hover ? 0.5 : 0), radius: hover ? 9 : 0, y: hover ? 3 : 0)
        // Tiles drop in one after another when the menu opens
        .opacity(shown ? 1 : 0)
        .offset(y: shown ? 0 : -10)
        .animation(.spring(response: 0.28, dampingFraction: 0.6), value: hover)
        .animation(.spring(response: 0.18, dampingFraction: 0.6), value: pressed)
        .onAppear {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7).delay(Double(index) * 0.045)) { shown = true }
        }
        .onContinuousHover { phase in
            switch phase {
            case .active(let p): hover = true; spot = p
            case .ended: hover = false; pressed = false
            }
        }
        // Tap: a quick squish, then start. (A press-tracking drag gesture here swallowed the tap.)
        .onTapGesture {
            pressed = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { pressed = false }
            onTap()
        }
    }
}

// The row beside the camera while a session runs: "● Swift ........ 24:58"
struct StudyStatusRow: View {
    @ObservedObject var study: StudyModel
    let sides: (left: CGFloat, right: CGFloat)   // the left grows with the subject name
    let notchWidth: CGFloat
    let notchHeight: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if let name = study.subject, let label = study.subjectLabel {
                    HStack(spacing: 5) {
                        // The activity's category icon (book, walker, moon, drop); orange while paused
                        Image(systemName: study.categoryOf(name).icon)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(study.paused ? studyOrange : study.categoryOf(name).color)
                            .frame(width: 12)
                        Text(label).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundColor(.white).lineLimit(1)
                    }
                    .modifier(SoftPill(tint: study.paused ? studyOrange : subjectAccent(name)))   // the subject's own tile colour
                } else if study.resting {
                    HStack(spacing: 5) {
                        Image(systemName: "cup.and.saucer.fill").foregroundColor(study.paused ? studyOrange : studyBlue).font(.system(size: 11))
                        Text("Break").font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundColor(.white).lineLimit(1)
                    }
                    .modifier(SoftPill(tint: study.paused ? studyOrange : studyBlue))
                } else if study.breakOver {
                    HStack(spacing: 5) {
                        Image(systemName: "bell.fill").foregroundColor(studyBlue).font(.system(size: 11))
                        Text("Break over").font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundColor(.white).lineLimit(1)
                    }
                    .modifier(SoftPill(tint: studyBlue))
                } else if let done = study.justFinished {
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark.circle.fill").foregroundColor(studyGreen).font(.system(size: 12))
                        Text(done).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundColor(.white).lineLimit(1)
                    }
                    .modifier(SoftPill(tint: studyGreen))
                }
            }
            .frame(width: sides.left - 12, alignment: .leading)
            Color.clear.frame(width: notchWidth)   // the camera
            Group {
                if study.running || study.resting {
                    TimerPill(study: study)
                } else if study.breakOver {
                    Text("Pick one").font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundColor(studyBlue)
                        .modifier(SoftPill(tint: studyBlue))
                } else if study.justFinished != nil {
                    Text("Done").font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundColor(studyGreen)
                        .modifier(SoftPill(tint: studyGreen))
                }
            }
            .frame(width: sides.right - 12, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(width: sides.left + notchWidth + sides.right, height: notchHeight)
    }
}

// Below the camera when you hover: subject tiles and +, or the box to type a new subject
struct StudyPicker: View {
    @ObservedObject var study: StudyModel
    @FocusState private var nameFocused: Bool

    var body: some View {
        if study.editing != nil {
            VStack(spacing: 8) {
                // Line 1: name, then save / delete / cancel
                HStack(spacing: 8) {
                    TextField("Name", text: $study.editName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundColor(.white)
                        .padding(.horizontal, 9).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.12)))
                        .frame(width: 150)
                        .focused($nameFocused)
                        .onSubmit { study.saveEdit() }
                        .onAppear { nameFocused = true }
                    // Tap to move the activity to the next category
                    Button { study.editCategory = study.editCategory.next } label: {
                        Label(study.editCategory.label, systemImage: study.editCategory.icon)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundColor(study.editCategory.color)
                            .modifier(SoftPill(tint: study.editCategory.color))
                    }
                    .buttonStyle(LivelyButtonStyle(glow: study.editCategory.color))
                    .help("Change category")
                    pill("Save", studyGreen) { study.saveEdit() }
                    Button { if let name = study.editing { study.remove(name) } } label: {
                        Image(systemName: "trash").font(.system(size: 11, weight: .semibold)).foregroundColor(.white.opacity(0.7))
                    }.buttonStyle(.plain)
                    Button { study.cancelEdit() } label: {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundColor(.white.opacity(0.7))
                    }.buttonStyle(.plain)
                }
                // Line 2: study length and break length
                HStack(spacing: 6) {
                    Text("Study").font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(studyGreen)
                    stepButton("minus") { study.nudgeMinutes(-5) }
                    numberField("25", $study.editMinutes)
                    stepButton("plus") { study.nudgeMinutes(5) }
                    Text("min").font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(.white.opacity(0.6))
                    Spacer().frame(width: 14)
                    Text("Break").font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(studyBlue)
                    stepButton("minus") { study.nudgeBreak(-1) }
                    numberField("5", $study.editBreak)
                    stepButton("plus") { study.nudgeBreak(1) }
                    Text("min").font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(.white.opacity(0.6))
                }
                // Line 3 (habits only): the choices asked when you tap the tile, comma separated.
                // Empty = no question, the timer starts straight away.
                if study.editCategory != .academic {
                    HStack(spacing: 6) {
                        // Habit on: a card on the Habits page, counts toward a perfect day.
                        // Off: time only (toilet, coffee), still counted in every time total.
                        Button { study.editIsHabit.toggle() } label: {
                            Label(study.editIsHabit ? "Habit" : "Time only",
                                  systemImage: study.editIsHabit ? "checkmark.circle.fill" : "clock")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundColor(study.editIsHabit ? study.editCategory.color : .white.opacity(0.7))
                                .modifier(SoftPill(tint: study.editIsHabit ? study.editCategory.color : .white.opacity(0.6)))
                        }
                        .buttonStyle(LivelyButtonStyle(glow: study.editCategory.color))
                        .help("Habit: shown on the Habits page. Time only: just counts the time.")
                        Text("Choices").font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(study.editCategory.color)
                        TextField("e.g. Dhuha, Tahajjud, Witir", text: $study.editOptions)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundColor(.white)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.12)))
                            .frame(width: 220)
                            .onSubmit { study.saveEdit() }
                    }
                }
            }
        } else if let item = study.choosing {
            // Which one? e.g. Pray → Subuh · Zohor · Asar · Maghrib · Isyak. Ones already done today are ticked.
            let tint = item.category.color
            VStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: item.category.icon).foregroundColor(tint).font(.system(size: 11, weight: .semibold))
                    // From ✓: "Which prayer did you do?" (logs it). From a tap: "Which prayer?" (starts the timer).
                    Text("Which \(["pray", "solat", "sunnah", "sunat"].contains { item.name.lowercased().contains($0) } ? "prayer" : "one")\(study.choosingTick ? " did you do" : "")?")
                        .font(.system(size: 12.5, weight: .semibold, design: .rounded)).foregroundColor(.white)
                }
                HStack(spacing: 6) {
                    ForEach(item.options, id: \.self) { option in
                        let done = study.doneToday(item.name, option)
                        Button { study.choosingTick ? study.checkIn(item, detail: option) : study.start(item, detail: option) } label: {
                            HStack(spacing: 4) {
                                if done { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)) }
                                Text(option).font(.system(size: 11.5, weight: .semibold, design: .rounded))
                            }
                            .foregroundColor(.white.opacity(done ? 0.7 : 1))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Capsule().fill(tint.opacity(done ? 0.18 : 0.42)))
                            .overlay(Capsule().strokeBorder(tint.opacity(0.7), lineWidth: 0.8))
                        }
                        .buttonStyle(LivelyButtonStyle(glow: tint))
                    }
                }
                pill("Cancel", .white.opacity(0.25)) { study.choosing = nil; study.choosingTick = false }
            }
            .padding(.top, 6)
        } else if study.adding {
            HStack(spacing: 8) {
                Image(systemName: study.category.icon).foregroundColor(study.category.color).font(.system(size: 12))
                TextField("New \(study.category.label.lowercased()) activity", text: $study.newName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.12)))
                    .frame(width: 200)
                    .focused($nameFocused)
                    .onSubmit { study.addSubject() }
                    .onAppear { nameFocused = true }
                pill("Add", studyGreen) { study.addSubject() }
                pill("Cancel", .white.opacity(0.25)) { study.newName = ""; study.adding = false }
            }
        } else {
            VStack(spacing: 6) {
                // Category tabs: Academic · Health · Soul · Personal
                HStack(spacing: 6) {
                    ForEach(StudyCategory.allCases) { cat in
                        CategoryTab(category: cat, selected: study.category == cat,
                                    count: study.subjects.filter { $0.category == cat }.count) {
                            study.category = cat
                        }
                    }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(study.visibleSubjects.enumerated()), id: \.element) { index, item in
                            SubjectTile(item: item, today: study.timeLabel(item.name), active: study.subject == item.name,
                                        index: index, onTap: { study.tap(item) }, onEdit: { study.beginEditing(item) },
                                        onTick: { study.tick(item) })
                                .contextMenu {
                                    Button("Edit \(item.name)") { study.beginEditing(item) }
                                    Button("Remove \(item.name)") { study.remove(item.name) }
                                }
                        }
                        AddTile { study.beginAdding() }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 6)      // room for the pencil badge and the lift
                    .padding(.bottom, 4)   // room for the hover glow
                }
                .id(study.category)        // a fresh row per tab, so the tiles drop in again
                if study.running {
                    HStack(spacing: 8) {
                        pill(study.paused ? "Resume" : "Pause", studyOrange) { study.togglePause() }
                        pill("Stop", .white.opacity(0.25)) { study.stop(completed: false) }
                    }
                } else if study.resting {
                    HStack(spacing: 8) {
                        pill(study.paused ? "Resume break" : "Pause break", studyOrange) { study.togglePause() }
                        pill("Skip break", studyBlue) { study.endBreak(finished: false) }
                    }
                } else {
                    Text(study.visibleSubjects.isEmpty ? "Tap + to add your first \(study.category.label.lowercased()) activity"
                                                       : "Click to start  ·  hover a tile and tap ✎ to edit")
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.5))
                }
            }
            .padding(.top, 4)
        }
    }

    private func numberField(_ placeholder: String, _ text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .multilineTextAlignment(.center)
            .font(.system(size: 13, weight: .semibold, design: .monospaced))
            .foregroundColor(.white)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.12)))
            .frame(width: 38)
            .onSubmit { study.saveEdit() }
    }

    private func stepButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .bold)).foregroundColor(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.white.opacity(0.18)))
        }.buttonStyle(LivelyButtonStyle())
    }

    private func pill(_ title: String, _ tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 11.5, weight: .semibold, design: .rounded)).foregroundColor(.white)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(Capsule().fill(tint))
        }.buttonStyle(LivelyButtonStyle(glow: tint))
    }
}

// One category tab above the tiles: icon, name and how many activities it holds
struct CategoryTab: View {
    let category: StudyCategory
    let selected: Bool
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: category.icon).font(.system(size: 10, weight: .semibold))
                Text(category.label).font(.system(size: 11, weight: .semibold, design: .rounded))
                if count > 0 {
                    Text("\(count)").font(.system(size: 9.5, weight: .bold, design: .rounded)).opacity(0.6)
                }
            }
            .foregroundColor(selected ? .white : category.color.opacity(0.85))
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill(category.color.opacity(selected ? 0.38 : 0.10)))
            .overlay(Capsule().strokeBorder(category.color.opacity(selected ? 0.7 : 0.22), lineWidth: 0.8))
        }
        .buttonStyle(LivelyButtonStyle(glow: category.color))
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: selected)
    }
}

// The "+" tile: the plus spins a quarter turn and the tile lights up on hover
struct AddTile: View {
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus").font(.system(size: 15, weight: .semibold)).foregroundColor(.white)
                .rotationEffect(.degrees(hover ? 90 : 0))
                .frame(width: 46, height: 54)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(hover ? 0.2 : 0.10)))
                .overlay(RoundedRectangle(cornerRadius: 9)
                    .stroke(Color.white.opacity(hover ? 0.5 : 0), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3])))
        }
        .buttonStyle(LivelyButtonStyle())
        .animation(.spring(response: 0.35, dampingFraction: 0.55), value: hover)
        .onHover { hover = $0 }
    }
}
