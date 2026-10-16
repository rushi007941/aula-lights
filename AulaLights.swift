// AULA Lights — control the AULA F75's backlight from the Mac menu bar or the command line.
//
// Works over the USB-C cable only (USB 258A:010C). Bluetooth can't carry lighting
// commands, and the 2.4 GHz receiver uses a different protocol (not supported yet).
//
// Protocol notes (cross-checked against the Windows driver's KB.ini and two
// open-source projects: daschinmoy21/aula-f75-linux and mohithingorani/aula-macos-software):
//   - Everything goes through 520-byte HID feature reports with report ID 6.
//   - The 128-byte settings block is always read, patched and written back whole.
//     Rebuilding it from scratch is known to break the keyboard's Fn shortcuts.
//   - Every write is read back to verify it; on a mismatch the originals are restored.
//
// Usage:
//   AulaLights                     open the menu bar app
//   AulaLights status              print the current lighting
//   AulaLights effects             list the effects
//   AulaLights set [--effect NAME|NUMBER] [--color RRGGBB] [--rainbow on|off]
//                  [--brightness 0-9] [--speed 0-4]
//   AulaLights off                 turn the lighting off

import AppKit
import Foundation
import IOKit.hid
import SwiftUI

// MARK: - Model

struct RGB: Hashable, Codable {
    var r: UInt8, g: UInt8, b: UInt8

    var hex: String { String(format: "%02X%02X%02X", r, g, b) }

    init(r: UInt8, g: UInt8, b: UInt8) { self.r = r; self.g = g; self.b = b }

    init?(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(r: UInt8(v >> 16 & 0xFF), g: UInt8(v >> 8 & 0xFF), b: UInt8(v & 0xFF))
    }
}

// Names and IDs from the Windows driver (text.xml + KB.ini "LedOpt" rows).
enum Effect: Int, CaseIterable, Identifiable {
    case off = 0, fixedOn, respire, rainbow, flashAway, raindrops, rainbowWheel, ripplesShining,
         starsTwinkle, shadowDisappear, retroSnake, neonStream, reaction, sineWave, retinueScanning,
         rotatingWindmill, colorfulWaterfall, blossoming, rotatingStorm
    case perKey = 21  // host-driven per-key colours (the typing ripple)

    var id: Int { rawValue }

    /// Effects the keyboard renders itself (what the effect grid shows).
    static var builtIn: [Effect] { allCases.filter { $0 != .off && $0 != .perKey } }

    var title: String {
        if self == .perKey { return "Per-key (ripple)" }
        return ["Off", "Steady", "Breathing", "Rainbow", "Flash away", "Raindrops", "Rainbow wheel",
         "Ripples", "Stars twinkle", "Shadow disappear", "Retro snake", "Neon stream", "Reaction",
         "Sine wave", "Scanning", "Rotating windmill", "Colourful waterfall", "Blossoming",
         "Rotating storm"][rawValue]
    }

    // KB.ini last LedOpt column: whether the effect takes a single chosen colour.
    var supportsColor: Bool { [1, 2, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 18].contains(rawValue) }

    static func parse(_ text: String) -> Effect? {
        if let n = Int(text) { return Effect(rawValue: n) }
        let key = { (s: String) in s.lowercased().filter { $0.isLetter } }
        let wanted = key(text)
        let aliases: [String: Effect] = ["static": .fixedOn, "fixedon": .fixedOn, "solid": .fixedOn,
                                         "respire": .respire, "breathe": .respire]
        return aliases[wanted] ?? allCases.first { key($0.title) == wanted || key("\($0)") == wanted }
    }
}

struct LightState: Equatable {
    var effect: Effect
    var brightness: Int  // 0-9
    var speed: Int       // 0-4
    var rainbow: Bool    // multicolour instead of the chosen colour
    var color: RGB

    var summary: String {
        var parts = ["\(effect.title)"]
        if effect != .off {
            parts.append("brightness \(brightness)/9")
            parts.append("speed \(speed)/4")
            if effect.supportsColor { parts.append(rainbow ? "rainbow" : "colour #\(color.hex)") }
        }
        return parts.joined(separator: ", ")
    }
}

