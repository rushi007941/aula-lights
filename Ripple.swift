// Key layout, the ripple maths, and the input monitor.

import Foundation
import IOKit.hid

// MARK: - Key layout

struct KeyPos: Identifiable {
    let name: String
    let led: Int        // index in the 126-slot frame
    let usage: Int      // HID keyboard usage the key sends (-1 for Fn, which never reaches the Mac)
    let x: Double, y: Double  // centre, in key units
    let w: Double             // width, in key units
    var id: Int { led }
}

enum Layout {
    // LED order is the keyboard's column-major matrix order (from keylux, verified on hardware).
    static let ledOrder: [String?] = [
        "Esc", "`", "Tab", "Caps", "LShift", "LCtrl", nil,
        "1", "Q", "A", "Z", "LWin",
        "F1", "2", "W", "S", "X", "LAlt",
        "F2", "3", "E", "D", "C", nil,
        "F3", "4", "R", "F", "V", nil,
        "F4", "5", "T", "G", "B", "Space",
        "F5", "6", "Y", "H", "N", nil,
        "F6", "7", "U", "J", "M", nil,
        "F7", "8", "I", "K", ",", "Fn",
        "F8", "9", "O", "L", ".", "RCtrl",
        "F9", "0", "P", ";", "/", nil,
        "F10", "-", "[", "'", "RShift", nil,
        "F11", "=", "]", nil, nil, "Left",
        "F12", "Backspace", "\\", "Enter", "Up", "Down", nil,
        "Del", "PgUp", "PgDn", "End", "Right",
    ]

    // Physical rows of the F75 (widths in key units; "" is a gap).
    static let rows: [[(String, Double)]] = [
        [("Esc", 1), ("", 0.9), ("F1", 1), ("F2", 1), ("F3", 1), ("F4", 1), ("", 0.4), ("F5", 1), ("F6", 1), ("F7", 1),
         ("F8", 1), ("", 0.4), ("F9", 1), ("F10", 1), ("F11", 1), ("F12", 1), ("", 0.3), ("Knob", 1)],
        [("`", 1), ("1", 1), ("2", 1), ("3", 1), ("4", 1), ("5", 1), ("6", 1), ("7", 1), ("8", 1), ("9", 1), ("0", 1),
         ("-", 1), ("=", 1), ("Backspace", 2), ("Del", 1)],
        [("Tab", 1.5), ("Q", 1), ("W", 1), ("E", 1), ("R", 1), ("T", 1), ("Y", 1), ("U", 1), ("I", 1), ("O", 1), ("P", 1),
         ("[", 1), ("]", 1), ("\\", 1.5), ("PgUp", 1)],
        [("Caps", 1.75), ("A", 1), ("S", 1), ("D", 1), ("F", 1), ("G", 1), ("H", 1), ("J", 1), ("K", 1), ("L", 1),
         (";", 1), ("'", 1), ("Enter", 2.25), ("PgDn", 1)],
        [("LShift", 2.25), ("Z", 1), ("X", 1), ("C", 1), ("V", 1), ("B", 1), ("N", 1), ("M", 1), (",", 1), (".", 1),
         ("/", 1), ("RShift", 1.75), ("Up", 1), ("End", 1)],
        [("LCtrl", 1.25), ("LWin", 1.25), ("LAlt", 1.25), ("Space", 6.25), ("Fn", 1.25), ("RCtrl", 1.25), ("", 0.5),
         ("Left", 1), ("Down", 1), ("Right", 1)],
    ]

    static let usages: [String: Int] = {
        var u: [String: Int] = [
            "Esc": 0x29, "`": 0x35, "-": 0x2D, "=": 0x2E, "Backspace": 0x2A, "Del": 0x4C, "Tab": 0x2B,
            "[": 0x2F, "]": 0x30, "\\": 0x31, "PgUp": 0x4B, "Caps": 0x39, ";": 0x33, "'": 0x34, "Enter": 0x28,
            "PgDn": 0x4E, "LShift": 0xE1, ",": 0x36, ".": 0x37, "/": 0x38, "RShift": 0xE5, "Up": 0x52, "End": 0x4D,
            "LCtrl": 0xE0, "LWin": 0xE3, "LAlt": 0xE2, "Space": 0x2C, "RCtrl": 0xE4, "Left": 0x50, "Down": 0x51,
            "Right": 0x4F, "0": 0x27,
        ]
        for (i, c) in "ABCDEFGHIJKLMNOPQRSTUVWXYZ".enumerated() { u[String(c)] = 0x04 + i }
        for n in 1...9 { u[String(n)] = 0x1E + n - 1 }
        for n in 1...12 { u["F\(n)"] = 0x3A + n - 1 }
        return u
    }()

    static func rowY(_ row: Int) -> Double { Double(row) + (row > 0 ? 0.25 : 0) }

    static let keys: [KeyPos] = {
        var result: [KeyPos] = []
        for (row, entries) in rows.enumerated() {
            var x = 0.0
            for (name, width) in entries {
                if let led = ledOrder.firstIndex(where: { $0 == name }) {
                    result.append(KeyPos(name: name, led: led, usage: usages[name] ?? -1,
                                         x: x + width / 2, y: rowY(row), w: width))
                }
                x += width
            }
        }
        return result
    }()

