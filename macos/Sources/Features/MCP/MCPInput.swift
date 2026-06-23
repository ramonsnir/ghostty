// (ramon fork) MCP input injection: real key events (ghostty_surface_key), text
// typing, and mouse-wheel scroll. The KeySpec table + keySpecs mappers are COPIED
// verbatim from the web monitor (the native-keycode discipline is load-bearing);
// the HTTP-body parsers are intentionally NOT copied — the MCP layer hands typed
// arguments, so it parses nothing here.

import Foundation
import AppKit
import GhosttyKit

enum MCPInput {
    // MARK: - Key event specs (real keypresses, not paste)

    /// A single key event to replay on a surface. PURE/value-type so the
    /// argument->events mapping is unit-testable without AppKit or a surface.
    struct KeySpec: Equatable {
        /// NATIVE macOS virtual keycode. `ghostty_input_key_s.keycode` is matched
        /// against `input.keycodes` `entry.native` to resolve the physical key, so
        /// this MUST be the platform keycode (NSEvent.keyCode space: Return=36,
        /// Esc=53, …), NOT a GHOSTTY_KEY_* enum value. 0 = none (text-bearing
        /// event; the char rides `text`).
        var keycode: UInt32
        var mods: ghostty_input_mods_e
        var text: String?
        var unshiftedCodepoint: UInt32

        init(
            keycode: UInt32 = 0,
            mods: ghostty_input_mods_e = GHOSTTY_MODS_NONE,
            text: String? = nil,
            unshiftedCodepoint: UInt32 = 0
        ) {
            self.keycode = keycode
            self.mods = mods
            self.text = text
            self.unshiftedCodepoint = unshiftedCodepoint
        }

        /// Build a `ghostty_input_key_s` for this spec (press then release) and
        /// hand it to `ghostty_surface_key`. MUST be called on the main thread.
        func send(to surface: ghostty_surface_t) {
            sendOne(action: GHOSTTY_ACTION_PRESS, to: surface)
            sendOne(action: GHOSTTY_ACTION_RELEASE, to: surface)
        }

        private func sendOne(action: ghostty_input_action_e, to surface: ghostty_surface_t) {
            var key_ev = ghostty_input_key_s()
            key_ev.action = action
            key_ev.keycode = keycode
            key_ev.mods = mods
            key_ev.consumed_mods = GHOSTTY_MODS_NONE
            key_ev.unshifted_codepoint = unshiftedCodepoint
            key_ev.composing = false
            // Encode text only on PRESS, and only when it is not a single control
            // character (control chars are encoded by Ghostty itself).
            if action == GHOSTTY_ACTION_PRESS,
               let text, text.count > 0,
               let codepoint = text.utf8.first, codepoint >= 0x20 {
                text.withCString { ptr in
                    key_ev.text = ptr
                    _ = ghostty_surface_key(surface, key_ev)
                }
            } else {
                key_ev.text = nil
                _ = ghostty_surface_key(surface, key_ev)
            }
        }
    }

    /// PURE: map a named key command to a single key-event spec. Unknown -> nil.
    /// The schema enum uses `escape`; `esc` is also accepted (alias).
    static func keySpecs(forKey key: String) -> [KeySpec]? {
        switch key {
        // NATIVE macOS virtual keycodes (NSEvent.keyCode space) — see KeySpec.keycode.
        case "enter": return [KeySpec(keycode: 36)]
        case "esc", "escape": return [KeySpec(keycode: 53)]
        case "tab": return [KeySpec(keycode: 48)]
        case "backspace": return [KeySpec(keycode: 51)]
        case "ctrl-c": return [KeySpec(keycode: 8, mods: GHOSTTY_MODS_CTRL,
                                       unshiftedCodepoint: UInt32(UnicodeScalar("c").value))]
        case "ctrl-u": return [KeySpec(keycode: 32, mods: GHOSTTY_MODS_CTRL,
                                       unshiftedCodepoint: UInt32(UnicodeScalar("u").value))]
        // ctrl-d = shell EOF; the Agent Queue's default exit key (§10). keycode 2 = 'd'.
        case "ctrl-d": return [KeySpec(keycode: 2, mods: GHOSTTY_MODS_CTRL,
                                       unshiftedCodepoint: UInt32(UnicodeScalar("d").value))]
        case "up": return [KeySpec(keycode: 126)]
        case "down": return [KeySpec(keycode: 125)]
        case "left": return [KeySpec(keycode: 123)]
        case "right": return [KeySpec(keycode: 124)]
        case "y": return keySpecs(forText: "y")
        case "n": return keySpecs(forText: "n")
        case "space": return keySpecs(forText: " ")
        default: return nil
        }
    }

