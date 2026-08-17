import AppKit

@MainActor
final class CodePulseApplicationDelegate: NSObject, NSApplicationDelegate {
    private var runtime: CodePulseRuntime?
    private var settingsAction: (() -> Void)?

    func configureSettingsAction(_ action: @escaping () -> Void) {
        settingsAction = action
        installSettingsMenuItem()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installApplicationMenu()

        let runtime = CodePulseRuntime()
        self.runtime = runtime
        configureSettingsAction { [weak runtime] in
            runtime?.showSettings()
        }
        runtime.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    @objc private func showSettings(_ sender: Any?) {
        settingsAction?()
    }

    func installApplicationMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "CodePulse")
        appMenuItem.title = "CodePulse"
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)
        NSApp.mainMenu = mainMenu

        let aboutItem = NSMenuItem(
            title: "About CodePulse",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        aboutItem.target = NSApp
        appMenu.addItem(aboutItem)
        appMenu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(showSettings(_:)),
            keyEquivalent: ","
        )
        settingsItem.target = self
        settingsItem.keyEquivalentModifierMask = [.command]
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit CodePulse",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = NSApp
        quitItem.keyEquivalentModifierMask = [.command]
        appMenu.addItem(quitItem)
    }

    private func installSettingsMenuItem() {
        guard let appMenu = NSApp.mainMenu?.items.first?.submenu,
              let settingsItem = appMenu.item(withTitle: "Settings…") else {
            return
        }

        settingsItem.target = self
        settingsItem.action = #selector(showSettings(_:))
        settingsItem.keyEquivalent = ","
        settingsItem.keyEquivalentModifierMask = [.command]
    }
}
