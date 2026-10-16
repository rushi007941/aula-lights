// aula-remap — gives the AULA F75 a Mac layout: Alt becomes Command and Win becomes
// Option. Only the AULA keyboard is affected; the built-in MacBook keyboard is left alone.
//
// It watches the IOKit registry for the keyboard appearing (boot, wake, Bluetooth
// reconnect, plugging in the cable/dongle) and re-applies the mapping with `hidutil`
// each time, because macOS drops per-device mappings on reconnect.
//
// The layout is a setting: "mac" (swap) or "windows" (keys as printed, the default).
// It lives in ~/Library/Application Support/aula-remap/layout. AULA Lights changes it
// and posts the distributed notification below so the switch takes effect at once.
//
// Usage:
//   aula-remap                 run forever (what the LaunchAgent does)
//   aula-remap --once          apply the current layout to connected AULA keyboards and exit
//   aula-remap --reset         remove the mapping from AULA keyboards and exit
//   aula-remap --layout mac|windows   save the layout, apply it, and exit
//   aula-remap --knob volume|dial     save the knob mode, apply it, and exit
//
// Knob: "volume" (default) leaves the knob as AULA made it. "dial" stops its turn and
// click reaching macOS so AULA Lights can use them for the dial menu (the app reads the
// knob before this mapping applies). Whenever AULA Lights isn't running, the knob goes
// back to "volume", so it is never left dead.

import AppKit
import Foundation
import IOKit
import IOKit.hid

// The keyboard shows up under different IDs depending on how it's connected.
// ProductID nil = any product from that vendor (0x3554 is AULA's own ID).
let aulaDevices: [(vendor: Int, product: Int?, how: String)] = [
    (0x3554, nil, "Bluetooth / 2.4 GHz"),  // BT 0xFA07, receiver 0xFA09
    (0x258A, 0x010C, "USB cable"),        // generic chip vendor, so match the product too
]

let layoutChanged = Notification.Name("com.aulalights.remap.layoutChanged")

