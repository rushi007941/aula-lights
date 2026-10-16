// Live scenes (ripple, heatmap, Whack-a-key) and the engine that streams whichever one
// is active to the keyboard. A scene is used either by the engine (on its queue) or by
// the on-screen preview (on the main thread), so each one guards its state with a lock.

import Foundation

extension NSLock {
    func run<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

protocol LiveScene: AnyObject {
    func press(_ key: KeyPos, at t: Double)
    func colors(at t: Double) -> [RGBf]  // linear 0-1, one per LED slot (126)
}

/// Ring of light from a point; used by the game's bursts.
private func ring(distance d: Double, radius: Double, width: Double) -> Double {
    exp(-pow(d - radius, 2) / (2 * width * width))
}

// MARK: - Ripple

final class RippleScene: LiveScene {
    private let lock = NSLock()
    private var renderer = RippleRenderer()

    var settings: RippleSettings {
        get { lock.run { renderer.settings } }
        set { lock.run { renderer.settings = newValue } }
    }

    func press(_ key: KeyPos, at t: Double) { lock.run { renderer.press(key, at: t) } }
    func colors(at t: Double) -> [RGBf] { lock.run { renderer.colors(at: t) } }
}

// MARK: - Heatmap

/// Keys warm up as you use them and cool down over time.
final class HeatmapScene: LiveScene {
    private let lock = NSLock()
    private var heat = [Double](repeating: 0, count: 126)
    private var flash = [Double](repeating: -10, count: 126)
    private var last: Double?
    private var memory = 40.0  // half-life, seconds

    var halfLife: Double {
        get { lock.run { memory } }
        set { lock.run { memory = newValue } }
    }

    func reset() { lock.run { heat = .init(repeating: 0, count: 126) } }

    /// The key you've used most lately, once there's enough typing to say.
    func hottest() -> KeyPos? {
        lock.run {
            guard let best = Layout.keys.max(by: { heat[$0.led] < heat[$1.led] }), heat[best.led] >= 3 else { return nil }
            return best
        }
    }

    func press(_ key: KeyPos, at t: Double) {
        lock.run { heat[key.led] += 1; flash[key.led] = t }
    }

    /// Cold navy, through cyan and green, to amber and red.
    static func ramp(_ v: Double) -> RGBf {
        let stops: [(Double, RGBf)] = [(0, (0.03, 0.05, 0.28)), (0.25, (0.0, 0.45, 1.0)), (0.5, (0.0, 0.95, 0.65)),
                                       (0.75, (1.0, 0.78, 0.0)), (1, (1.0, 0.12, 0.04))]
        let v = min(max(v, 0), 1)
        for i in 1..<stops.count where v <= stops[i].0 {
            let (a, ca) = stops[i - 1], (b, cb) = stops[i]
            let f = (v - a) / (b - a)
            return (ca.0 + (cb.0 - ca.0) * f, ca.1 + (cb.1 - ca.1) * f, ca.2 + (cb.2 - ca.2) * f)
        }
        return stops.last!.1
    }

    func colors(at t: Double) -> [RGBf] {
        lock.run {
            if let last { let k = pow(0.5, (t - last) / memory); for i in heat.indices { heat[i] *= k } }
            last = t
            let top = max(heat.max() ?? 0, 4)
            var out = [RGBf](repeating: (0, 0, 0), count: 126)
            for key in Layout.keys {
                let v = heat[key.led] / top
                var c = HeatmapScene.ramp(v)
                let level = 0.25 + 0.75 * min(1, v * 2.5)
                c = (c.0 * level, c.1 * level, c.2 * level)
                let f = 0.6 * exp(-(t - flash[key.led]) / 0.12)  // a white tap where you press
                out[key.led] = (min(1, c.0 + f), min(1, c.1 + f), min(1, c.2 + f))
            }
            return out
        }
    }
}

// MARK: - Whack-a-key

enum GamePhase: Equatable { case idle, countdown(Int), playing, over }

struct GameState: Equatable {
    var phase = GamePhase.idle
    var score = 0
    var combo = 0
    var hits = 0
    var misses = 0
    var timeLeft = Int(WhackScene.duration)
    var best = UserDefaults.standard.integer(forKey: "whack.best")
    var newBest = false
}

/// A key lights up; hit it before it moves on. 30 seconds, combos for speed.
final class WhackScene: LiveScene {
    static let duration = 30.0
    static let pool = Layout.keys.filter { $0.name.count == 1 && ($0.name.first!.isLetter || $0.name.first!.isNumber) }

