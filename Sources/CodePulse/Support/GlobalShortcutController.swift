import AppKit
import Combine

final class GlobalShortcutController: ObservableObject {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var action: (() -> Void)?

    func start(action: @escaping () -> Void) {
        guard globalMonitor == nil, localMonitor == nil else { return }
        self.action = action

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            if Self.isShortcut(event) {
                DispatchQueue.main.async { [weak self] in self?.action?() }
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if Self.isShortcut(event) {
                DispatchQueue.main.async { [weak self] in self?.action?() }
                return nil
            }
            return event
        }
    }

    func stop() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        action = nil
    }

    deinit {
        stop()
    }

    private static func isShortcut(_ event: NSEvent) -> Bool {
        guard event.keyCode == 17 else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return modifiers == [.command, .option]
    }
}
