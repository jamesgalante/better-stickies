import Carbon.HIToolbox

/// A system-wide hotkey via Carbon's RegisterEventHotKey — the one global
/// shortcut API that needs no Accessibility permission. The handler fires
/// on key-down regardless of which app is frontmost.
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let handler: () -> Void

    init?(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        self.handler = handler

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        // C callback: no captures allowed, so self travels through userData.
        let callback: EventHandlerUPP = { _, _, userData in
            guard let userData else { return noErr }
            Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue().handler()
            return noErr
        }
        guard InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventType,
                                  Unmanaged.passUnretained(self).toOpaque(),
                                  &handlerRef) == noErr else { return nil }

        let hotKeyID = EventHotKeyID(signature: OSType(0x5354_4B59) /* 'STKY' */, id: 1)
        guard RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                  GetApplicationEventTarget(), 0, &hotKeyRef) == noErr,
              hotKeyRef != nil else {
            if let handlerRef { RemoveEventHandler(handlerRef) }
            return nil
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
