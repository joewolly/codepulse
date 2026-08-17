import AppKit

@MainActor
final class CodePulseApplicationDelegate: NSObject, NSApplicationDelegate {
    private var runtime: CodePulseRuntime?
    private var settingsAction: (() -> Void)?

    func configureSettingsAction(_ action: @escaping () -> Void) {
        settingsAction = action
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

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.title = "Edit"
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let undoItem = NSMenuItem(
            title: "Undo",
            action: NSSelectorFromString("undo:"),
            keyEquivalent: "z"
        )
        undoItem.target = nil
        undoItem.keyEquivalentModifierMask = [.command]
        editMenu.addItem(undoItem)

        let redoItem = NSMenuItem(
            title: "Redo",
            action: NSSelectorFromString("redo:"),
            keyEquivalent: "z"
        )
        redoItem.target = nil
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoItem)
        editMenu.addItem(.separator())

        let cutItem = NSMenuItem(
            title: "Cut",
            action: NSSelectorFromString("cut:"),
            keyEquivalent: "x"
        )
        cutItem.target = nil
        cutItem.keyEquivalentModifierMask = [.command]
        editMenu.addItem(cutItem)

        let copyItem = NSMenuItem(
            title: "Copy",
            action: NSSelectorFromString("copy:"),
            keyEquivalent: "c"
        )
        copyItem.target = nil
        copyItem.keyEquivalentModifierMask = [.command]
        editMenu.addItem(copyItem)

        let pasteItem = NSMenuItem(
            title: "Paste",
            action: NSSelectorFromString("paste:"),
            keyEquivalent: "v"
        )
        pasteItem.target = nil
        pasteItem.keyEquivalentModifierMask = [.command]
        editMenu.addItem(pasteItem)
        editMenu.addItem(.separator())

        let selectAllItem = NSMenuItem(
            title: "Select All",
            action: NSSelectorFromString("selectAll:"),
            keyEquivalent: "a"
        )
        selectAllItem.target = nil
        selectAllItem.keyEquivalentModifierMask = [.command]
        editMenu.addItem(selectAllItem)

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
}
