// Study notch prototype for ApexAgent: hover the notch, pick a subject, a pomodoro starts,
// and every session is saved to a CSV. Standalone: it does not touch the app.
//
// Build and run (from the ApexAgent folder):
//   swiftc -parse-as-library Prototypes/StudyNotch.swift -o /tmp/studynotch && /tmp/studynotch
// Quit with Ctrl-C.
//
// Data (personal, git-ignored):
//   data/subjects.json        your subject list
//   data/study_sessions.csv   one row per finished or stopped session
//
// Test settings (environment variables):
//   STUDY_MINUTES=0.2    a 12-second pomodoro, to test the finish without waiting 25 minutes
//   STUDY_EXPANDED=1     keep the notch open (for screenshots)
//   STUDY_START=Swift    start that subject right away

import AppKit
import SwiftUI

// MARK: - Storage

struct StudyStore {
    let folder: URL
    var subjectsURL: URL { folder.appendingPathComponent("subjects.json") }
    var sessionsURL: URL { folder.appendingPathComponent("study_sessions.csv") }
    static let header: String = "id,subject,planned_min,actual_min,started_at,ended_at,completed\n"

    init() {
        folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("data")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func loadSubjects() -> [String] {
        guard let data = try? Data(contentsOf: subjectsURL),
              let list = try? JSONDecoder().decode([String].self, from: data) else {
            return ["Swift", "SQL", "PSM"]   // first run
        }
        return list
    }

    func saveSubjects(_ list: [String]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(list) { try? data.write(to: subjectsURL) }
    }

    // One CSV row per session. Quotes around the subject so a comma in a name cannot break the columns.
    func appendSession(subject: String, plannedMin: Double, actualMin: Double, startedAt: Date, endedAt: Date, completed: Bool) {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
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
            let cols = parseCSVLine(String(line))
            guard cols.count == 7, let minutes = Double(cols[3]), let started = iso.date(from: cols[4]) else { continue }
            if Calendar.current.isDateInToday(started) { totals[cols[1], default: 0] += minutes }
        }
        return totals
    }

    private func parseCSVLine(_ line: String) -> [String] {
        var out: [String] = []
        var field: String = ""
        var quoted: Bool = false
        var chars = Array(line)
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
        chars.removeAll()
        return out
    }
}

// MARK: - Model

@MainActor
final class StudyModel: ObservableObject {
    @Published var subjects: [String]
    @Published var todayMinutes: [String: Double]
    @Published var expanded: Bool = false
    @Published var adding: Bool = false
    @Published var newName: String = ""
    // The running session
    @Published var subject: String? = nil
    @Published var remaining: TimeInterval = 0
    @Published var paused: Bool = false
    @Published var justFinished: String? = nil

    let notchWidth: CGFloat
    let notchHeight: CGFloat
    let plannedMinutes: Double
    let store = StudyStore()
    private var endDate: Date? = nil
    private var startedAt: Date? = nil
    private var tick: Timer? = nil

    init(notchWidth: CGFloat, notchHeight: CGFloat) {
        self.notchWidth = notchWidth
        self.notchHeight = notchHeight
        self.plannedMinutes = Double(ProcessInfo.processInfo.environment["STUDY_MINUTES"] ?? "") ?? 25
        self.subjects = store.loadSubjects()
        self.todayMinutes = store.todayMinutes()
        store.saveSubjects(subjects)
    }

    var running: Bool { subject != nil }

    // Sizes of the black shape for each look
    var size: CGSize {
        if expanded { return CGSize(width: max(notchWidth + 220, 420), height: notchHeight + 96) }
        if running || justFinished != nil { return CGSize(width: notchWidth + 150, height: notchHeight) }
        return CGSize(width: notchWidth, height: notchHeight)
    }

    var clock: String {
        let s = Int(remaining.rounded(.up))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    func hoursLabel(_ subject: String) -> String {
        let m = todayMinutes[subject] ?? 0
        return m < 60 ? "\(Int(m.rounded()))m" : String(format: "%.1fh", m / 60)
    }

    func start(_ name: String) {
        if running { stop(completed: false) }
        subject = name
        startedAt = Date()
        remaining = plannedMinutes * 60
        endDate = Date().addingTimeInterval(remaining)
        paused = false
        justFinished = nil
        expanded = false
        tick?.invalidate()
        tick = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated { self.update() }
        }
        print("▶ started \(name) for \(plannedMinutes) min")
    }

