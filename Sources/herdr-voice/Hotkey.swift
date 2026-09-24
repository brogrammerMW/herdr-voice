import Carbon.HIToolbox

/// Global hotkey through Carbon, which needs no Accessibility permission.
/// Default ⌥⌘M; override with HERDR_VOICE_HOTKEY_KEYCODE (virtual key code, modifiers stay ⌥⌘).
enum Hotkey {
    static let label = "⌥⌘M"
    private static var handler: (() -> Void)?

    static func register(_ onPress: @escaping () -> Void) {
        handler = onPress
        let keyCode = UInt32(ProcessInfo.processInfo.environment["HERDR_VOICE_HOTKEY_KEYCODE"] ?? "") ?? UInt32(kVK_ANSI_M)
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            Hotkey.handler?()
            return noErr
        }, 1, &spec, nil, nil)
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x4856_4F43), id: 1) // "HVOC"
        let status = RegisterEventHotKey(keyCode, UInt32(optionKey | cmdKey), id, GetApplicationEventTarget(), 0, &ref)
        if status != noErr { log("⚠ could not register \(label) (\(status)); click the orb to mute") }
    }
}
