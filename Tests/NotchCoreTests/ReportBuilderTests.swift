import Foundation
import Testing
@testable import NotchCore

private func folderWithData() -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("report-tests-\(UUID().uuidString)")
    let store = StudyStore(folder: folder)
    store.saveSubjects([Subject(name: "SQL", minutes: 25),
                        Subject(name: "Pray", minutes: 5, category: .soul, options: ["Subuh", "Zohor"]),
                        Subject(name: "Tadarus", minutes: 20, category: StudyCategory(rawValue: "c-quran-club"))])
    store.saveCategories([CustomCategory(key: "c-quran-club", label: "Quran Club", icon: "star.fill", color: "#8e6be8")])
    let now = Date()
    store.appendSession(subject: "SQL", category: .academic, detail: nil, plannedMin: 25, actualMin: 25,
                        startedAt: now.addingTimeInterval(-3000), endedAt: now.addingTimeInterval(-1500), completed: true)
    for p in ["Subuh", "Zohor"] {
        store.appendSession(subject: "Pray", category: .soul, detail: p, plannedMin: 5, actualMin: 5,
                            startedAt: now.addingTimeInterval(-900), endedAt: now.addingTimeInterval(-600), completed: true)
    }
    return folder
}

// The embedded copy must be the HTML file exactly (run scripts/embed_report_template.py after editing it)
@Test func embeddedTemplateMatchesTheFile() throws {
    let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("scripts/study_report_template.html")
    #expect(ReportTemplate.html == (try String(contentsOf: file, encoding: .utf8)))
    #expect(ReportTemplate.html.contains("const D = __DATA__;"))
}

@Test func reportHasHabitsCategoriesAndTotals() throws {
    let d = ReportBuilder.build(store: StudyStore(folder: folderWithData()))
    let habits = try #require(d["habits"] as? [[String: Any]])
    #expect(habits.map { $0["name"] as? String } == ["Study", "Pray", "Tadarus"])
    #expect((habits[1]["days"] as? [[String: Any]])?.first { $0["today"] as? Bool == true }?["s"] as? Int == 2)   // both prayers done
    let cats = try #require(d["categories"] as? [[String: Any]])
    #expect(cats.map { $0["key"] as? String } == ["academic", "health", "soul", "personal", "c-quran-club"])
    #expect(cats.last?["color"] as? String == "#8e6be8")
    let totals = try #require(d["totals"] as? [String: Any])
    #expect(totals["minutes"] as? Double == 35)
    #expect((d["sessions"] as? [Any])?.count == 3)
}

// The shared copy never carries raw sessions
@Test func sharedReportLeavesOutSessions() throws {
    let d = ReportBuilder.build(store: StudyStore(folder: folderWithData()), forSharing: true)
    #expect((d["sessions"] as? [Any])?.isEmpty == true)
    #expect(d["shared"] as? Bool == true)
    #expect(d["habits"] != nil)
}

@Test func localReportIsWrittenFromTheTemplate() throws {
    let folder = folderWithData()
    let url = try #require(ReportBuilder.writeLocalReport(dataFolder: folder))
    let html = try String(contentsOf: url, encoding: .utf8)
    #expect(!html.contains("__DATA__"))
    #expect(html.contains("\"Quran Club\""))
}

@Test func pythonStyleRoundingAndSums() {
    #expect(ReportBuilder.r1(19.35) == 19.4)   // like Python round(19.35, 1)
    #expect(ReportBuilder.r1(0.25) == 0.2)
    #expect(ReportBuilder.pysum([0.1, 0.2, 0.3]) == 0.6)   // a plain reduce gives 0.6000000000000001
}