    // Uses the end time, not a counter, so the clock stays right even if the Mac is busy
    private func update() {
        guard running, !paused, let end = endDate else { return }
        remaining = max(0, end.timeIntervalSinceNow)
        if remaining <= 0 { stop(completed: true) }
    }

    func togglePause() {
        guard running else { return }
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
        print("■ \(completed ? "finished" : "stopped") \(name): \(String(format: "%.1f", studiedMin)) min saved")
        subject = nil
        startedAt = nil
        endDate = nil
        paused = false
        if completed {
            NSSound(named: "Glass")?.play()
            justFinished = name
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                MainActor.assumeIsolated { if self.justFinished == name { self.justFinished = nil } }
            }
        }
    }

    func addSubject() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty && !subjects.contains(where: { $0.lowercased() == name.lowercased() }) {
            subjects.append(String(name.prefix(16)))
            store.saveSubjects(subjects)
        }
        newName = ""
        adding = false
    }

    func remove(_ name: String) {
        subjects.removeAll { $0 == name }
        store.saveSubjects(subjects)
    }
}

// MARK: - Views

struct NotchShape: Shape {
    var bottomRadius: CGFloat
    var animatableData: CGFloat {
        get { bottomRadius }
        set { bottomRadius = newValue }
    }
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let r = min(bottomRadius, rect.height / 2, rect.width / 2)
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r), control: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

let studyGreen = Color(red: 0.25, green: 0.73, blue: 0.31)
let studyOrange = Color(red: 0.94, green: 0.53, blue: 0.24)

struct SubjectTile: View {
    let name: String
    let hours: String
    let active: Bool
    @State private var hover = false

    var body: some View {
        VStack(spacing: 2) {
            Text(name).font(.system(size: 12, weight: .semibold, design: .rounded)).lineLimit(1)
            Text(hours).font(.system(size: 10, weight: .medium, design: .rounded)).foregroundColor(.white.opacity(0.55))
        }
        .foregroundColor(.white)
        .frame(width: 66, height: 46)
        .background(RoundedRectangle(cornerRadius: 9).fill(active ? studyGreen.opacity(0.35) : Color.white.opacity(hover ? 0.18 : 0.10)))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(active ? studyGreen : Color.clear, lineWidth: 1.5))
        .onHover { hover = $0 }
    }
}

struct StudyNotchView: View {
    @ObservedObject var model: StudyModel
    @FocusState private var nameFocused: Bool

    var body: some View {
        let size = model.size
        ZStack(alignment: .top) {
            NotchShape(bottomRadius: model.expanded ? 18 : 9)
                .fill(Color.black)
                .frame(width: size.width, height: size.height)

            VStack(spacing: 0) {
                // Row beside the camera: the running session, always visible
                HStack(spacing: 0) {
                    leftStatus.frame(width: 70, alignment: .leading)
                    Spacer(minLength: model.notchWidth)
                    rightStatus.frame(width: 70, alignment: .trailing)
                }
                .padding(.horizontal, 12)
                .frame(width: size.width, height: model.notchHeight)

                if model.expanded {
                    expandedBody
                        .frame(width: size.width, height: 96)
                        .transition(.opacity)
                }
            }
        }
        .frame(width: 520, height: model.notchHeight + 110, alignment: .top)
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: model.expanded)
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: model.running)
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: model.justFinished)
    }

    @ViewBuilder private var leftStatus: some View {
        if let name = model.subject {
            HStack(spacing: 5) {
                Circle().fill(model.paused ? studyOrange : studyGreen).frame(width: 7, height: 7)
                Text(name).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundColor(.white).lineLimit(1)
            }
        } else if let done = model.justFinished {
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill").foregroundColor(studyGreen).font(.system(size: 12))
                Text(done).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundColor(.white).lineLimit(1)
            }
        }
    }

    @ViewBuilder private var rightStatus: some View {
        if model.running {
            Text(model.clock)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundColor(model.paused ? studyOrange : .white)
        } else if model.justFinished != nil {
            Text("Done").font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundColor(studyGreen)
        }
    }

    @ViewBuilder private var expandedBody: some View {
        if model.adding {
            HStack(spacing: 8) {
                TextField("Subject name", text: $model.newName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.12)))
                    .frame(width: 200)
                    .focused($nameFocused)
                    .onSubmit { model.addSubject() }
                    .onAppear { nameFocused = true }
                pillButton("Add", tint: studyGreen) { model.addSubject() }
                pillButton("Cancel", tint: .white.opacity(0.25)) { model.newName = ""; model.adding = false }
            }
        } else {
            VStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.subjects, id: \.self) { name in
                            SubjectTile(name: name, hours: model.hoursLabel(name), active: model.subject == name)
                                .onTapGesture { model.start(name) }
                                .contextMenu { Button("Remove \(name)") { model.remove(name) } }
                        }
                        Button { model.adding = true } label: {
                            Image(systemName: "plus").font(.system(size: 15, weight: .semibold)).foregroundColor(.white)
                                .frame(width: 46, height: 46)
                                .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.10)))
                        }.buttonStyle(.plain)
                    }
                    .padding(.horizontal, 14)
                }
                if model.running {
                    HStack(spacing: 8) {
                        pillButton(model.paused ? "Resume" : "Pause", tint: studyOrange) { model.togglePause() }
                        pillButton("Stop", tint: .white.opacity(0.25)) { model.stop(completed: false) }
                    }
                } else {
                    Text("Pick a subject to start \(Int(model.plannedMinutes)) min")
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.5))
                }
            }
            .padding(.top, 4)
        }
    }

    private func pillButton(_ title: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 11.5, weight: .semibold, design: .rounded)).foregroundColor(.white)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(Capsule().fill(tint))
        }.buttonStyle(.plain)
    }
}

