import AppKit
import NotchCore

// StudyNotch: the study notch on its own, for other Mac users.
// No microphone, no LLM, no API keys, no shell: only the notch, the timer and two data files in
// ~/Library/Application Support/StudyNotch/. A menu-bar icon gives a way to find the data and to quit,
// because a notch-only app has no Dock icon and no window.
//
// Not done yet (see README): the habit report is still built by ApexAgent's Python script, so StudyNotch
// passes no report hook; launch at login needs a real .app bundle (SMAppService).

@MainActor
final class MenuBar: NSObject {
    private var item: NSStatusItem?
    private let dataFolder: URL

    init(dataFolder: URL) {
        self.dataFolder = dataFolder
    }

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "timer", accessibilityDescription: "StudyNotch")
        let menu = NSMenu()
        menu.addItem(withTitle: "StudyNotch: hover the notch to start", action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(.separator())
        let open = menu.addItem(withTitle: "Show Data Folder", action: #selector(showData), keyEquivalent: "")
        open.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit StudyNotch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        self.item = item
    }

    @objc private func showData() {
        NSWorkspace.shared.activateFileViewerSelecting([dataFolder])
    }
}

let config = NotchConfig(dataFolder: NotchConfig.applicationSupportFolder)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // no Dock icon; the notch and the menu-bar icon are the whole UI
MainActor.assumeIsolated {
    let menuBar = MenuBar(dataFolder: config.dataFolder)
    menuBar.install()
    NotchController.shared.start(config: config)
    objc_setAssociatedObject(app, "studynotch.menubar", menuBar, .OBJC_ASSOCIATION_RETAIN)   // keep it alive
}
app.run()
