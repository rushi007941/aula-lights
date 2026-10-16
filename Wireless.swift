// The 2.4 GHz receiver's protocol (3554:FA09): 20-byte output reports with ID 0x13,
// answered by 20-byte input reports. Byte 19 is a checksum (sum of bytes 0-18).
// Documented by keylux-linux and aula-macos-software from captures of the vendor driver.

import Foundation
import IOKit.hid

final class WirelessLink {
    static let vendorID = 0x3554
    static let receiverProductID = 0xFA09
    static let bluetoothProductID = 0xFA07
    static let reportID: UInt8 = 0x13

    let device: IOHIDDevice
    let productID: Int
    private let input: ReplyMonitor

    private init(_ device: IOHIDDevice, productID: Int) {
        self.device = device
        self.productID = productID
        self.input = ReplyMonitor(device: device)
    }

    deinit {
        input.stop()
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    /// Opens the vendor channel (usage page 0xFF02) of the receiver or the Bluetooth keyboard.
    static func open(productIDs: [Int] = [receiverProductID, bluetoothProductID]) throws -> WirelessLink {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: vendorID] as CFDictionary)
        let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
        let int = { (d: IOHIDDevice, k: String) in (IOHIDDeviceGetProperty(d, k as CFString) as? Int) ?? 0 }
        let hasVendorChannel = { (d: IOHIDDevice) -> Bool in
            let pairs = (IOHIDDeviceGetProperty(d, kIOHIDDeviceUsagePairsKey as CFString) as? [[String: Int]]) ?? []
            return pairs.contains { $0[kIOHIDDeviceUsagePageKey] == 0xFF02 } && int(d, kIOHIDMaxOutputReportSizeKey) >= 19
        }
        for pid in productIDs {
            guard let d = devices.first(where: { int($0, kIOHIDProductIDKey) == pid && hasVendorChannel($0) }) else { continue }
            let r = IOHIDDeviceOpen(d, IOOptionBits(kIOHIDOptionsTypeNone))
            if r != kIOReturnSuccess {
                if !F75.accessGranted { throw AulaError.needsPermission("not allowed") }
                throw AulaError.openFailed(r)
            }
            return WirelessLink(d, productID: pid)
        }
        throw AulaError.notFound
    }

    static func isReceiverPresent() -> Bool {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: vendorID, kIOHIDProductIDKey: receiverProductID] as CFDictionary)
        return !((IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []).isEmpty
    }

    static func frame(command: UInt8, subcommand: UInt8, sequence: UInt8, payload: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 20)
        out[0] = reportID
        out[1] = command
        out[2] = subcommand
        out[3] = sequence
        out.replaceSubrange(4..<(4 + min(payload.count, 15)), with: payload.prefix(15))
        out[19] = out.prefix(19).reduce(0, &+)
        return out
    }

    func send(_ frame: [UInt8]) throws {
        let r = frame.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(WirelessLink.reportID), $0.baseAddress!, $0.count)
        }
        guard r == kIOReturnSuccess else { throw AulaError.io("Sending over wireless", r) }
    }

    static func valid(_ r: [UInt8]) -> Bool { r.count == 20 && r[0] == reportID && r[19] == r.prefix(19).reduce(0, &+) }

    /// Reads the 10-fragment settings block. Throws unless all 10 arrive intact and the
    /// block ends with the 5A A5 signature, so a partial read can never be written back.
    func readConfig() throws -> [[UInt8]] {
        input.clear()
        try send(WirelessLink.frame(command: 0x44, subcommand: 0x01, sequence: 0, payload: []))
        let deadline = Date().addingTimeInterval(1.5)
        var config: [Int: [UInt8]] = [:]
        while Date() < deadline, config.count < 10 {
            Thread.sleep(forTimeInterval: 0.005)
            for r in input.reports() where WirelessLink.valid(r) && r[1] == 0x44 && r[2] == 0x0A && r[3] < 10 {
                config[Int(r[3])] = r
            }
        }
        guard config.count == 10, config[9]![5] == 0x5A, config[9]![6] == 0xA5 else {
            throw AulaError.badReply("the wireless settings read (\(config.count) of 10 parts)")
        }
        return (0..<10).map { config[$0]! }
    }

    /// Sends one command and waits for the keyboard to acknowledge it.
    func exchange(_ frame: [UInt8]) throws {
        input.clear()
        try send(frame)
        let deadline = Date().addingTimeInterval(0.8)
        while Date() < deadline {
            if input.reports().contains(where: { WirelessLink.valid($0) && $0[1...3] == frame[1...3] }) { return }
            Thread.sleep(forTimeInterval: 0.002)
        }
        throw AulaError.badReply(String(format: "wireless command 0x%02X part %d (no acknowledgement)", frame[1], frame[3]))
    }

    /// Read-only diagnostics: every reply to one settings read.
    func readConfigProbe(wait seconds: Double = 1.5) throws -> [[UInt8]] {
        input.clear()
        try send(WirelessLink.frame(command: 0x44, subcommand: 0x01, sequence: 0, payload: []))
        Thread.sleep(forTimeInterval: seconds)
        return input.reports()
    }
}