enum AulaError: LocalizedError {
    case notFound, bluetoothLimited, needsPermission(String), openFailed(IOReturn), io(String, IOReturn), badReply(String), verifyFailed(String)

    var errorDescription: String? {
        switch self {
        case .notFound:
            "AULA F75 not found. Connect it with the USB-C cable or the 2.4 GHz receiver (Bluetooth can't change the lighting)."
        case .bluetoothLimited:
            "Over Bluetooth the keyboard doesn't share its full settings, so lighting can't be changed safely. Use the cable or the 2.4 GHz receiver."
        case .needsPermission(let state):
            "macOS blocked access (Input Monitoring: \(state)). Allow Aula Lights in System Settings → Privacy & Security → Input Monitoring, then reopen it."
        case .openFailed(let r): "Couldn't open the keyboard (error 0x\(String(UInt32(bitPattern: r), radix: 16)))."
        case .io(let what, let r): "\(what) failed (error 0x\(String(UInt32(bitPattern: r), radix: 16)))."
        case .badReply(let what): "The keyboard sent an unexpected reply to \(what)."
        case .verifyFailed(let what): "\(what) didn't stick, so the previous lighting was restored."
        }
    }
}

// MARK: - Device

final class F75 {
    static let vendorID = 0x258A
    static let productID = 0x010C
    static let reportID: UInt8 = 6
    static let reportLength = 520

    // Settings block (128 bytes, offsets exclude the 8-byte header)
    static let effectByte = 10, customFlagByte = 9
    static func brightnessByte(_ e: Effect) -> Int { 56 + 2 * e.rawValue }
    static func flagsByte(_ e: Effect) -> Int { 57 + 2 * e.rawValue }  // high nibble speed, low nibble 7 = rainbow

    // Colour palette (512 bytes): per-effect RGB slots in four regions with reserved gaps.
    static let paletteRegions = [(21, 105), (147, 42), (210, 84), (315, 63)]

    private let device: IOHIDDevice

    private init(_ device: IOHIDDevice) { self.device = device }
    deinit { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }

