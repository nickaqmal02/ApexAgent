import Foundation
import Testing
@testable import NotchCore

// Every test gets its own empty folder, so nothing touches the real data/ or Application Support.
private func tempStore() -> StudyStore {
    StudyStore(folder: FileManager.default.temporaryDirectory.appendingPathComponent("notchcore-tests-\(UUID().uuidString)"))
}

// MARK: - Store

@Test func firstRunGivesStarterSubjects() {
    #expect(tempStore().loadSubjects().map(\.name) == ["Swift", "SQL", "PSM"])
}

@Test func subjectsRoundTripThroughTheFolder() {
    let store = tempStore()
    let list = [Subject(name: "Pray", minutes: 5, category: .soul, options: ["Subuh", "Zohor"]),
                Subject(name: "Brisk walk", minutes: 30, category: .health)]
    store.saveSubjects(list)
    #expect(store.loadSubjects() == list)
}

@Test func sessionsAreCountedForToday() {
    let store = tempStore()
    let now = Date()
    store.appendSession(subject: "SQL", category: .academic, detail: nil, plannedMin: 25, actualMin: 25,
                        startedAt: now.addingTimeInterval(-1500), endedAt: now, completed: true)
    store.appendSession(subject: "SQL", category: .academic, detail: nil, plannedMin: 25, actualMin: 10,
                        startedAt: now.addingTimeInterval(-600), endedAt: now, completed: false)
    #expect(store.todayMinutes()["SQL"] == 35)
    let text = (try? String(contentsOf: store.sessionsURL, encoding: .utf8)) ?? ""
    #expect(text.hasPrefix(StudyStore.header))
}

@Test func finishedOptionsAreTickedForToday() {
    let store = tempStore()
    let now = Date()
    store.appendSession(subject: "Pray", category: .soul, detail: "Subuh", plannedMin: 5, actualMin: 5,
                        startedAt: now.addingTimeInterval(-300), endedAt: now, completed: true)
    store.appendSession(subject: "Pray", category: .soul, detail: "Zohor", plannedMin: 5, actualMin: 2,
                        startedAt: now.addingTimeInterval(-120), endedAt: now, completed: false)   // stopped: not done
    #expect(store.todayDoneDetails() == ["Pray|Subuh"])
}

// A CSV from before the detail column gets only its header rewritten; the rows stay as they were
@Test func oldHeaderGetsTheDetailColumn() throws {
    let store = tempStore()
    let row = "id1,\"SQL\",25.0,25.0,2026-11-18T19:53:34+08:00,2026-11-18T20:18:34+08:00,1,academic\n"
    try (StudyStore.headerBeforeDetail + "\n" + row).write(to: store.sessionsURL, atomically: true, encoding: .utf8)
    store.upgradeSessionsIfNeeded { _ in .academic }
    let text = try String(contentsOf: store.sessionsURL, encoding: .utf8)
    #expect(text == StudyStore.header + row)
}

// MARK: - Custom categories

@Test func customCategoriesRoundTrip() {
    let store = tempStore()
    #expect(store.loadCategories().isEmpty)
    let list = [CustomCategory(key: "c-quran-club", label: "Quran Club", icon: "star.fill", color: "#8e6be8")]
    store.saveCategories(list)
    #expect(store.loadCategories() == list)
}

@Test func categoryKeysAreSlugsThatNeverClash() {
    #expect(CustomCategory.key(for: "Quran Club", taken: []) == "c-quran-club")
    #expect(CustomCategory.key(for: "  Gym!! ", taken: []) == "c-gym")
    #expect(CustomCategory.key(for: "Gym", taken: ["c-gym"]) == "c-gym-2")
    #expect(CustomCategory.key(for: "???", taken: []) == "c-category")
    #expect(!StudyCategory.builtIn.map(\.rawValue).contains(CustomCategory.key(for: "academic", taken: [])))
}

// Categories are saved as plain strings, exactly like the old enum, so existing subjects.json files still load
@Test func categoryIsSavedAsAPlainString() throws {
    let data = try JSONEncoder().encode(Subject(name: "Tadarus", minutes: 20, category: StudyCategory(rawValue: "c-quran-club")))
    let json = String(decoding: data, as: UTF8.self)
    #expect(json.contains(#""category":"c-quran-club""#))
    let old = #"[{"name":"Walk","minutes":30,"category":"health"}]"#.data(using: .utf8)!
    #expect(try JSONDecoder().decode([Subject].self, from: old).first?.category == .health)
}

// A removed custom category must not crash anything: its activities and rows still read sensibly
@Test func unknownCategoryFallsBackGracefully() {
    let gone = StudyCategory(rawValue: "c-deleted-thing")
    #expect(!gone.isBuiltIn)
    #expect(gone.icon == "circle.fill")
    #expect(StudyCategory.builtIn.count == 4)
}