    /// PURE: map literal text to one key-event spec per printable run. A printable
    /// run rides one text-bearing event's `text`; a newline (`\n`/`\r`) becomes a
    /// REAL Enter key event (keycode 36), so a submit actually submits.
    static func keySpecs(forText text: String) -> [KeySpec] {
        var specs: [KeySpec] = []
        var run = ""
        func flushRun() {
            guard !run.isEmpty else { return }
            let scalars = Array(run.unicodeScalars)
            let usc: UInt32 = scalars.count == 1 ? scalars[0].value : 0
            specs.append(KeySpec(text: run, unshiftedCodepoint: usc))
            run = ""
        }
        for ch in text {
            if ch == "\n" || ch == "\r" {
                flushRun()
                specs.append(KeySpec(keycode: 36))  // native macOS Return
            } else {
                run.append(ch)
            }
        }
        flushRun()
        return specs
    }

    /// PURE: collapse ALL newlines (interior + leading/trailing) in `text` into
    /// single spaces and trim, producing a strictly single-line string. This is the
    /// load-bearing safety guard for the Phase-2.1 Approve path: `keySpecs(forText:)`
    /// turns every embedded `\n`/`\r` into a REAL Return key event (native keycode 36),
    /// which SUBMITS. Approve now intentionally submits in one tap — but it must send
    /// exactly ONE trailing Return, not one per interior newline. Running a multi-line
    /// suggestion through this first STRIPS the INTERIOR newlines so `keySpecs(forText:)`
    /// emits no Return at all; the single intended submit is then the `submit:true`
    /// APPENDED Return in `sendText`. So this guard turns N partial submits into the
    /// one intended submit — it does NOT (any longer) suppress the submit itself.
    static func singleLine(_ text: String) -> String {
        return text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Scroll delta (pure, testable)

    /// PURE: clamp a wheel-tick delta to a sane range. nil on a zero delta (a
    /// no-op the caller turns into a tool error). Positive = scroll back/up; the
    /// sign is preserved and passed DIRECTLY to `ghostty_surface_mouse_scroll`
    /// (no inversion).
    static func scrollDeltaClamped(_ dy: Double) -> Double? {
        guard dy != 0 else { return nil }
        return max(-30, min(30, dy))
    }

    // MARK: - Main-thread injectors

    /// Type text (and optionally submit with a trailing Return). MUST be called
    /// inside `DispatchQueue.main.sync`. Returns false if the uuid does not resolve.
    static func sendText(uuid: UUID, text: String, submit: Bool) -> Bool {
        guard let (controller, view) = MCPLayout.controllerAndView(forUUID: uuid),
              let surface = view.surface else { return false }
        MCPLayout.revealIfZoomedAway(controller, view)
        var specs = keySpecs(forText: text)
        if submit { specs.append(KeySpec(keycode: 36)) }
        for spec in specs { spec.send(to: surface) }
        return true
    }

    /// Send a single named key. MUST be called inside `DispatchQueue.main.sync`.
    /// Returns nil on an unknown key (so the caller emits a precise tool error),
    /// false if the uuid does not resolve, true on success.
    static func sendKey(uuid: UUID, key: String) -> Bool? {
        guard let specs = keySpecs(forKey: key) else { return nil }
        guard let (controller, view) = MCPLayout.controllerAndView(forUUID: uuid),
              let surface = view.surface else { return false }
        MCPLayout.revealIfZoomedAway(controller, view)
        for spec in specs { spec.send(to: surface) }
        return true
    }

    /// Scroll by a (clamped) wheel-tick delta. MUST be called inside
    /// `DispatchQueue.main.sync`. Returns false if the uuid does not resolve.
    static func scroll(uuid: UUID, dy: Double) -> Bool {
        guard let (controller, view) = MCPLayout.controllerAndView(forUUID: uuid),
              let surface = view.surface else { return false }
        MCPLayout.revealIfZoomedAway(controller, view)
        ghostty_surface_mouse_scroll(surface, 0, dy, 0)
        return true
    }
}
