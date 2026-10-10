//
//  KeyCharacters.swift
//  ShrikeUI
//
//  The one place that reads the typed character of a key event.
// On a non-Latin layout (Russian, Greek, Hebrew…) the Q
//  key types "й", so a plain-letter shortcut row ("q" = Flag) never
//  matched. When the typed character is not ASCII, the key's character
//  on the current ASCII-capable layout is used instead — what AppKit
//  does for menu key equivalents. Latin layouts (US, AZERTY, QWERTZ)
//  keep matching by the character they type.
//

import AppKit
import Carbon.HIToolbox

/// The character a key code gives on an ASCII-capable layout. A
/// protocol so tests can give a fixed map (the test machine's layout
/// must not decide the result).
@MainActor
public protocol ASCIIKeyLayout: AnyObject {
    /// nil = the key types nothing there (or a dead key).
    func character(keyCode: UInt16, shift: Bool) -> String?
}

@MainActor
public enum KeyCharacters {

    /// The layout used for the fallback. Tests swap in a fixed map and
    /// put `SystemASCIIKeyLayout.shared` back in teardown.
    public static var asciiLayout: any ASCIIKeyLayout = SystemASCIIKeyLayout.shared

    /// `charactersIgnoringModifiers` (⇧ still applies: ⇧/ = "?"), with
    /// the ASCII fallback for a non-Latin character. Not lowercased.
    public static func key(of event: NSEvent) -> String {
        resolve(typed: event.charactersIgnoringModifiers ?? "", keyCode: event.keyCode,
                shift: event.modifierFlags.contains(.shift))
    }

    /// The key with no modifiers at all (⇧1 → "1"), same fallback.
    public static func unshiftedKey(of event: NSEvent) -> String {
        resolve(typed: event.characters(byApplyingModifiers: []) ?? "", keyCode: event.keyCode, shift: false)
    }

    /// `typed` as is when it is ASCII (or a Cocoa function key,
    /// U+F700–U+F8FF), else the ASCII layout's character for `keyCode`.
    public static func resolve(typed: String, keyCode: UInt16, shift: Bool) -> String {
        guard needsFallback(typed) else { return typed }
        return asciiLayout.character(keyCode: keyCode, shift: shift) ?? typed
    }

    static func needsFallback(_ typed: String) -> Bool {
        var nonASCII = false
        for scalar in typed.unicodeScalars where !scalar.isASCII {
            if (0xF700...0xF8FF).contains(scalar.value) { return false }
            nonASCII = true
        }
        return nonASCII
    }
}

/// The current ASCII-capable keyboard layout (the Latin layout macOS
/// uses for ⌘ keys), read with `UCKeyTranslate`. Each key code is
/// translated once per input source; the cache is cleared when the user
/// switches input sources, so a key press costs a dictionary lookup.
@MainActor
public final class SystemASCIIKeyLayout: ASCIIKeyLayout {

    public static let shared = SystemASCIIKeyLayout()

    /// keyCode << 1 | shift → character ("" = the key types nothing).
    private var cache: [UInt32: String] = [:]
    private var layoutData: CFData?
    private var loaded = false
    private var observer: (any NSObjectProtocol)?

    private init() {}

    public func character(keyCode: UInt16, shift: Bool) -> String? {
        let slot = UInt32(keyCode) << 1 | (shift ? 1 : 0)
        if let hit = cache[slot] { return hit.isEmpty ? nil : hit }
        let value = translate(keyCode: keyCode, shift: shift) ?? ""
        cache[slot] = value
        return value.isEmpty ? nil : value
    }

    /// Drops the cached layout (input source changed).
    func reset() {
        cache.removeAll(keepingCapacity: true)
        layoutData = nil
        loaded = false
    }

    private func loadLayout() {
        loaded = true
        if observer == nil {
            let name = Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String)
            observer = DistributedNotificationCenter.default().addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.reset() }
            }
        }
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            layoutData = nil
            return
        }
        layoutData = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
    }

    private func translate(keyCode: UInt16, shift: Bool) -> String? {
        if !loaded { loadLayout() }
        guard let data = layoutData, let bytes = CFDataGetBytePtr(data) else { return nil }
        // UCKeyTranslate takes the Carbon modifier byte (EventRecord
        // modifiers >> 8).
        let modifiers: UInt32 = shift ? UInt32(shiftKey >> 8) & 0xFF : 0
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
            UCKeyTranslate(
                layout, keyCode, UInt16(kUCKeyActionDown), modifiers, UInt32(LMGetKbdType()),
                OptionBits(1 << kUCKeyTranslateNoDeadKeysBit), &deadKeyState,
                chars.count, &length, &chars
            )
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length)
    }
}
