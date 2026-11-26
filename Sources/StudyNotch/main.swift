import AppKit
import NotchCore

// StudyNotch: the study notch on its own, for other Mac users.
// No microphone, no LLM, no API keys, no shell: the notch, the timer, data files in
// ~/Library/Application Support/StudyNotch/, a local habit report, and optional sharing of that
// report on the web (off until the user turns it on). The menu-bar icon holds all of that.

// Where "Share my report" talks to. Set once the AWS stack is deployed (cloud/README.md);
// STUDYNOTCH_API overrides it for testing. Empty = the Share items are hidden.
let defaultShareAPI = "https://hsjsnyta2wxq6c5xrbgefn5jde0yqonm.lambda-url.ap-southeast-1.on.aws/"
let shareAPI: URL? = URL(string: ProcessInfo.processInfo.environment["STUDYNOTCH_API"] ?? defaultShareAPI)
    .flatMap { $0.scheme == "https" || $0.host == "127.0.0.1" ? $0 : nil }

// Debug / scripting: `studynotch --report-json [folder] [--shared]` prints the report data and exits (no UI)
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "--report-json" {
    let args = CommandLine.arguments.dropFirst(2).filter { $0 != "--shared" }
    let folder = args.first.map { URL(fileURLWithPath: $0) } ?? NotchConfig.applicationSupportFolder
    FileHandle.standardOutput.write(ReportBuilder.json(dataFolder: folder, forSharing: CommandLine.arguments.contains("--shared")))
    exit(0)
}

@MainActor
final class MenuBar: NSObject, NSMenuDelegate {
    private var item: NSStatusItem?
    private let dataFolder: URL
    let share: ShareManager?

    init(dataFolder: URL) {
        self.dataFolder = dataFolder
        self.share = shareAPI.map { ShareManager(api: $0, dataFolder: dataFolder) }
    }

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "timer", accessibilityDescription: "StudyNotch")
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        self.item = item
    }

    // Rebuilt every time it opens, so the share state is always current
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        note(menu, "StudyNotch: hover the notch to start")
        menu.addItem(.separator())
        add(menu, "Open My Report", #selector(openReport), key: "r")
        if let share {
            menu.addItem(.separator())
            switch share.state {
            case .off:
                add(menu, "Share My Report on the Web…", #selector(startSharing))
            case .working:
                note(menu, "Sharing: working…")
            case .on(let url, let last):
                note(menu, "✓ Sharing is on")
                note(menu, url.replacingOccurrences(of: "https://", with: ""))
                if let last { note(menu, "Updated \(RelativeDateTimeFormatter().localizedString(for: last, relativeTo: Date()))") }
                add(menu, "Copy Link", #selector(copyLink), key: "c")
                add(menu, "Open Link in Browser", #selector(openLink))
                add(menu, "Stop Sharing", #selector(stopSharing))
            }
            if let err = share.lastError { note(menu, err) }
        }
        menu.addItem(.separator())
        add(menu, "Show Data Folder", #selector(showData))
        menu.addItem(withTitle: "Quit StudyNotch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, key: String = "") {
        let i = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        i.target = self
    }
    private func note(_ menu: NSMenu, _ title: String) {
        menu.addItem(withTitle: title, action: nil, keyEquivalent: "").isEnabled = false
    }

    @objc private func openReport() {
        if let url = ReportBuilder.writeLocalReport(dataFolder: dataFolder) { NSWorkspace.shared.open(url) }
    }
    @objc private func startSharing() { Task { await share?.start() } }
    @objc private func stopSharing() { Task { await share?.stop() } }
    @objc private func copyLink() {
        guard case .on(let url, _)? = share?.state else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }
    @objc private func openLink() {
        guard case .on(let url, _)? = share?.state, let u = URL(string: url) else { return }
        NSWorkspace.shared.open(u)
    }
    @objc private func showData() { NSWorkspace.shared.activateFileViewerSelecting([dataFolder]) }

    // After a session or an edit: refresh the local report file and (if sharing) the web copy
    func dataChanged() {
        ReportBuilder.writeLocalReport(dataFolder: dataFolder)
        share?.reportChanged()
    }
}

let folder = NotchConfig.applicationSupportFolder
let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // no Dock icon; the notch and the menu-bar icon are the whole UI
MainActor.assumeIsolated {
    let menuBar = MenuBar(dataFolder: folder)
    menuBar.install()
    let config = NotchConfig(dataFolder: folder, onReportNeeded: {
        MainActor.assumeIsolated { menuBar.dataChanged() }   // NotchCore calls this on the main thread
    })
    NotchController.shared.start(config: config)
    objc_setAssociatedObject(app, "studynotch.menubar", menuBar, .OBJC_ASSOCIATION_RETAIN)   // keep it alive
}
app.run()
