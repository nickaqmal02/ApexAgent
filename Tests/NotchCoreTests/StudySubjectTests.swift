import Foundation
import Testing
@testable import NotchCore

// subjects.json saved before break times existed must still load, with a 5-minute break
@Test func oldSubjectFileGetsDefaultBreak() throws {
    let old = #"[{"name":"Swift","minutes":50}]"#.data(using: .utf8)!
    let list = try JSONDecoder().decode([Subject].self, from: old)
    #expect(list == [Subject(name: "Swift", minutes: 50, breakMinutes: 5)])
}

@Test func breakTimeRoundTrips() throws {
    let saved = try JSONEncoder().encode([Subject(name: "SQL", minutes: 25, breakMinutes: 10)])
    let loaded = try JSONDecoder().decode([Subject].self, from: saved)
    #expect(loaded.first?.breakMinutes == 10)
}

// A comma or quote in a subject name must not break the CSV columns
@Test func csvLineWithQuotedSubject() {
    let cols = StudyStore.parseCSVLine(#"id1,"Maths, ""hard""",25.0,25.0,2026-11-18T19:53:34+08:00,2026-11-18T20:18:34+08:00,1"#)
    #expect(cols.count == 7)
    #expect(cols[1] == #"Maths, "hard""#)
}
