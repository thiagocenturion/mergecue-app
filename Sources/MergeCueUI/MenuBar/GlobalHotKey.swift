import AppKit
import Carbon.HIToolbox

/// A system-wide keyboard shortcut (Settings › General › Keyboard, default ⌃⌥⌘M) that toggles the popover.
///
/// Uses Carbon's `RegisterEventHotKey`: unlike a global `NSEvent` monitor it needs no Accessibility permission,
/// only fires for the exact combination, and the key press is not delivered to the frontmost app.
final class GlobalHotKey {
    /// 'MCUE'
    private static let signature: OSType = 0x4D43_5545
    private let action: () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private(set) var registered: HotKeyPreset = .off

    init(action: @escaping () -> Void) {
        self.action = action
    }

    /// Registers `preset` (replacing the previous shortcut). False when macOS refuses it, e.g. because another app
    /// already owns the combination; `.off` only unregisters.
    @discardableResult
    func register(_ preset: HotKeyPreset) -> Bool {
        unregister()
        guard let keyCode = preset.keyCode else { return true }
        installHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(keyCode, preset.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        hotKeyRef = ref
        registered = preset
        return true
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        registered = .off
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, id.signature == GlobalHotKey.signature else { return OSStatus(eventNotHandledErr) }
            // Application-target Carbon events are dispatched on the main thread.
            MainActor.assumeIsolated {
                Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue().action()
            }
            return noErr
        }, 1, &eventType, context, &handlerRef)
    }
}