/// Collects the keyboard's 0x13 replies on its own thread, so none are missed while the
/// caller waits. Ordinary keystroke reports are never kept.
final class ReplyMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var received: [[UInt8]] = []
    private let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    private let device: IOHIDDevice
    private let finished = DispatchSemaphore(value: 0)
    private var runLoop: CFRunLoop?
    private var stopped = false

    init(device: IOHIDDevice) {
        self.device = device
        let started = DispatchSemaphore(value: 0)
        Thread { [self] in
            let loop = CFRunLoopGetCurrent()!
            lock.run { runLoop = loop }
            IOHIDDeviceRegisterInputReportCallback(device, buffer, 64, { context, result, _, _, reportID, report, length in
                guard result == kIOReturnSuccess, reportID == 0x13, length == 19 || length == 20, let context else { return }
                var bytes = Array(UnsafeBufferPointer(start: report, count: length))
                if length == 19 { bytes.insert(0x13, at: 0) }
                Unmanaged<ReplyMonitor>.fromOpaque(context).takeUnretainedValue().append(bytes)
            }, Unmanaged.passUnretained(self).toOpaque())
            IOHIDDeviceScheduleWithRunLoop(device, loop, CFRunLoopMode.defaultMode.rawValue)
            started.signal()
            CFRunLoopRun()
            IOHIDDeviceRegisterInputReportCallback(device, buffer, 64, nil, Unmanaged.passUnretained(self).toOpaque())
            IOHIDDeviceUnscheduleFromRunLoop(device, loop, CFRunLoopMode.defaultMode.rawValue)
            finished.signal()
        }.start()
        started.wait()
    }

    deinit { buffer.deallocate() }

    func stop() {
        guard let loop = lock.run({ () -> CFRunLoop? in
            guard !stopped else { return nil }
            stopped = true
            return runLoop
        }) else { return }
        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) { CFRunLoopStop(loop) }
        CFRunLoopWakeUp(loop)
        finished.wait()
    }

    func clear() { lock.run { received.removeAll(keepingCapacity: true) } }
    func reports() -> [[UInt8]] { lock.run { received } }

    private func append(_ bytes: [UInt8]) {
        lock.run {
            if received.count == 256 { received.removeFirst() }
            received.append(bytes)
        }
    }
}

// MARK: - Lighting over the receiver

extension WirelessLink: LightingDevice {
    var connectionName: String { productID == WirelessLink.receiverProductID ? "2.4 GHz receiver" : "Bluetooth" }

    /// Where an effect's brightness and speed live: (fragment, payload offset).
    private static func parameterLocation(_ effect: Int) -> (fragment: Int, offset: Int) {
        effect <= 6 ? (4, 3 + (effect - 1) * 2) : (5 + (effect - 7) / 7, 1 + ((effect - 7) % 7) * 2)
    }

