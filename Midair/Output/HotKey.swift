import Carbon.HIToolbox

/// A global keyboard shortcut via Carbon `RegisterEventHotKey`: needs no extra permissions.
@MainActor
final class HotKey {
    private static var nextID: UInt32 = 1

    private let id: UInt32
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: @MainActor () -> Void

    init(keyCode: Int, modifiers: Int, action: @escaping @MainActor () -> Void) {
        id = Self.nextID
        Self.nextID += 1
        self.action = action
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var pressed = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            let hotKey = Unmanaged<HotKey>.fromOpaque(context).takeUnretainedValue()
            return MainActor.assumeIsolated {
                // The handler is installed app-wide: someone else's shortcut goes on to the next handler.
                guard pressed.id == hotKey.id else { return OSStatus(eventNotHandledErr) }
                hotKey.action()
                return noErr
            }
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)

        let hotKeyID = EventHotKeyID(signature: OSType(0x4D44_4152), id: id)
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }
}
