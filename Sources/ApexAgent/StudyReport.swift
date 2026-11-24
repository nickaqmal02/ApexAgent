import Foundation
import NotchCore

// Rebuilds data/study_report.html after a study session or an activity edit, and uploads it too
// when APEX_STUDY_UPLOAD=1 (scripts/study_report.py --upload needs STUDY_BUCKET / STUDY_DIST_ID /
// STUDY_URL, so start ApexAgent from a terminal that loaded ~/.zshrc).
// Serial background queue: the notch never waits, and two quick stops upload one after another.
// Offline is fine: the upload fails, gets logged, and the next one sends the whole report again.
private let studyReportQueue = DispatchQueue(label: "study.upload")

func rebuildStudyReport() {
    let upload: Bool = ProcessInfo.processInfo.environment["APEX_STUDY_UPLOAD"] == "1"
    studyReportQueue.async {
        let args = ["python3", "scripts/study_report.py", "--no-open"] + (upload ? ["--upload"] : [])
        let out = runShell("/usr/bin/env", args: args)
        let last = out.split(separator: "\n").last.map(String.init) ?? "(no output)"
        if !upload { print("📄 report rebuilt locally: \(last)") }
        else { print(last.hasPrefix("Live at") ? "☁️ report: \(last)" : "☁️ report upload failed: \(last)") }
    }
}

// ApexAgent keeps its study data in data/ next to where it is started (git-ignored), as before the split.
func apexNotchConfig() -> NotchConfig {
    NotchConfig(dataFolder: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("data"),
                onReportNeeded: { rebuildStudyReport() })
}
