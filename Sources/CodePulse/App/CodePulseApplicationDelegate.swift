import AppKit

final class CodePulseApplicationDelegate: NSObject, NSApplicationDelegate {
    private var settingsAction: (() -> Void)?

    func configureSettingsAction(_ action: @escaping () -> Void) {
        settingsAction = action
        installSettingsMenuItem()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installSettingsMenuItem()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    @objc private func showSettings(_ sender: Any?) {
        settingsAction?()
    }

    private func installSettingsMenuItem() {
        guard let appMenu = NSApp.mainMenu?.items.first?.submenu else { return }

        if let settingsItem = appMenu.item(withTitle: "Settings…") {
            settingsItem.target = self
            settingsItem.action = #selector(showSettings(_:))
            settingsItem.keyEquivalent = ","
            return
        }

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(showSettings(_:)),
            keyEquivalent: ","
        )
        settingsItem.target = self
        appMenu.insertItem(settingsItem, at: min(2, appMenu.items.count))
    }
}
