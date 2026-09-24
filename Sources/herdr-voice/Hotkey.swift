import Carbon.HIToolbox

/// Global hotkeys through Carbon, which needs no Accessibility permission.
/// Mute is ⌥⌘M (override the key with HERDR_VOICE_HOTKEY_KEYCODE, modifiers stay ⌥⌘).
/// Esc is only grabbed while the assistant is speaking, so every other app keeps its Esc.
enum Hotkey {
    static let label = "⌥⌘M"
    static let mute: UInt32 = 1
    static let stop: UInt32 = 2

    private static var handlers: [UInt32: () -> Void] = [:]
    private static var refs: [UInt32: EventHotKeyRef] = [:]
    private static var installed = false
    private static var warnedStop = false
    private static let debugKeys = ProcessInfo.processInfo.environment["HERDR_VOICE_DEBUG_KEYS"] == "1"

    private static func debug(_ line: String) { if debugKeys { log("⌨  " + line) } }

    static func registerMute(_ onPress: @escaping () -> Void) {
        let keyCode = UInt32(ProcessInfo.processInfo.environment["HERDR_VOICE_HOTKEY_KEYCODE"] ?? "") ?? UInt32(kVK_ANSI_M)
        if !register(id: mute, keyCode: keyCode, modifiers: UInt32(optionKey | cmdKey), onPress) {
            log("⚠ could not register \(label); click the orb to mute")
        }
    }

    /// Grabs plain Esc while `active`, releases it otherwise. Cheap to call every frame.
    static func setStopKey(active: Bool, _ onPress: @escaping () -> Void) {
        if active, refs[stop] == nil {
            if register(id: stop, keyCode: UInt32(kVK_Escape), modifiers: 0, onPress) {
                debug("Esc grabbed")
            } else if !warnedStop {
                warnedStop = true
                log("⚠ could not grab Esc; say \"stop\" or talk over the voice instead")
            }
        } else if !active, let ref = refs.removeValue(forKey: stop) {
            UnregisterEventHotKey(ref)
            handlers[stop] = nil
            debug("Esc released")
        }
    }

    @discardableResult
    private static func register(id: UInt32, keyCode: UInt32, modifiers: UInt32, _ onPress: @escaping () -> Void) -> Bool {
        installHandlerOnce()
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4856_4F43), id: id) // "HVOC"
        guard RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref) == noErr, let ref
        else { return false }
        refs[id] = ref
        handlers[id] = onPress
        return true
    }

    private static func installHandlerOnce() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            Hotkey.handlers[id.id]?()
            return noErr
        }, 1, &spec, nil, nil)
    }
}