    private let lock = NSLock()
    private var state = GameState()
    private var reported = GameState()
    private var startAt = 0.0
    private var endAt = 0.0
    private var target: KeyPos?
    private var targetAt = 0.0
    private var bursts: [(x: Double, y: Double, t: Double, c: RGBf)] = []
    private var missed: [Int: Double] = [:]

    /// Called on the main thread when the score, timer or phase changes.
    var onChange: ((GameState) -> Void)?

    func start(at t: Double) {
        lock.run {
            state = GameState()
            state.phase = .countdown(3)
            startAt = t + 3
            bursts = []; missed = [:]; target = nil
        }
    }

    func cancel() { lock.run { state.phase = .idle; target = nil } }

    var isActive: Bool {
        lock.run { if case .countdown = state.phase { return true }; return state.phase == .playing }
    }

    func press(_ key: KeyPos, at t: Double) {
        lock.run {
            guard state.phase == .playing, let target else { return }
            if key.led == target.led {
                state.hits += 1
                state.combo += 1
                state.score += (t - targetAt < 0.7 ? 2 : 1) + (state.combo % 5 == 0 ? 3 : 0)
                bursts.append((key.x, key.y, t, (0.25, 1.0, 0.45)))
                pickTarget(at: t)
            } else {
                state.misses += 1
                state.combo = 0
                missed[key.led] = t
            }
        }
    }

    private func pickTarget(at t: Double) {
        var next = WhackScene.pool.randomElement()!
        while next.led == target?.led { next = WhackScene.pool.randomElement()! }
        target = next
        targetAt = t
    }

    private func advance(_ t: Double) {
        switch state.phase {
        case .countdown:
            let remain = startAt - t
            if remain <= 0 { state.phase = .playing; pickTarget(at: t) } else { state.phase = .countdown(Int(ceil(remain))) }
        case .playing:
            let left = WhackScene.duration - (t - startAt)
            state.timeLeft = max(0, Int(ceil(left)))
            if left <= 0 {
                state.phase = .over
                endAt = t
                target = nil
                if state.score > state.best {
                    state.best = state.score
                    state.newBest = true
                    UserDefaults.standard.set(state.score, forKey: "whack.best")
                }
                bursts.append((Layout.width / 2, Layout.height / 2, t, (-1, 0, 0)))  // rainbow finale
            }
        default: break
        }
    }

    func colors(at t: Double) -> [RGBf] {
        let (out, changed) = lock.run { () -> ([RGBf], GameState?) in
            advance(t)
            bursts.removeAll { t - $0.t > 1.6 }
            missed = missed.filter { t - $0.value < 0.4 }
            let left = WhackScene.duration - (t - startAt)
            var out = [RGBf](repeating: (0, 0, 0), count: 126)
            for key in Layout.keys {
                var c: RGBf = (0.012, 0.016, 0.04)
                switch state.phase {
                case .countdown:
                    let beat = startAt - t
                    let v = pow(beat - floor(beat), 3) * 0.55  // the board thumps once a second
                    c = (0.9 * v, 0.62 * v, 0.18 * v)
                case .playing:
                    if let target {
                        let d = hypot(key.x - target.x, key.y - target.y)
                        let pulse = 0.78 + 0.22 * sin(t * 11)
                        let v = key.led == target.led ? pulse : 0.22 * exp(-d * d / 0.9)
                        c.0 += 0.95 * v; c.1 += 0.68 * v; c.2 += 0.2 * v
                    }
                    let edge = key.y < 0.5 || key.y > 5 || key.x < 1.2 || key.x > 14.8
                    if left < 5 && edge {
                        let v = 0.45 * (0.5 + 0.5 * sin(t * 12))
                        c.0 += v; c.1 += v * 0.05
                    }
                case .over:
                    let v = 0.06 + 0.05 * sin((t - endAt) * 2)
                    c = (0.9 * v, 0.62 * v, 0.18 * v)
                case .idle:
                    break
                }
                for b in bursts {
                    let age = t - b.t
                    let d = hypot(key.x - b.x, key.y - b.y)
                    let v = ring(distance: d, radius: age * (b.c.0 < 0 ? 9 : 12), width: 0.6) * max(0, 1 - age / (b.c.0 < 0 ? 1.6 : 0.7))
                    let bc = b.c.0 < 0 ? hue(d * 0.07 - age * 0.5) : b.c
                    c.0 += bc.0 * v; c.1 += bc.1 * v; c.2 += bc.2 * v
                }
                if let m = missed[key.led] {
                    let v = exp(-(t - m) / 0.15)
                    c.0 += v; c.1 += 0.08 * v; c.2 += 0.05 * v
                }
                out[key.led] = (min(1, c.0), min(1, c.1), min(1, c.2))
            }
            guard state != reported else { return (out, nil) }
            reported = state
            return (out, state)
        }
        if let changed {
            let callback = onChange
            DispatchQueue.main.async { callback?(changed) }
        }
        return out
    }
}

// MARK: - Engine

/// Streams the active scene to the keyboard while it's in per-key mode.
final class LiveEngine {
    static let backupURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AulaLights", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("before-ripple.bin")
    }()