    /// Is the keyboard plugged in over USB? Reads the device list only, so it needs no permission.
    static func isPresent() -> Bool {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: vendorID, kIOHIDProductIDKey: productID] as CFDictionary)
        return !((IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []).isEmpty
    }

    static var accessGranted: Bool { IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted }

    static func open() throws -> F75 {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: vendorID, kIOHIDProductIDKey: productID] as CFDictionary)
        let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
        // The keyboard exposes several interfaces; the lighting one takes the big feature reports.
        let featureSize = { (d: IOHIDDevice) in
            (IOHIDDeviceGetProperty(d, kIOHIDMaxFeatureReportSizeKey as CFString) as? Int) ?? 0
        }
        guard let found = devices.filter({ featureSize($0) >= reportLength }).max(by: { featureSize($0) < featureSize($1) })
        else { throw AulaError.notFound }

        let result = IOHIDDeviceOpen(found, IOOptionBits(kIOHIDOptionsTypeNone))
        if result != kIOReturnSuccess {
            let access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
            if access != kIOHIDAccessTypeGranted {
                IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
                throw AulaError.needsPermission(access == kIOHIDAccessTypeDenied ? "denied" : "not decided yet")
            }
            throw AulaError.openFailed(result)
        }
        return F75(found)
    }

    // MARK: Low-level transport

    private func send(_ payload: [UInt8], settle: Bool = true) throws {
        var report = [UInt8](repeating: 0, count: F75.reportLength)
        report[0] = F75.reportID
        report.replaceSubrange(1..<(1 + payload.count), with: payload)
        let r = report.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, CFIndex(F75.reportID), $0.baseAddress!, $0.count)
        }
        guard r == kIOReturnSuccess else { throw AulaError.io("Sending to the keyboard", r) }
        if settle { usleep(20_000) }
    }

    /// Returns the reply without the report ID byte.
    private func receive() throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: F75.reportLength)
        buffer[0] = F75.reportID
        var length = buffer.count
        let r = buffer.withUnsafeMutableBufferPointer {
            IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, CFIndex(F75.reportID), $0.baseAddress!, &length)
        }
        guard r == kIOReturnSuccess else { throw AulaError.io("Reading from the keyboard", r) }
        return Array(buffer[1..<length])
    }

    // MARK: Settings block and palette

    /// The firmware sometimes returns a truncated, mostly-zero block while busy.
    /// Writing that back would wipe the settings, so only blocks ending in 5A A5 count.
    static func validSettings(_ block: [UInt8]) -> Bool { block.count == 128 && block[126] == 0x5A && block[127] == 0xA5 }

    func readSettings() throws -> [UInt8] {
        let command: [UInt8] = [0x84, 0, 0, 1, 0, 0x80]
        for _ in 0..<4 {
            try send(command)
            let rx = try receive()
            if rx.count >= 135, Array(rx[0..<6]) == command {
                let block = Array(rx[7..<135])
                if F75.validSettings(block) { return block }
            }
            usleep(100_000)
        }
        throw AulaError.badReply("the settings read")
    }

    func writeSettings(_ settings: [UInt8]) throws {
        guard F75.validSettings(settings) else { throw AulaError.badReply("the settings check (refusing to write)") }
        try send([0x04, 0, 0, 1, 0, 0x80, 0] + settings)
    }

    // MARK: Per-key streaming (used by the ripple)

    /// Switches to per-key mode and returns the previous settings so they can be restored.
    /// Mode bytes from keylux's captures: all three matter, or the board goes dark.
    func enterPerKeyMode() throws -> [UInt8] {
        let original = try readSettings()
        var s = original
        s[9] = 0x01; s[10] = 0x15; s[59] = 0x47
        try writeSettings(s)
        usleep(400_000)  // the firmware repaints asynchronously after a settings write
        return original
    }

    func restoreSettings(_ original: [UInt8]) throws {
        try writeSettings(original)
        usleep(100_000)
        let back = try readSettings()
        guard back[9] == original[9], back[10] == original[10] else { throw AulaError.verifyFailed("Restoring the lighting") }
    }

    /// One live frame: 126 LEDs, interleaved RGB (378 bytes). The caller paces these
    /// at least 46 ms apart; faster starves the keyboard's key scanning.
    func streamFrame(_ rgb: [UInt8]) throws {
        precondition(rgb.count == 378)
        try send([0x08, 0, 0, 1, 0, 0x7A, 0x01] + rgb, settle: false)
    }

    func readPalette() throws -> [UInt8] {
        let command: [UInt8] = [0x8A, 0, 0, 1, 0, 0x80, 2]
        try send(command)
        let rx = try receive()
        guard rx.count >= 519, Array(rx[0..<5]) == Array(command[0..<5]) else { throw AulaError.badReply("the colour read") }
        return Array(rx[7..<519])
    }

    func writePalette(_ palette: [UInt8]) throws {
        precondition(palette.count == 512)
        var payload: [UInt8] = [0x0A, 0, 0, 1, 0, 0, 2] + palette
        payload[513] = 0x5A
        payload[514] = 0xA5
        try send(payload)
    }

    // MARK: High level

    func state() throws -> LightState {
        let s = try readSettings()
        let palette = try readPalette()
        let effect = Effect(rawValue: Int(s[F75.effectByte])) ?? .off
        let shown = effect == .off ? Effect.fixedOn : effect  // show something sensible for "off"
        let flags = s[F75.flagsByte(shown)]
        return LightState(effect: effect,
                          brightness: min(Int(s[F75.brightnessByte(shown)]), 9),
                          speed: min(Int(flags >> 4), 4),
                          rainbow: flags & 0x0F == 7,
                          color: RGB(r: palette[21], g: palette[22], b: palette[23]))
    }

    func apply(_ target: LightState) throws {
        let originalSettings = try readSettings()
        var settings = originalSettings
        settings[F75.customFlagByte] = 0
        settings[F75.effectByte] = UInt8(target.effect.rawValue)
        if target.effect != .off {
            let b = F75.brightnessByte(target.effect), f = F75.flagsByte(target.effect)
            settings[b] = UInt8(min(max(target.brightness, 0), 9))
            var low = settings[f] & 0x0F
            if target.effect.supportsColor { low = target.rainbow ? 7 : 0 }
            settings[f] = UInt8(min(max(target.speed, 0), 4)) << 4 | low
        }

        let changesColor = target.effect.supportsColor && !target.rainbow
        let originalPalette = changesColor ? try readPalette() : nil
        var palette = originalPalette
        if palette != nil {
            for (start, count) in F75.paletteRegions {
                for i in stride(from: start, to: start + count, by: 3) {
                    palette![i] = target.color.r; palette![i + 1] = target.color.g; palette![i + 2] = target.color.b
                }
            }
        }

        do {
            if let palette {
                try writePalette(palette)
                usleep(60_000)
            }
            try writeSettings(settings)

            // Verify only the bytes we meant to change; the firmware may normalise others.
            let after = try readSettings()
            var checked = [F75.effectByte]
            if target.effect != .off { checked += [F75.brightnessByte(target.effect), F75.flagsByte(target.effect)] }
            guard checked.allSatisfy({ after[$0] == settings[$0] }) else { throw AulaError.verifyFailed("The lighting change") }
            if let palette {
                let back = try readPalette()
                guard F75.paletteRegions.allSatisfy({ back[$0.0..<($0.0 + $0.1)] == palette[$0.0..<($0.0 + $0.1)] })
                else { throw AulaError.verifyFailed("The colour change") }
            }
        } catch {
            if let originalPalette { try? writePalette(originalPalette) }
            try? writeSettings(originalSettings)
            throw error
        }
    }
}