    /// Centre of the volume knob, in key units.
    static let knob: (x: Double, y: Double) = {
        var x = 0.0
        for (name, width) in rows[0] {
            if name == "Knob" { return (x + width / 2, 0) }
            x += width
        }
        return (16, 0)
    }()

    static let width = 16.0   // board size in key units
    static let height = 6.25

    static let byUsage: [Int: KeyPos] = Dictionary(keys.filter { $0.usage >= 0 }.map { ($0.usage, $0) }, uniquingKeysWith: { a, _ in a })
}

// MARK: - Ripple

struct RippleSettings: Equatable, Codable {
    var color = RGB(r: 0, g: 170, b: 255)
    var rainbow = false
    var intensity = 0.9    // how bright the wave is (0-1)
    var speed = 7.0        // keys per second; slower keeps the ring visibly round on a 6-row board
    var spread = 7.0       // how far it reaches, in keys
    var width = 0.6        // ring thickness, in keys
    var rings = 1          // echo rings following the first one (1-3)
    var background = 0.06  // idle glow between presses (0-0.5)
}



typealias RGBf = (Double, Double, Double)

func hue(_ h: Double) -> RGBf {
    let h = h - floor(h)
    let i = Int(h * 6) % 6, f = h * 6 - Double(Int(h * 6))
    switch i {
    case 0: return (1, f, 0)
    case 1: return (1 - f, 1, 0)
    case 2: return (0, 1, f)
    case 3: return (0, 1 - f, 1)
    case 4: return (f, 0, 1)
    default: return (1, 0, 1 - f)
    }
}

/// Turns key presses into per-key colours. The same maths drives the keyboard and the
/// on-screen preview, so what you see in the app is what the keyboard shows.
struct RippleRenderer {
    var settings = RippleSettings()
    private var ripples: [(x: Double, y: Double, start: Double, hue: Double)] = []

    mutating func press(_ key: KeyPos, at t: Double) {
        ripples.append((key.x, key.y, t, (t * 0.13).truncatingRemainder(dividingBy: 1)))
        if ripples.count > 24 { ripples.removeFirst() }
    }

    mutating func clear() { ripples = [] }

    /// Linear 0-1 colour for every LED slot (126 of them).
    mutating func colors(at t: Double) -> [(Double, Double, Double)] {
        let s = settings
        let gap = 2.2 * s.width + 0.8  // spacing between echo rings
        let life = (s.spread + 3 * s.width + gap * Double(s.rings - 1)) / s.speed + 0.3
        ripples.removeAll { t - $0.start > life }
        let base = (Double(s.color.r) / 255, Double(s.color.g) / 255, Double(s.color.b) / 255)

        var out = [(Double, Double, Double)](repeating: (0, 0, 0), count: 126)
        for key in Layout.keys {
            var (r, g, b) = s.rainbow ? hue(key.x / 16) : base
            r *= s.background; g *= s.background; b *= s.background

            for ripple in ripples {
                let age = t - ripple.start
                let radius = s.speed * age
                let d = hypot(key.x - ripple.x, key.y - ripple.y)
                var ring = 0.0
                for echo in 0..<s.rings {
                    let r = radius - Double(echo) * gap
                    guard r > -s.width else { continue }
                    let fade = max(0, 1 - max(r, 0) / s.spread)
                    ring += exp(-pow(d - r, 2) / (2 * s.width * s.width)) * fade * pow(0.55, Double(echo))
                }
                let flash = d < 0.6 ? exp(-age * 9) : 0  // the pressed key itself lights up first
                let v = s.intensity * max(ring, flash)
                guard v > 0.002 else { continue }
                let c = s.rainbow ? hue(ripple.hue + d * 0.05) : base
                r += c.0 * v; g += c.1 * v; b += c.2 * v
            }
            out[key.led] = (min(r, 1), min(g, 1), min(b, 1))
        }
        return out
    }
}

// MARK: - Input monitor

/// Listens (without blocking anything) to the AULA keyboard: key presses for the drawing
/// and the ripple, and the knob, which sends volume up / down / mute.
final class InputMonitor {
    var onKey: ((Int, Bool) -> Void)?   // HID usage, pressed?
    var onKnob: ((Int) -> Void)?        // consumer usage: 0xE9 up, 0xEA down, 0xE2 mute
    private var manager: IOHIDManager?

    func start() {
        guard manager == nil else { return }
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matches: [[String: Any]] = [
            [kIOHIDVendorIDKey: F75.vendorID, kIOHIDProductIDKey: F75.productID],  // USB cable
            [kIOHIDVendorIDKey: 0x3554],                                             // Bluetooth / 2.4 GHz
        ]
        IOHIDManagerSetDeviceMatchingMultiple(m, matches as CFArray)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(m, { context, _, _, value in
            guard let context else { return }
            let monitor = Unmanaged<InputMonitor>.fromOpaque(context).takeUnretainedValue()
            let element = IOHIDValueGetElement(value)
            let usage = Int(IOHIDElementGetUsage(element))
            let pressed = IOHIDValueGetIntegerValue(value) == 1
            switch IOHIDElementGetUsagePage(element) {
            case UInt32(kHIDPage_KeyboardOrKeypad) where (0x04...0xE7).contains(usage):
                monitor.onKey?(usage, pressed)
            case UInt32(kHIDPage_Consumer) where pressed && [0xE9, 0xEA, 0xE2].contains(usage):
                monitor.onKnob?(usage)
            default: break
            }
        }, context)
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = m
    }
}