// MARK: - Window

// A panel that can take typing (for the + box) without activating the app or stealing focus otherwise
final class StudyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class StudyNotchController {
    var panel: StudyPanel?
    var model: StudyModel?
    var hoverTimer: Timer?
    var screenFrame: NSRect = .zero

    func start() {
        guard let screen = NSScreen.main else { return }
        let notchHeight: CGFloat = screen.safeAreaInsets.top > 0 ? screen.safeAreaInsets.top : 32
        var notchWidth: CGFloat = 190
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notchWidth = right.minX - left.maxX
        }
        screenFrame = screen.frame
        let model = StudyModel(notchWidth: notchWidth, notchHeight: notchHeight)
        let width: CGFloat = 520
        let height: CGFloat = notchHeight + 110
        let frame = NSRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - height, width: width, height: height)

        let panel = StudyPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar + 1
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: StudyNotchView(model: model))
        panel.orderFrontRegardless()
        self.panel = panel
        self.model = model

        let env = ProcessInfo.processInfo.environment
        if env["STUDY_EXPANDED"] == "1" { setExpanded(true) }
        if let name = env["STUDY_START"] { model.start(name) }

        // Hover: check where the mouse is 20 times a second. Cheap, and needs no special permission.
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated { self.checkHover() }
        }
    }

    // The black shape's area on screen (AppKit y grows upward, so the top is screen maxY)
    private func shapeRect(_ size: CGSize, margin: CGFloat) -> NSRect {
        NSRect(x: screenFrame.midX - size.width / 2 - margin, y: screenFrame.maxY - size.height - margin,
               width: size.width + margin * 2, height: size.height + margin * 2)
    }

    private func checkHover() {
        guard let model = model else { return }
        if ProcessInfo.processInfo.environment["STUDY_EXPANDED"] == "1" { return }
        let mouse = NSEvent.mouseLocation
        if model.expanded {
            // Stay open while the mouse is near, or while typing a new subject
            if !model.adding && !shapeRect(model.size, margin: 14).contains(mouse) { setExpanded(false) }
        } else if shapeRect(model.size, margin: 2).contains(mouse) {
            setExpanded(true)
        }
    }

    private func setExpanded(_ open: Bool) {
        guard let model = model, let panel = panel else { return }
        model.expanded = open
        if !open { model.adding = false }
        // Closed: clicks pass through to the menu bar. Open: the panel takes clicks.
        panel.ignoresMouseEvents = !open
        if open { panel.makeKey() } else { panel.resignKey() }
    }
}

@main
struct StudyNotchApp {
    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let controller = MainActor.assumeIsolated { () -> StudyNotchController in
            let c = StudyNotchController()
            c.start()
            return c
        }
        print("Study notch running. Hover the notch. Data: \(controller.model?.store.folder.path ?? "?")")
        app.run()
    }
}