// MARK: - Command line

enum CLI {
    static func run(_ args: [String]) -> Int32 {
        do {
            switch args.first {
            case "status":
                let kb = try Keyboard.open()
                print("\(try kb.state().summary)  [\(kb.connectionName)]")
            case "effects":
                for e in [Effect.off] + Effect.builtIn {
                    print(String(format: "%2d  %@%@", e.rawValue, e.title, e.supportsColor ? "  (colour)" : ""))
                }
            case "probe-bt-live":
                // Bluetooth only: flashes every key red/blue for 2 s with live-colour messages.
                // These never write settings; the built-in effect resumes afterwards.
                let link = try WirelessLink.open(productIDs: [WirelessLink.bluetoothProductID])
                let all = Layout.keys.map(\.led)
                let started = Date()
                var sent = 0
                for i in 0..<20 {
                    let c = i % 2 == 0 ? RGB(r: 255, g: 0, b: 0) : RGB(r: 0, g: 64, b: 255)
                    let msg = WirelessLink.liveMessage([(c, all)])
                    try link.sendLive(msg)
                    sent += msg.count
                    Thread.sleep(forTimeInterval: max(0, 0.1 - Double(msg.count) * 0.012))
                }
                print(String(format: "Sent %d parts over Bluetooth in %.1f s, no errors.", sent, Date().timeIntervalSince(started)))
            case "probe-bt-speed":
                // Bluetooth only: a burst of red/blue flashes sent without waiting on each write,
                // timed; then the whole board painted green and left. Writes no settings.
                let link = try WirelessLink.open(productIDs: [WirelessLink.bluetoothProductID])
                let all = Layout.keys.map(\.led)
                var burst: [[UInt8]] = []
                for i in 0..<10 { burst += WirelessLink.liveMessage([(i % 2 == 0 ? RGB(r: 255, g: 0, b: 0) : RGB(r: 0, g: 64, b: 255), all)]) }
                let t0 = Date()
                let r = link.sendPipelined(burst, gap: 0.004)
                let dt = Date().timeIntervalSince(t0)
                print(String(format: "Burst: %d parts sent, %d failed, in %.2f s = %.0f parts/s", r.done, r.failed, dt, Double(r.done) / dt))
                _ = link.sendPipelined(WirelessLink.liveMessage([(RGB(r: 0, g: 255, b: 48), all)]), gap: 0.012)
                print("Board painted green. Watch whether it stays.")
            case "selftest-radio":
                // Offline: builds receiver live messages for the examples captured in keylux's notes.
                let hex = { (r: [UInt8]) in r.map { String(format: "%02x", $0) }.joined(separator: " ") }
                for r in WirelessLink.liveMessage([(RGB(r: 0, g: 0xFF, b: 0xFF), [0x37])]) { print(hex(r)) }
                for r in WirelessLink.liveMessage([(RGB(r: 0, g: 0, b: 0xFF), [0x24, 0x2A])]) { print(hex(r)) }
                for r in WirelessLink.liveMessage([(RGB(r: 0, g: 0xFF, b: 0xFF), [0x43]), (RGB(r: 0xFF, g: 0xFF, b: 0), [0x27])]) { print(hex(r)) }
            case "probe-wireless":
                // Read-only: asks the receiver or the Bluetooth keyboard for its settings, prints the replies.
                let link = try WirelessLink.open()
                print(String(format: "Opened 3554:%04X (%@)", link.productID, link.productID == WirelessLink.bluetoothProductID ? "Bluetooth" : "2.4 GHz receiver"))
                let replies = try link.readConfigProbe()
                if replies.isEmpty { print("No reply.") }
                for r in replies { print(r.map { String(format: "%02X", $0) }.joined(separator: " ")) }
            case "restore":
                // Recovery if the app quit mid-ripple and left the keyboard in per-key mode.
                guard let saved = try? Data(contentsOf: LiveEngine.backupURL) else { return fail("No saved lighting to restore.") }
                try F75.open().restoreSettings([UInt8](saved))
                try? FileManager.default.removeItem(at: LiveEngine.backupURL)
                print("Restored the lighting from before the ripple.")
            case "off":
                let kb = try Keyboard.open()
                var s = try kb.state()
                if s.effect == .perKey { return fail(liveModeRunning) }
                s.effect = .off
                try kb.apply(s)
                print("Lighting off.")
            case "set":
                // Validate everything before touching the keyboard.
                var edits: [(inout LightState) -> Void] = []
                var i = 1
                while i < args.count {
                    let flag = args[i], value = i + 1 < args.count ? args[i + 1] : ""
                    switch flag {
                    case "--effect": guard let e = Effect.parse(value) else { return fail("Unknown effect '\(value)'. Try: effects") }; edits.append { $0.effect = e }
                    case "--color", "--colour": guard let c = RGB(hex: value) else { return fail("Colour must look like 00AAFF") }; edits.append { $0.color = c; $0.rainbow = false }
                    case "--rainbow": let on = ["on", "true", "yes", "1"].contains(value.lowercased()); edits.append { $0.rainbow = on }
                    case "--brightness": guard let n = Int(value), (0...9).contains(n) else { return fail("Brightness is 0-9") }; edits.append { $0.brightness = n }
                    case "--speed": guard let n = Int(value), (0...4).contains(n) else { return fail("Speed is 0-4") }; edits.append { $0.speed = n }
                    default: return fail("Unknown option \(flag)")
                    }
                    i += 2
                }
                let kb = try Keyboard.open()
                var s = try kb.state()
                if s.effect == .perKey { return fail(liveModeRunning) }
                for edit in edits { edit(&s) }
                try kb.apply(s)
                Controller.lastColor = s.color  // the receiver can't report it back
                print("Set: \(try kb.state().summary)")
            default:
                print("""
                usage: AulaLights status | effects | off | restore
                       AulaLights set [--effect NAME|NUMBER] [--color RRGGBB] [--rainbow on|off]
                                      [--brightness 0-9] [--speed 0-4]
                Run with no arguments to open the menu bar app.
                """)
            }
            return 0
        } catch {
            return fail(error.localizedDescription)
        }
    }

    /// Aula Lights is streaming to the keyboard; writing settings now would fight it.
    static let liveModeRunning = "A live mode (ripple, heatmap or game) is showing on the keyboard. Turn off \"Show on the keyboard\" in Aula Lights first."

    static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data("Error: \(message)\n".utf8))
        return 1
    }
}
