import Carbon.HIToolbox
import Combine
import Foundation

protocol GlobalHotKeyRegistering: AnyObject {
    @discardableResult
    func register(
        keyCode: UInt32,
        modifiers: UInt32,
        action: @escaping () -> Void
    ) -> Bool

    func unregister()
}

final class CarbonHotKeyRegistrar: GlobalHotKeyRegistering {
    private static let signature: OSType = 0x4350_4C53 // "CPLS"
    private static let hotKeyID = EventHotKeyID(signature: signature, id: 1)

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var action: (() -> Void)?

    @discardableResult
    func register(
        keyCode: UInt32,
        modifiers: UInt32,
        action: @escaping () -> Void
    ) -> Bool {
        if hotKeyRef != nil {
            self.action = action
            return true
        }

        self.action = action

        var eventType = EventTypeSpec(
            eventClass: UInt32(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var eventHandlerRef: EventHandlerRef?
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            Self.eventHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )
        guard handlerStatus == noErr, let eventHandlerRef else {
            self.action = nil
            return false
        }
        self.eventHandlerRef = eventHandlerRef

        var hotKeyRef: EventHotKeyRef?
        let registrationStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            Self.hotKeyID,
            GetApplicationEventTarget(),
            UInt32(kEventHotKeyExclusive),
            &hotKeyRef
        )
        guard registrationStatus == noErr, let hotKeyRef else {
            removeEventHandler()
            self.action = nil
            return false
        }

        self.hotKeyRef = hotKeyRef
        return true
    }

    func unregister() {
        if let hotKeyRef {
            _ = UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }

        removeEventHandler()
        action = nil
    }

    deinit {
        unregister()
    }

    private func removeEventHandler() {
        if let eventHandlerRef {
            _ = RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
    }

    private static let eventHandler: EventHandlerUPP = { _, _, userData in
        guard let userData else { return OSStatus(eventNotHandledErr) }
        let registrar = Unmanaged<CarbonHotKeyRegistrar>
            .fromOpaque(userData)
            .takeUnretainedValue()
        registrar.action?()
        return noErr
    }
}

@MainActor
final class GlobalShortcutController: ObservableObject {
    static let historyKeyCode: UInt32 = 17 // T
    static let historyModifiers: UInt32 = UInt32(cmdKey | optionKey)

    private let registrar: GlobalHotKeyRegistering
    private var action: (() -> Void)?
    private var settingsCancellable: AnyCancellable?
    private(set) var isRegistered = false

    init(registrar: GlobalHotKeyRegistering = CarbonHotKeyRegistrar()) {
        self.registrar = registrar
    }

    func start(isEnabled: Bool, action: @escaping () -> Void) {
        settingsCancellable?.cancel()
        settingsCancellable = nil
        self.action = action
        setEnabled(isEnabled)
    }

    func start(store: SessionStore, action: @escaping () -> Void) {
        settingsCancellable?.cancel()
        self.action = action
        setEnabled(store.state.settings.globalShortcutEnabled)
        settingsCancellable = store.$state
            .map { $0.settings.globalShortcutEnabled }
            .removeDuplicates()
            .sink { [weak self] isEnabled in
                self?.setEnabled(isEnabled)
            }
    }

    func setEnabled(_ isEnabled: Bool) {
        if isEnabled {
            guard !isRegistered else { return }
            let didRegister = registrar.register(
                keyCode: Self.historyKeyCode,
                modifiers: Self.historyModifiers,
                action: { [weak self] in
                    DispatchQueue.main.async { [weak self] in
                        self?.action?()
                    }
                }
            )
            isRegistered = didRegister
        } else {
            guard isRegistered else { return }
            registrar.unregister()
            isRegistered = false
        }
    }

    func stop() {
        settingsCancellable?.cancel()
        settingsCancellable = nil

        if isRegistered {
            registrar.unregister()
            isRegistered = false
        }
        action = nil
    }

    deinit {
        settingsCancellable?.cancel()
        if isRegistered {
            registrar.unregister()
        }
    }
}