    static let frameInterval = 0.05  // 20 FPS; the keyboard needs >= 46 ms between frames
    /// The receiver: 20 small updates a second, like the vendor driver's ~46 ms rhythm, with a
    /// budget of 60 parts a second (under the 64 keylux measured before the board flickers)
    /// and never more than 4 parts in one update.
    static let radioInterval = 0.05
    static let radioPartsPerSecond = 60.0
    static let radioMaxPartsPerTick = 4
    /// Colour levels the vendor driver itself streams over the radio.
    static let radioLevels: [UInt8] = [0x00, 0x33, 0x66, 0xB2, 0xFF]

    static let radioBackupURL: URL = backupURL.deletingLastPathComponent().appendingPathComponent("before-live-receiver.bin")
    static var now: Double { ProcessInfo.processInfo.systemUptime }

    private let queue = DispatchQueue(label: "aula-lights.live")
    private var kb: F75?
    private var original: [UInt8]?
    private var radio: WirelessLink?
    private var radioOriginal: [[UInt8]]?
    private var radioSent = [RGB?](repeating: nil, count: 126)  // what each key shows now
    private var radioTokens = 0.0      // parts we may send right now
    private var radioLastTick = 0.0
    private var timer: DispatchSourceTimer?
    private var scene: LiveScene?
    private var lastFrame: [UInt8] = []
    private var lastSend = 0.0

    // The latest colours, for the on-screen keyboard (read from the main thread).
    private let lock = NSLock()
    private var shown: [RGBf] = []
    var latestColors: [RGBf] { lock.run { shown } }

    /// Called on the main thread if streaming stops by itself (e.g. cable unplugged).
    var onFailure: ((String) -> Void)?

    func start(_ scene: LiveScene) throws {
        try queue.sync {
            self.scene = scene
            guard kb == nil, radio == nil else { return }
            if !F75.isPresent() && WirelessLink.isReceiverPresent() {
                // Over the 2.4 GHz receiver: same safety (back up, then switch), different streaming.
                let link = try WirelessLink.open(productIDs: [WirelessLink.receiverProductID])
                let saved = try link.readConfig()
                if saved[0][15] != 0x15 { try Data(saved.flatMap { $0 }).write(to: LiveEngine.radioBackupURL) }
                var before = try link.enterPerKeyMode()
                if before[0][15] == 0x15, let disk = try? Data(contentsOf: LiveEngine.radioBackupURL), disk.count == 200 {
                    before = stride(from: 0, to: 200, by: 20).map { Array(disk[$0..<$0 + 20]) }
                }
                radio = link
                radioOriginal = before
                radioSent = .init(repeating: nil, count: 126)
                radioTokens = Double(LiveEngine.radioMaxPartsPerTick)
                radioLastTick = LiveEngine.now
                startTimer(interval: LiveEngine.radioInterval)
                return
            }
            let device = try F75.open()
            let saved = try device.readSettings()
            // Keep a copy on disk first, so a crash can't strand the keyboard in per-key mode.
            if saved[10] != 0x15 { try Data(saved).write(to: LiveEngine.backupURL) }
            original = try device.enterPerKeyMode()
            if original?[10] == 0x15, let disk = try? Data(contentsOf: LiveEngine.backupURL) { original = [UInt8](disk) }
            kb = device
            lastFrame = []
            startTimer(interval: LiveEngine.frameInterval)
        }
    }

    func setScene(_ scene: LiveScene) { queue.async { self.scene = scene } }

