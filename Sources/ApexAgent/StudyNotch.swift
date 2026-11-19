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

// One subject, its pomodoro length and its break length. Editable from the notch (the pencil on each tile).
struct Subject: Codable, Hashable {
    var name: String
    var minutes: Double
    var breakMinutes: Double = 5

    init(name: String, minutes: Double, breakMinutes: Double = 5) {
        self.name = name
        self.minutes = minutes
        self.breakMinutes = breakMinutes
    }

    // Files saved before breaks existed have no breakMinutes: use 5
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        minutes = try c.decode(Double.self, forKey: .minutes)
        breakMinutes = try c.decodeIfPresent(Double.self, forKey: .breakMinutes) ?? 5
    }
}

struct StudyStore {
    let folder: URL
    var subjectsURL: URL { folder.appendingPathComponent("subjects.json") }
    var sessionsURL: URL { folder.appendingPathComponent("study_sessions.csv") }
    static let header: String = "id,subject,planned_min,actual_min,started_at,ended_at,completed\n"

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
    func appendSession(subject: String, plannedMin: Double, actualMin: Double, startedAt: Date, endedAt: Date, completed: Bool) {
        let iso = ISO8601DateFormatter()
        iso.timeZone = .current
        let safeSubject: String = "\"" + subject.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        let row: String = [UUID().uuidString, safeSubject, String(format: "%.1f", plannedMin), String(format: "%.1f", actualMin),
                           iso.string(from: startedAt), iso.string(from: endedAt), completed ? "1" : "0"].joined(separator: ",") + "\n"
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
            guard cols.count == 7, let minutes = Double(cols[3]), let started = iso.date(from: cols[4]) else { continue }
            if Calendar.current.isDateInToday(started) { totals[cols[1], default: 0] += minutes }
        }
        return totals
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
    // The break after a finished pomodoro: whose break it is, and a short "break over" notice
    @Published var breakFor: String? = nil
    @Published var breakOver: Bool = false
    // The running session
    @Published var subject: String? = nil
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
        subjects = store.loadSubjects()
        todayMinutes = store.todayMinutes()
        store.saveSubjects(subjects)
    }

    var running: Bool { subject != nil }
    var resting: Bool { breakFor != nil }
    var showsStatus: Bool { running || resting || justFinished != nil || breakOver }
    // Typing in the + or edit box: keep the notch open even if the mouse wanders off
    var typing: Bool { adding || editing != nil }

    var clock: String {
        let s = Int(remaining.rounded(.up))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    func timeLabel(_ subject: String) -> String {
        let m = todayMinutes[subject] ?? 0
        return m < 60 ? "\(Int(m.rounded()))m" : String(format: "%.1fh", m / 60)
    }

    func start(_ item: Subject) {
        if running { stop(completed: false) }
        if resting { endBreak(finished: false) }   // starting a subject ends the break early
        breakOver = false
        plannedMinutes = testMinutes ?? item.minutes
        let name: String = item.name
        subject = name
        startedAt = Date()
        remaining = plannedMinutes * 60
        endDate = Date().addingTimeInterval(remaining)
        paused = false
        justFinished = nil
        tick?.invalidate()
        tick = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated { self.update() }
        }
        print("📚 study started: \(name), \(plannedMinutes) min")
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

    func stop(completed: Bool) {
        guard let name = subject, let began = startedAt else { return }
        tick?.invalidate()
        let studiedMin: Double = completed ? plannedMinutes : (plannedMinutes * 60 - remaining) / 60
        store.appendSession(subject: name, plannedMin: plannedMinutes, actualMin: studiedMin, startedAt: began, endedAt: Date(), completed: completed)
        todayMinutes = store.todayMinutes()
        print("📚 study \(completed ? "finished" : "stopped"): \(name), \(String(format: "%.1f", studiedMin)) min saved")
        subject = nil
        startedAt = nil
        endDate = nil
        paused = false
        if completed {
            NSSound(named: "Glass")?.play()
            let breakLength: Double = testMinutes ?? (subjects.first { $0.name == name }?.breakMinutes ?? 5)
            if breakLength > 0 {
                startBreak(for: name, minutes: breakLength)
            } else {
                justFinished = name
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                    MainActor.assumeIsolated { if self.justFinished == name { self.justFinished = nil } }
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
            subjects.append(Subject(name: String(name.prefix(maxSubjectNameLength)), minutes: 25))
            store.saveSubjects(subjects)
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
        store.saveSubjects(subjects)
        cancelEdit()
    }

    func cancelEdit() {
        editing = nil
        editName = ""
        editMinutes = ""
        editBreak = ""
    }

    func remove(_ name: String) {
        subjects.removeAll { $0.name == name }
        store.saveSubjects(subjects)
        cancelEdit()
    }
}

// MARK: - Views

// Long enough for names like "RAG LangChain Knowledge"
let maxSubjectNameLength: Int = 24

let studyGreen = Color(red: 0.25, green: 0.73, blue: 0.31)
let studyOrange = Color(red: 0.94, green: 0.53, blue: 0.24)
let studyBlue = Color(red: 0.35, green: 0.65, blue: 1.0)   // breaks

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
            Text("\(today) today").font(.system(size: 9, weight: .medium, design: .rounded)).foregroundColor(.white.opacity(0.45))
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
    let width: CGFloat
    let notchWidth: CGFloat
    let notchHeight: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if let name = study.subject {
                    HStack(spacing: 5) {
                        Circle().fill(study.paused ? studyOrange : studyGreen).frame(width: 7, height: 7)
                        Text(name).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundColor(.white).lineLimit(1)
                    }
                } else if study.resting {
                    HStack(spacing: 5) {
                        Image(systemName: "cup.and.saucer.fill").foregroundColor(study.paused ? studyOrange : studyBlue).font(.system(size: 11))
                        Text("Break").font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundColor(.white).lineLimit(1)
                    }
                } else if study.breakOver {
                    HStack(spacing: 5) {
                        Image(systemName: "bell.fill").foregroundColor(studyBlue).font(.system(size: 11))
                        Text("Break over").font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundColor(.white).lineLimit(1)
                    }
                } else if let done = study.justFinished {
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark.circle.fill").foregroundColor(studyGreen).font(.system(size: 12))
                        Text(done).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundColor(.white).lineLimit(1)
                    }
                }
            }
            .frame(width: 90, alignment: .leading)
            Spacer(minLength: notchWidth)
            Group {
                if study.running || study.resting {
                    Text(study.clock).font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundColor(study.paused ? studyOrange : (study.resting ? studyBlue : .white))
                } else if study.breakOver {
                    Text("Pick one").font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundColor(studyBlue)
                } else if study.justFinished != nil {
                    Text("Done").font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundColor(studyGreen)
                }
            }
            .frame(width: 60, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(width: width, height: notchHeight)
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
                        .frame(width: 170)
                        .focused($nameFocused)
                        .onSubmit { study.saveEdit() }
                        .onAppear { nameFocused = true }
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
            }
        } else if study.adding {
            HStack(spacing: 8) {
                TextField("Subject name", text: $study.newName)
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
            VStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(study.subjects.enumerated()), id: \.element) { index, item in
                            SubjectTile(item: item, today: study.timeLabel(item.name), active: study.subject == item.name,
                                        index: index, onTap: { study.start(item) }, onEdit: { study.beginEditing(item) })
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
                    Text("Click a subject to start  ·  hover a tile and tap ✎ to edit")
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