    private static let paletteTemplate: [[UInt8]] = {
        let a: [UInt8] = [0x0E, 0, 0xFF, 0xFF, 0xFF, 0, 0xFF, 0, 0xFF, 0, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
        let b: [UInt8] = [0x0E, 0xFF, 0, 0, 0, 0xFF, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0, 0xFF, 0]
        let c: [UInt8] = [0x0E, 0xFF, 0, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0, 0, 0, 0xFF, 0, 0]
        var result = [[UInt8](repeating: 0, count: 15), [0x0E, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0, 0, 0, 0xFF, 0, 0]]
        while result.count < 21 { result.append([a, b, c][(result.count - 2) % 3]) }
        return result
    }()

    func state() throws -> LightState {
        guard productID == WirelessLink.receiverProductID else { throw AulaError.bluetoothLimited }
        let cfg = try readConfig()
        let effect = Effect(rawValue: Int(cfg[0][15])) ?? .off
        let shown = (effect == .off || effect == .perKey) ? Effect.fixedOn : effect
        let loc = WirelessLink.parameterLocation(shown.rawValue)
        let brightness = cfg[loc.fragment][4 + loc.offset]
        let flags = cfg[loc.fragment][4 + loc.offset + 1]
        // The receiver can't report the colour back, so the app keeps the last one it set.
        return LightState(effect: effect, brightness: min(Int(brightness), 9), speed: min(Int(flags >> 4), 4),
                          rainbow: flags & 0x0F == 7, color: Controller.lastColor)
    }

    func apply(_ target: LightState) throws {
        guard productID == WirelessLink.receiverProductID else { throw AulaError.bluetoothLimited }
        let original = try readConfig()
        let e = target.effect
        let rainbow = target.rainbow || !e.supportsColor

        // Settings: the read block with only the effect, brightness and speed changed.
        var frames = original.enumerated().map { seq, report -> [UInt8] in
            var payload = Array(report[4..<19])
            if seq == 0 { payload[10] = 0; payload[11] = UInt8(e.rawValue); payload[13] = 1 }
            if e != .off {
                let loc = WirelessLink.parameterLocation(e.rawValue)
                if seq == loc.fragment {
                    payload[loc.offset] = UInt8(min(max(target.brightness, 0), 9))
                    payload[loc.offset + 1] = UInt8(min(max(target.speed, 0), 4)) << 4 | (rainbow ? 7 : 0)
                }
            }
            return WirelessLink.frame(command: 0x04, subcommand: 0x0A, sequence: UInt8(seq), payload: payload)
        }
        let settingsFrames = frames

        // Colour table: 37 parts; the chosen colour goes into this effect's slot.
        for seq in 0..<37 {
            var payload = seq < WirelessLink.paletteTemplate.count ? WirelessLink.paletteTemplate[seq] : [UInt8](repeating: 0, count: 15)
            payload[0] = seq == 36 ? 0x08 : 0x0E
            if e.supportsColor {
                for (channel, value) in [target.color.r, target.color.g, target.color.b].enumerated() {
                    let offset = e.rawValue * 21 + channel
                    if offset / 14 == seq { payload[1 + offset % 14] = value }
                }
            }
            if seq == 36 { payload[3] = 0x5A; payload[4] = 0xA5 }
            frames.append(WirelessLink.frame(command: 0x09, subcommand: 0x25, sequence: UInt8(seq), payload: payload))
        }
        frames.append(WirelessLink.frame(command: 0x0A, subcommand: 0x01, sequence: 0, payload: [0x04, 0x07]))  // save

        do {
            for f in frames { try exchange(f) }
            // Read back and compare the parts we changed.
            let after = try readConfig()
            guard after[0][15] == UInt8(e.rawValue),
                  (4...8).allSatisfy({ after[$0][5..<19] == settingsFrames[$0][5..<19] }) else {
                throw AulaError.verifyFailed("The lighting change")
            }
        } catch {
            for report in original {  // put the original settings back
                var f = report
                f[1] = 0x04
                f[19] = f.prefix(19).reduce(0, &+)
                try? exchange(f)
            }
            try? exchange(WirelessLink.frame(command: 0x0A, subcommand: 0x01, sequence: 0, payload: [0x04, 0x07]))
            throw error
        }
    }
}

/// Whatever the keyboard is connected through: the cable (preferred) or the receiver.
protocol LightingDevice: AnyObject {
    var connectionName: String { get }
    func state() throws -> LightState
    func apply(_ target: LightState) throws
}

extension F75: LightingDevice {
    var connectionName: String { "USB-C" }
}

enum Keyboard {
    static func open() throws -> LightingDevice {
        if F75.isPresent() { return try F75.open() }
        if WirelessLink.isReceiverPresent() { return try WirelessLink.open(productIDs: [WirelessLink.receiverProductID]) }
        throw AulaError.notFound
    }

    /// Cable or receiver plugged in (Bluetooth doesn't count: it can't change the lighting).
    static func isPresent() -> Bool { F75.isPresent() || WirelessLink.isReceiverPresent() }
}

// MARK: - Live streaming over the receiver

extension WirelessLink {
    static let saveFrame = frame(command: 0x0A, subcommand: 0x01, sequence: 0, payload: [0x04, 0x07])