let layoutFile: URL = {
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("aula-remap", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("layout")
}()

let knobFile = layoutFile.deletingLastPathComponent().appendingPathComponent("knob")
let appBundleID = "com.aulalights.app"

func currentKnob() -> String {
    (try? String(contentsOf: knobFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) == "dial" ? "dial" : "volume"
}

// HID consumer page 0x0C: E9 = Volume Up, EA = Volume Down, E2 = Mute (the knob).
// Mapped to consumer usage 0 (nothing) while the dial menu owns the knob.
let knobSilence: [(UInt64, UInt64)] = [
    (0xC_0000_00E9, 0xC_0000_0000),
    (0xC_0000_00EA, 0xC_0000_0000),
    (0xC_0000_00E2, 0xC_0000_0000),
]

func currentLayout() -> String {
    let saved = (try? String(contentsOf: layoutFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    return saved == "mac" ? "mac" : "windows"  // keys as printed until the user picks Mac layout
}

// HID keyboard usage page 0x07: E2 = Left Alt, E3 = Left GUI (Win), E6 = Right Alt, E7 = Right GUI
let swaps: [(UInt64, UInt64)] = [
    (0x7_0000_00E2, 0x7_0000_00E3),  // Left Alt  -> Left Command
    (0x7_0000_00E3, 0x7_0000_00E2),  // Left Win  -> Left Option
    (0x7_0000_00E6, 0x7_0000_00E7),  // Right Alt -> Right Command
    (0x7_0000_00E7, 0x7_0000_00E6),  // Right Win -> Right Option
]

func log(_ msg: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    print("[\(ts)] \(msg)")
    fflush(stdout)
}

func hidutil(_ args: [String]) -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return false }
    p.waitUntilExit()
    return p.terminationStatus == 0
}

func matching(vendor: Int, product: Int?) -> String {
    if let product { return "{\"VendorID\":\(vendor),\"ProductID\":\(product)}" }
    return "{\"VendorID\":\(vendor)}"
}

/// Applies the saved layout (or clears it) on one AULA device ID, or all of them.
func apply(vendor: Int? = nil, product: Int? = nil, reset: Bool = false) {
    let mac = !reset && currentLayout() == "mac"
    let dial = !reset && currentKnob() == "dial"
    let entries = ((mac ? swaps : []) + (dial ? knobSilence : [])).map {
        "{\"HIDKeyboardModifierMappingSrc\":\($0.0),\"HIDKeyboardModifierMappingDst\":\($0.1)}"
    }.joined(separator: ",")
    let targets: [(vendor: Int, product: Int?)] = vendor.map { [($0, product)] } ?? aulaDevices.map { ($0.vendor, $0.product) }
    for target in targets {
        let ok = hidutil(["property", "--matching", matching(vendor: target.vendor, product: target.product),
                          "--set", "{\"UserKeyMapping\":[\(entries)]}"])
        let name = String(format: "0x%04X", target.vendor) + (target.product.map { String(format: ":0x%04X", $0) } ?? "")
        log("\(mac ? "Mac layout (Alt=Cmd, Win=Opt)" : "Windows layout (no swap)"), knob: \(dial ? "dial" : "volume") on \(name): \(ok ? "ok" : "FAILED")")
    }
}

func intProperty(_ service: io_service_t, _ key: String) -> Int? {
    IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
        .takeRetainedValue() as? Int
}

// --- one-shot modes -------------------------------------------------------

let args = Array(CommandLine.arguments.dropFirst())
if args.contains("--reset") { apply(reset: true); exit(0) }
if args.contains("--once") { apply(); exit(0) }
if let i = args.firstIndex(of: "--layout"), i + 1 < args.count, ["mac", "windows"].contains(args[i + 1]) {
    try? args[i + 1].write(to: layoutFile, atomically: true, encoding: .utf8)
    apply()
    DistributedNotificationCenter.default().postNotificationName(layoutChanged, object: nil, userInfo: nil, deliverImmediately: true)
    exit(0)
}
if let i = args.firstIndex(of: "--knob"), i + 1 < args.count, ["volume", "dial"].contains(args[i + 1]) {
    try? args[i + 1].write(to: knobFile, atomically: true, encoding: .utf8)
    apply()
    DistributedNotificationCenter.default().postNotificationName(layoutChanged, object: nil, userInfo: nil, deliverImmediately: true)
    exit(0)
}

// --- watch mode -----------------------------------------------------------

let port = IONotificationPortCreate(kIOMainPortDefault)!
IONotificationPortSetDispatchQueue(port, DispatchQueue.main)

let onMatch: IOServiceMatchingCallback = { _, iterator in
    var service = IOIteratorNext(iterator)
    var found = Set<[Int]>()
    while service != 0 {
        if let vid = intProperty(service, kIOHIDVendorIDKey), let pid = intProperty(service, kIOHIDProductIDKey) {
            found.insert([vid, pid])
        }
        IOObjectRelease(service)
        service = IOIteratorNext(iterator)
    }
    // The keyboard's event service shows up a moment after the device itself,
    // so apply a few times over the first couple of seconds.
    for ids in found {
        log(String(format: "AULA keyboard connected (0x%04X:0x%04X)", ids[0], ids[1]))
        for delay in [0.5, 1.5, 4.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { apply(vendor: ids[0], product: ids[1]) }
        }
    }
}

var iterators: [io_iterator_t] = []
for device in aulaDevices {
    let match = IOServiceMatching(kIOHIDDeviceKey) as NSMutableDictionary
    match[kIOHIDVendorIDKey] = device.vendor
    if let product = device.product { match[kIOHIDProductIDKey] = product }
    match[kIOHIDPrimaryUsagePageKey] = kHIDPage_GenericDesktop
    match[kIOHIDPrimaryUsageKey] = kHIDUsage_GD_Keyboard
    var iterator: io_iterator_t = 0
    let kr = IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, match, onMatch, nil, &iterator)
    guard kr == KERN_SUCCESS else { log("Could not watch for \(device.how) (error \(kr))"); exit(1) }
    onMatch(nil, iterator)  // handle keyboards already connected and arm the notification
    iterators.append(iterator)
}

// AULA Lights flips the layout switch -> apply straight away.
DistributedNotificationCenter.default().addObserver(forName: layoutChanged, object: nil, queue: .main) { _ in
    log("Layout switched to \(currentLayout())")
    apply()
}

// The knob must never stay silenced without the app: hand it back to volume when
// AULA Lights quits (or crashes), and at start-up if it isn't running.
func releaseKnob(_ why: String) {
    guard currentKnob() == "dial" else { return }
    try? "volume".write(to: knobFile, atomically: true, encoding: .utf8)
    log("Knob back to volume (\(why))")
    apply()
}
let appRunning = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == appBundleID }
if !appRunning { releaseKnob("AULA Lights isn't running") }
NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { note in
    let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
    guard app?.bundleIdentifier == appBundleID else { return }
    // Command-line use starts a short-lived second copy of the app; only release the
    // knob once no copy is left running.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        let stillRunning = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == appBundleID && !$0.isTerminated }
        if !stillRunning { releaseKnob("AULA Lights quit") }
    }
}

log("Watching for AULA keyboards (layout: \(currentLayout()), knob: \(currentKnob()))")
RunLoop.main.run()  // a run loop (not dispatchMain) so distributed notifications arrive