    func stop() throws {
        try queue.sync {
            timer?.cancel(); timer = nil
            scene = nil
            lock.run { shown = [] }
            defer { kb = nil; original = nil; radio = nil; radioOriginal = nil }
            if let kb, let original {
                try kb.restoreSettings(original)
                try? FileManager.default.removeItem(at: LiveEngine.backupURL)
            }
            if let radio, let radioOriginal {
                try radio.restoreConfig(radioOriginal)
                try? FileManager.default.removeItem(at: LiveEngine.radioBackupURL)
            }
        }
    }

    func press(_ key: KeyPos) {
        queue.async { self.scene?.press(key, at: LiveEngine.now) }
    }

    static func frame(from colors: [RGBf]) -> [UInt8] {
        let out = { (x: Double) in UInt8(pow(min(max(x, 0), 1), 1.8) * 255) }  // gamma for the LEDs
        var frame = [UInt8](repeating: 0, count: 378)
        for (i, c) in colors.prefix(126).enumerated() {
            frame[i * 3] = out(c.0); frame[i * 3 + 1] = out(c.1); frame[i * 3 + 2] = out(c.2)
        }
        return frame
    }

    private func startTimer(interval: Double) {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func tick() {
        if radio != nil { radioTick(); return }
        guard let kb, let scene else { return }
        let t = LiveEngine.now
        let colors = scene.colors(at: t)
        lock.run { shown = colors }
        let frame = LiveEngine.frame(from: colors)
        // Unchanged frames cost the keyboard nothing; still resend now and then in case it repainted.
        guard frame != lastFrame || t - lastSend > 2 else { return }
        do {
            try kb.streamFrame(frame)
            lastFrame = frame
            lastSend = t
        } catch {
            timer?.cancel(); timer = nil
            self.kb = nil
            let message = error.localizedDescription
            DispatchQueue.main.async { self.onFailure?(message) }
        }
    }

    /// Receiver tick: send only keys whose (rounded) colour changed, grouped by colour,
    /// biggest change first, within the parts budget. Whatever
    /// doesn't fit goes out on the next tick, 50 ms later.
    private func radioTick() {
        guard let radio, let scene else { return }
        let now = LiveEngine.now
        radioTokens = min(Double(LiveEngine.radioMaxPartsPerTick), radioTokens + (now - radioLastTick) * LiveEngine.radioPartsPerSecond)
        radioLastTick = now
        let colors = scene.colors(at: now)
        lock.run { shown = colors }
        let parts = Int(radioTokens)
        guard parts >= 1 else { return }

        let level = { (x: Double) -> UInt8 in
            let v = pow(min(max(x, 0), 1), 1.8) * 255
            return LiveEngine.radioLevels.min(by: { abs(Double($0) - v) < abs(Double($1) - v) })!
        }
        var changed: [RGB: [Int]] = [:]
        for key in Layout.keys {
            let c = colors[key.led]
            let q = RGB(r: level(c.0), g: level(c.1), b: level(c.2))
            if radioSent[key.led] != q { changed[q, default: []].append(key.led) }
        }
        guard !changed.isEmpty else { return }  // nothing new: stay silent

        // Biggest visible change first, lighting up or going dark alike: keys the ring has
        // passed must switch off on time, or the ripple looks like it travels too far.
        let delta = { (a: RGB, b: RGB?) -> Int in
            let b = b ?? RGB(r: 128, g: 128, b: 128)
            return abs(Int(a.r) - Int(b.r)) + abs(Int(a.g) - Int(b.g)) + abs(Int(a.b) - Int(b.b))
        }
        var priority: [RGB: Int] = [:]
        for (color, leds) in changed { priority[color] = leds.map { delta(color, radioSent[$0]) }.max() ?? 0 }
        var groups: [(RGB, [Int])] = []
        var bytes = 0
        for (color, leds) in changed.sorted(by: { (priority[$0.key]!, $0.value.count) > (priority[$1.key]!, $1.value.count) }) {
            let room = parts * 14 - bytes - 4
            guard room > 0 else { break }
            let take = Array(leds.prefix(min(room, 80)))
            groups.append((color, take))
            bytes += 4 + take.count
        }
        radioTokens -= Double((bytes + 13) / 14)
        do {
            try radio.sendLive(WirelessLink.liveMessage(groups))
            for (color, leds) in groups { for led in leds { radioSent[led] = color } }
        } catch {
            timer?.cancel(); timer = nil
            self.radio = nil
            let message = error.localizedDescription
            DispatchQueue.main.async { self.onFailure?(message) }
        }
    }
}