    /// Writes a 10-part settings block (as read, with edits), each part acknowledged, then saves.
    func writeConfig(_ cfg: [[UInt8]]) throws {
        for report in cfg {
            var f = report
            f[1] = 0x04
            f[19] = f.prefix(19).reduce(0, &+)
            try exchange(f)
        }
        try exchange(WirelessLink.saveFrame)
    }

    /// Settings block byte i lives in part i / 14, at report index 5 + i % 14.
    private static func at(_ i: Int) -> (part: Int, index: Int) { (i / 14, 5 + i % 14) }

    /// Switches to per-key mode (block bytes 9, 10, 59 = 01, 15, 47, as captured from the
    /// vendor driver on both links) by editing only those bytes of a fully read block.
    /// Returns the original block so it can be put back.
    func enterPerKeyMode() throws -> [[UInt8]] {
        let original = try readConfig()
        var cfg = original
        for (byte, value) in [(9, UInt8(0x01)), (10, UInt8(0x15)), (59, UInt8(0x47))] {
            let p = WirelessLink.at(byte)
            cfg[p.part][p.index] = value
        }
        do {
            try writeConfig(cfg)
            guard try readConfig()[0][15] == 0x15 else { throw AulaError.verifyFailed("Switching to live mode") }
        } catch {
            try? writeConfig(original)
            throw error
        }
        Thread.sleep(forTimeInterval: 0.4)  // the firmware repaints once after a settings change
        return original
    }

    func restoreConfig(_ original: [[UInt8]]) throws {
        try writeConfig(original)
        guard try readConfig()[0][15] == original[0][15] else { throw AulaError.verifyFailed("Restoring the lighting") }
    }

    /// One "paint these keys this colour" message: groups of [R, G, B, count, LEDs…], at most
    /// 84 bytes (6 parts of 14). Returns the 20-byte reports to send, in order.
    static func liveMessage(_ groups: [(RGB, [Int])]) -> [[UInt8]] {
        var data: [UInt8] = []
        for (c, leds) in groups { data += [c.r, c.g, c.b, UInt8(leds.count)] + leds.map { UInt8($0) } }
        let chunks = stride(from: 0, to: data.count, by: 14).map { Array(data[$0..<min($0 + 14, data.count)]) }
        return chunks.enumerated().map { i, chunk in
            var f = [UInt8](repeating: 0, count: 20)
            f[0] = reportID; f[1] = 0x88; f[2] = UInt8(chunks.count); f[3] = UInt8(i); f[4] = 0x10 + UInt8(chunk.count)
            f.replaceSubrange(5..<(5 + chunk.count), with: chunk)
            f[19] = f.prefix(19).reduce(0, &+)
            return f
        }
    }

    /// Sends reports without waiting for each to finish (Bluetooth writes are slow when awaited).
    /// Returns once all have completed, or after `timeout`.
    func sendPipelined(_ reports: [[UInt8]], gap: Double, timeout: Double = 10) -> (done: Int, failed: Int) {
        final class Tally { var done = 0; var failed = 0 }
        let tally = Tally()
        let context = Unmanaged.passRetained(tally).toOpaque()
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        var buffers: [UnsafeMutablePointer<UInt8>] = []
        for r in reports {
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: r.count)
            p.initialize(from: r, count: r.count)
            buffers.append(p)
            IOHIDDeviceSetReportWithCallback(device, kIOHIDReportTypeOutput, CFIndex(WirelessLink.reportID), p, r.count, 2.0, { context, result, _, _, _, _, _ in
                guard let context else { return }
                let t = Unmanaged<Tally>.fromOpaque(context).takeUnretainedValue()
                if result == kIOReturnSuccess { t.done += 1 } else { t.failed += 1 }
            }, context)
            RunLoop.current.run(until: Date().addingTimeInterval(gap))
        }
        let deadline = Date().addingTimeInterval(timeout)
        while tally.done + tally.failed < reports.count && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        buffers.forEach { $0.deallocate() }
        Unmanaged<Tally>.fromOpaque(context).release()
        return (tally.done, tally.failed)
    }

    /// Sends a live message. These have no acknowledgement; parts are spaced like the vendor driver's.
    func sendLive(_ reports: [[UInt8]]) throws {
        for r in reports {
            try send(r)
            Thread.sleep(forTimeInterval: 0.012)
        }
    }
}
