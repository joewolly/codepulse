import AppKit
import SwiftUI

@main
struct CodePulseApp: App {
    @StateObject private var store: SessionStore

    init() {
        _store = StateObject(wrappedValue: SessionStore.live())
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarPopoverView()
                .environmentObject(store)
        } label: {
            MenuBarLabel()
                .environmentObject(store)
        }
        .menuBarExtraStyle(.window)

        Window("History", id: "history") {
            HistoryView()
                .environmentObject(store)
        }
        .defaultSize(width: 680, height: 540)

        Settings {
            SettingsView()
                .environmentObject(store)
        }
    }
}
