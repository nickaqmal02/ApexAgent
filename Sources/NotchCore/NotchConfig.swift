import Foundation

// What a host app (ApexAgent or StudyNotch) tells the notch when it starts it.
public struct NotchConfig: Sendable {
    // Where subjects.json and study_sessions.csv live.
    public var dataFolder: URL
    // Called (on the main thread) when the study data changed enough that a report should be rebuilt.
    // ApexAgent runs scripts/study_report.py here; StudyNotch has no report builder yet, so it passes nil.
    public var onReportNeeded: (@Sendable () -> Void)?

    public init(dataFolder: URL, onReportNeeded: (@Sendable () -> Void)? = nil) {
        self.dataFolder = dataFolder
        self.onReportNeeded = onReportNeeded
    }

    // ~/Library/Application Support/StudyNotch: the normal place for an installed Mac app's data.
    public static var applicationSupportFolder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("StudyNotch", isDirectory: true)
    }
}
