// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import AppKit
import Carbon.HIToolbox
import JotCore

/// A system-wide shortcut through Carbon's hot key API: no Accessibility or
/// Input Monitoring prompt, and the keystroke never reaches other apps.
@MainActor
final class GlobalHotKey {
    struct Combo: Codable, Equatable {
        var keyCode: UInt32
        var modifiers: UInt32

        static let openScratchpad = Combo(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(optionKey))

        var display: String {
            var parts = ""
            if modifiers & UInt32(controlKey) != 0 { parts += "⌃" }
            if modifiers & UInt32(optionKey) != 0 { parts += "⌥" }
            if modifiers & UInt32(shiftKey) != 0 { parts += "⇧" }
            if modifiers & UInt32(cmdKey) != 0 { parts += "⌘" }
            return parts + Self.keyName(keyCode)
        }

        init(keyCode: UInt32, modifiers: UInt32) {
            self.keyCode = keyCode
            self.modifiers = modifiers
        }

        init?(event: NSEvent) {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            var carbon: UInt32 = 0
            if flags.contains(.control) { carbon |= UInt32(controlKey) }
            if flags.contains(.option) { carbon |= UInt32(optionKey) }
            if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
            if flags.contains(.command) { carbon |= UInt32(cmdKey) }
            guard carbon & UInt32(controlKey | optionKey | cmdKey) != 0 else { return nil }
            self.init(keyCode: UInt32(event.keyCode), modifiers: carbon)
        }

        static func keyName(_ code: UInt32) -> String {
            guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
                  let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "?" }
            let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
            var dead: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = data.withUnsafeBytes { raw -> OSStatus in
                guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
                return UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                      OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &length, &chars)
            }
            guard status == noErr, length > 0 else { return "?" }
            return String(utf16CodeUnits: chars, count: length).uppercased()
        }
    }

    private static var handlers: [UInt32: () -> Void] = [:]
    private static var installed = false
    private var reference: EventHotKeyRef?
    private let id: UInt32

    init(id: UInt32) {
        self.id = id
    }

    func register(_ combo: Combo, action: @escaping () -> Void) {
        unregister()
        Self.installHandlerIfNeeded()
        Self.handlers[id] = action
        let hotKeyID = EventHotKeyID(signature: OSType(0x4A4F5421), id: id)
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &reference)
        if status != noErr {
            Log.hotkey.error("global hot key \(combo.display, privacy: .public) FAILED to register: \(status)")
        } else {
            Log.hotkey.info("global hot key \(combo.display, privacy: .public) registered")
        }
    }

    func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil
        Self.handlers[id] = nil
    }

    private static func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            Log.hotkey.info("global hot key \(id) pressed")
            DispatchQueue.main.async { GlobalHotKey.handlers[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
