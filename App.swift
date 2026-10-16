// The app: the stage with the live keyboard, the floating control deck, and a menu bar extra.

import AppKit
import AudioToolbox
import CoreAudio
import SwiftUI

// MARK: - Small helpers

extension Effect {
    var symbol: String {
        switch self {
        case .off: "power"
        case .fixedOn: "lightbulb.fill"
        case .respire: "wind"
        case .rainbow: "rainbow"
        case .flashAway: "bolt.fill"
        case .raindrops: "drop.fill"
        case .rainbowWheel: "circle.dashed"
        case .ripplesShining: "dot.radiowaves.left.and.right"
        case .starsTwinkle: "sparkles"
        case .shadowDisappear: "moon.fill"
        case .retroSnake: "scribble.variable"
        case .neonStream: "waveform.path"
        case .reaction: "hand.tap.fill"
        case .sineWave: "waveform"
        case .retinueScanning: "barcode.viewfinder"
        case .rotatingWindmill: "fanblades.fill"
        case .colorfulWaterfall: "water.waves"
        case .blossoming: "camera.macro"
        case .rotatingStorm: "tornado"
        case .perKey: "keyboard"
        }
    }
}

extension RGB {
    var color: Color { Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255) }
}

/// The Mac/Windows modifier layout. The aula-remap background helper does the remapping
/// (and re-applies it on every reconnect); this just flips its setting.
enum KeyLayout {
    static let helper = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("aula-remap/aula-remap")
    static let file = helper.deletingLastPathComponent().appendingPathComponent("layout")

    static var isMac: Bool { (try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) == "mac" }
    static var helperInstalled: Bool { FileManager.default.isExecutableFile(atPath: helper.path) }

    static let label = "com.aulalights.remap"
    static var bundled: URL? { Bundle.main.url(forResource: "aula-remap", withExtension: nil) }

    /// Installs (or updates) the helper that ships inside the app: copies it to Application
    /// Support and runs it as a LaunchAgent, like remap/install.sh does for source builds.
    static func installHelper() throws {
        guard let bundled else { throw AulaError.badReply("the app bundle (helper missing)") }
        let fm = FileManager.default
        let dir = helper.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if fm.fileExists(atPath: helper.path) { try fm.removeItem(at: helper) }
        try fm.copyItem(at: bundled, to: helper)

        let agents = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")
        try fm.createDirectory(at: agents, withIntermediateDirectories: true)
        let plist = agents.appendingPathComponent("\(label).plist")
        let log = dir.appendingPathComponent("aula-remap.log").path
        let job: [String: Any] = ["Label": label, "ProgramArguments": [helper.path], "RunAtLoad": true, "KeepAlive": true,
                                  "StandardOutPath": log, "StandardErrorPath": log]
        try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0).write(to: plist)

        let uid = getuid()
        launchctl(["bootout", "gui/\(uid)/\(label)"])
        launchctl(["bootstrap", "gui/\(uid)", plist.path])
    }

    /// The installed helper is older than the one in this app: replace it quietly.
    static var helperOutdated: Bool {
        guard helperInstalled, let bundled,
              let a = try? Data(contentsOf: bundled), let b = try? Data(contentsOf: helper) else { return false }
        return a != b
    }

    private static func launchctl(_ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }

    static func set(mac: Bool) throws { try run(["--layout", mac ? "mac" : "windows"]) }

    /// "dial": the helper stops the AULA knob's own volume/mute so the dial can use it.
    static func setKnob(dial: Bool) throws { try run(["--knob", dial ? "dial" : "volume"]) }

    private static func run(_ args: [String]) throws {
        let p = Process()
        p.executableURL = helper
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
    }
}

/// An on-screen approximation of the keyboard's built-in effects (the firmware draws
/// the real ones, and there's no way to read its animation back).
enum EffectPreview {
    static func colors(_ s: LightState, off: Bool, at t: Double) -> [(Double, Double, Double)] {
        var out = [(Double, Double, Double)](repeating: (0, 0, 0), count: 126)
        guard !off, s.effect != .off else { return out }
        let level = Double(s.brightness) / 9
        let tt = t * (0.35 + Double(s.speed) * 0.3)
        let ownColors = !s.effect.supportsColor || s.rainbow
        let chosen = (Double(s.color.r) / 255, Double(s.color.g) / 255, Double(s.color.b) / 255)
        let cx = Layout.width / 2, cy = Layout.height / 2

        for k in Layout.keys {
            var c = ownColors ? hue(k.x / 16) : chosen
            var v = 1.0
            switch s.effect {
            case .off: v = 0
            case .fixedOn, .perKey: break
            case .respire: v = 0.12 + 0.88 * (0.5 + 0.5 * sin(tt * 2.2))
            case .rainbow, .colorfulWaterfall, .neonStream, .sineWave:
                if ownColors { c = hue(k.x / 16 - tt * 0.25 + (s.effect == .colorfulWaterfall ? k.y * 0.06 : 0)) }
                else { v = 0.25 + 0.75 * (0.5 + 0.5 * sin(k.x * 0.7 - tt * 3)) }
            case .rainbowWheel, .rotatingWindmill, .rotatingStorm:
                let a = atan2(k.y - cy, k.x - cx) / (2 * .pi)
                if ownColors { c = hue(a + tt * 0.2) } else { v = 0.25 + 0.75 * (0.5 + 0.5 * sin(a * 4 * .pi - tt * 3)) }
            case .retroSnake, .retinueScanning:
                let pos = (tt * 5).truncatingRemainder(dividingBy: 20) - 2
                v = 0.05 + exp(-pow(k.x - pos, 2) / 1.5)
            default:  // twinkles, raindrops, ripples, reaction…
                let seed = sin(Double(k.led) * 12.9898) * 43758.5453
                v = 0.08 + pow(max(0, sin(tt * 1.7 + (seed - floor(seed)) * 40)), 10)
            }
            out[k.led] = (c.0 * v * level, c.1 * v * level, c.2 * v * level)
        }
        return out
    }
}

/// Reads the Mac's output volume, and tells us when it changes, so the knob's ring
/// always matches the real level however it was changed.
enum SystemVolume {
    private static func outputDevice() -> AudioObjectID? {
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return nil }
        return device
    }

    static func read() -> (level: Double, muted: Bool)? {
        guard let device = outputDevice() else { return nil }
        var level = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                                 mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &level) == noErr else { return nil }
        var muted = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyMute
        _ = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted)
        return (Double(level), muted != 0)
    }

    static func observe(_ handler: @escaping () -> Void) {
        guard let device = outputDevice() else { return }
        for selector in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyMute] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput,
                                                     mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(device, &address, .main) { _, _ in handler() }
        }
    }
}

/// Curated one-click looks for the built-in effects.
struct Mood: Identifiable {
    let name: String
    let state: LightState
    var id: String { name }

    static let all: [Mood] = [
        Mood(name: "Studio", state: LightState(effect: .fixedOn, brightness: 4, speed: 2, rainbow: false, color: RGB(r: 255, g: 190, b: 120))),
        Mood(name: "Arc reactor", state: LightState(effect: .respire, brightness: 9, speed: 2, rainbow: false, color: RGB(r: 0, g: 170, b: 255))),
        Mood(name: "Ember", state: LightState(effect: .starsTwinkle, brightness: 7, speed: 1, rainbow: false, color: RGB(r: 255, g: 60, b: 20))),
        Mood(name: "Aurora", state: LightState(effect: .colorfulWaterfall, brightness: 6, speed: 1, rainbow: true, color: RGB(r: 0, g: 230, b: 160))),
        Mood(name: "Nightfall", state: LightState(effect: .sineWave, brightness: 3, speed: 1, rainbow: false, color: RGB(r: 150, g: 70, b: 255))),
    ]
}

// MARK: - Controller

enum Mode: Int, CaseIterable, Identifiable {
    case effects, ripple, heatmap, game
    var id: Int { rawValue }

    var title: String {
        switch self {
        case .effects: "Effects"
        case .ripple: "Typing ripple"
        case .heatmap: "Heatmap"
        case .game: "Whack-a-key"
        }
    }

    var short: String {
        switch self {
        case .effects: "Effects"
        case .ripple: "Ripple"
        case .heatmap: "Heatmap"
        case .game: "Play"
        }
    }

    /// Set as "roman italic": the second word carries the accent.
    var headline: (String, String) {
        switch self {
        case .effects: ("Built-in", "light")
        case .ripple: ("Typing", "ripple")
        case .heatmap: ("Your", "heatmap")
        case .game: ("Whack", "a key")
        }
    }

    var tagline: String {
        switch self {
        case .effects: "Eighteen effects that run on the keyboard itself. Choose one, set the colour, and it stays."
        case .ripple: "Every key you press sends a ring of light across the board."
        case .heatmap: "Keys warm with use and cool with rest. A picture of how you type."
        case .game: "A key lights up. Hit it before it moves. Thirty seconds on the clock."
        }
    }

    var isLive: Bool { self != .effects }
}

final class Controller: ObservableObject {
    static let shared = Controller()
    /// The receiver can't report the colour, so the last one applied is remembered.
    static var lastColor: RGB {
        get { UserDefaults.standard.string(forKey: "lastColor").flatMap(RGB.init(hex:)) ?? RGB(r: 0, g: 170, b: 255) }
        set { UserDefaults.standard.set(newValue.hex, forKey: "lastColor") }
    }
    static var snapshotMode = false

    @Published var state = LightState(effect: .fixedOn, brightness: 7, speed: 2, rainbow: false, color: RGB(r: 0, g: 170, b: 255))
    @Published var lightsOff = false
    @Published var status = "Looking for the keyboard…"
    @Published var connected = false
    @Published var needsPermission = false
    @Published var connection = "USB-C"  // or "2.4 GHz receiver"  // the cable is fine; macOS hasn't allowed access yet
    @Published var busy = false
    @Published var live = true
    @Published private(set) var liveOn = false  // a scene is streaming to the real keyboard
    @Published var macLayout = KeyLayout.isMac
    @Published private(set) var mode = Mode(rawValue: UserDefaults.standard.integer(forKey: "mode")) ?? .effects
    @Published var game = GameState()
    @Published private(set) var wpm = 0
    @Published private(set) var knobRecentlyTurned = false
    @Published var ripple: RippleSettings = Controller.loadRipple() {
        didSet {
            rippleScene.settings = ripple
            if let data = try? JSONEncoder().encode(ripple) { UserDefaults.standard.set(data, forKey: "ripple") }
        }
    }
    @Published var heatMemory = 40.0 { didSet { heatScene.halfLife = heatMemory } }
    @Published var toast: String?
    @Published var previewEffect: Effect?      // hovering an effect name previews it on screen
    @Published var previewState: LightState?   // hovering a mood does the same
    @Published var showShortcuts = false
    @Published var showTheme = false
    @Published var appearance = Appearance(rawValue: UserDefaults.standard.string(forKey: "theme.appearance") ?? "") ?? .dark {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: "theme.appearance") }
    }
    @Published var accent = Accent(rawValue: UserDefaults.standard.string(forKey: "theme.accent") ?? "") ?? .champagne {
        didSet { UserDefaults.standard.set(accent.rawValue, forKey: "theme.accent") }
    }
    /// The cursor spotlight and the light sweep. Off for a calmer window.
    @Published var ambient = UserDefaults.standard.object(forKey: "theme.ambient") as? Bool ?? true {
        didSet { UserDefaults.standard.set(ambient, forKey: "theme.ambient") }
    }
    @Published var sounds = UserDefaults.standard.object(forKey: "sounds") as? Bool ?? true {
        didSet { UserDefaults.standard.set(sounds, forKey: "sounds") }
    }
    @Published private(set) var cablePresent = Keyboard.isPresent()
    @Published private(set) var accessGranted = F75.accessGranted
    @Published var onboarded = UserDefaults.standard.bool(forKey: "onboarded") {
        didSet { UserDefaults.standard.set(onboarded, forKey: "onboarded") }
    }
    var showWelcome: Bool { !Controller.snapshotMode && (!onboarded || !accessGranted) }

    let engine = LiveEngine()
    let monitor = InputMonitor()
    let dial = Dial()
    /// The knob as a dial menu (otherwise it's plain volume and mute, as AULA made it).
    @Published var dialEnabled = UserDefaults.standard.bool(forKey: "dial.enabled") {
        didSet { UserDefaults.standard.set(dialEnabled, forKey: "dial.enabled") }
    }
    let rippleScene = RippleScene()
    let heatScene = HeatmapScene()
    let gameScene = WhackScene()

    // Live input from the keyboard, read by the drawing every frame (not @Published on purpose).
    private var keysDown = Set<Int>()
    private var lastPress: [Int: Double] = [:]
    private var keyTimes: [Double] = []
    private(set) var knobAngle = 0.0
    private var knobTarget = 0.0
    private var knobTouched = -100.0
    private(set) var volume: Double? = SystemVolume.read()?.level
    private(set) var muted = SystemVolume.read()?.muted ?? false

    private let queue = DispatchQueue(label: "aula-lights.usb")  // keep USB work off the UI thread
    private var pending: DispatchWorkItem?
    private var lastSent: LightState?  // what the keyboard was last known to show (as displayed)
    private var ticker: Timer?
    private var toastWork: DispatchWorkItem?
    var sweepAt = -10.0  // start of the light sweep across the drawing

    var scene: LiveScene? {
        switch mode {
        case .effects: nil
        case .ripple: rippleScene
        case .heatmap: heatScene
        case .game: gameScene
        }
    }

    private init() {
        rippleScene.settings = ripple
        heatScene.halfLife = heatMemory
        engine.onFailure = { [weak self] message in
            self?.liveOn = false
            self?.status = "Live lighting stopped: \(message)"
        }
        gameScene.onChange = { [weak self] state in
            guard let self else { return }
            let before = game
            game = state
            guard sounds else { return }
            if state.hits > before.hits { NSSound(named: "Tink")?.play() }
            if state.misses > before.misses { NSSound(named: "Funk").map { $0.volume = 0.35; $0.play() } }
            if case .countdown(let n) = state.phase, before.phase != state.phase, n > 0 { NSSound(named: "Pop")?.play() }
            if state.phase == .over && before.phase != .over { NSSound(named: "Glass")?.play() }
        }
        monitor.onKey = { [weak self] usage, down in self?.keyEvent(usage: usage, down: down) }
        monitor.onKnob = { [weak self] usage in self?.knobEvent(usage) }
        monitor.start()
        if KeyLayout.helperOutdated && !Controller.snapshotMode { try? KeyLayout.installHelper() }
        if dialEnabled && KeyLayout.helperInstalled && !Controller.snapshotMode { try? KeyLayout.setKnob(dial: true) }
        SystemVolume.observe { [weak self] in self?.readVolume() }

        // Shortcuts, and no beeps: this window has no text fields, so typing here is for the
        // lights. The colour panel keeps its keys (it's a separate panel).
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Leave typing alone in other windows (popovers, panels) and in any text field.
            guard let self, !(event.window is NSPanel), event.window === NSApp.mainWindow,
                  !(event.window?.firstResponder is NSText) else { return event }
            return handleShortcut(event) ? nil : event
        }
        // Typing speed decays when you stop, and the volume readout times out.
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
    }

    private static func loadRipple() -> RippleSettings {
        guard let data = UserDefaults.standard.data(forKey: "ripple"),
              let saved = try? JSONDecoder().decode(RippleSettings.self, from: data) else { return RippleSettings() }
        return saved
    }

    // MARK: Input

    private func keyEvent(usage: Int, down: Bool) {
        guard let key = Layout.byUsage[usage] else { return }
        guard down else { keysDown.remove(key.led); return }
        let now = LiveEngine.now
        // The board reports through two interfaces; one press should count once.
        let repeatEvent = (lastPress[key.led].map { now - $0 < 0.04 } ?? false) || keysDown.contains(key.led)
        keysDown.insert(key.led)
        lastPress[key.led] = now
        guard !repeatEvent else { return }
        keyTimes.append(now)
        updateWPM(now: now)
        if liveOn { engine.press(key) } else { scene?.press(key, at: now) }
    }

    private func knobEvent(_ usage: Int) {
        if dialEnabled && !Controller.snapshotMode { dial.knob(usage) }
        switch usage {
        case 0xE9: knobTarget += 24
        case 0xEA: knobTarget -= 24
        default: break  // 0xE2: pressing the knob mutes
        }
        knobTouched = LiveEngine.now
        knobRecentlyTurned = true
        for delay in [0.08, 0.3] {  // macOS applies the change a moment after the key event
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.readVolume() }
        }
    }

    private func readVolume() {
        if let v = SystemVolume.read() { volume = v.level; muted = v.muted }
    }

    private func updateWPM(now: Double) {
        keyTimes.removeAll { now - $0 > 12 }
        // 5 keystrokes per word, over a 12 second window
        let value = Int((Double(keyTimes.count) / 5 * (60 / 12)).rounded())
        if value != wpm { wpm = value }
    }

    private func tick() {
        let now = LiveEngine.now
        updateWPM(now: now)
        let recent = now - knobTouched < 2.2
        if recent != knobRecentlyTurned { knobRecentlyTurned = recent }

        // Notice the cable going in or out, and connect without a Refresh.
        let present = Keyboard.isPresent()
        let access = F75.accessGranted
        if access != accessGranted { accessGranted = access }
        if present != cablePresent {
            cablePresent = present
            if present && access { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.refresh() } }
            if !present && !liveOn { connected = false; status = "Plug in the USB-C cable to control the lights" }
        }
    }

    func showToast(_ text: String) {
        toastWork?.cancel()
        withAnimation(.easeOut(duration: 0.25)) { toast = text }
        let work = DispatchWorkItem { [weak self] in withAnimation(.easeIn(duration: 0.35)) { self?.toast = nil } }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.9, execute: work)
    }

    func sweep() { if ambient { sweepAt = LiveEngine.now } }

    /// Returns true when the key press was handled (or should be swallowed).
    private func handleShortcut(_ e: NSEvent) -> Bool {
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = e.charactersIgnoringModifiers ?? ""
        if flags.contains(.command) {
            if let n = Int(chars), let m = Mode(rawValue: n - 1) { setMode(m); return true }
            return false  // leave the menu shortcuts alone (Cmd-Q and friends)
        }
        if chars == "?" { withAnimation(.easeOut(duration: 0.25)) { showShortcuts.toggle() }; return true }
        if e.keyCode == 53 { withAnimation(.easeOut(duration: 0.25)) { showShortcuts = false; showTheme = false }; return true }  // Esc
        switch mode {
        case .effects:
            let list = Effect.builtIn
            let i = list.firstIndex(of: state.effect) ?? 0
            switch e.keyCode {
            case 123: state.effect = list[(i - 1 + list.count) % list.count]
            case 124: state.effect = list[(i + 1) % list.count]
            case 126: state.brightness = min(9, state.brightness + 1)
            case 125: state.brightness = max(0, state.brightness - 1)
            default: break
            }
        case .game:
            if e.keyCode == 49, !gameScene.isActive { startGame() }  // Space starts a round
        default:
            break
        }
        return true
    }

    /// 0...1: how far a key is pushed down in the drawing (held, or easing back up).
    func pressAmount(_ led: Int, now: Double) -> Double {
        if keysDown.contains(led) { return 1 }
        guard let t = lastPress[led] else { return 0 }
        return max(0, 1 - (now - t) / 0.16)
    }

    /// 0...1: how bright the knob's ring is (full while turning, then fades back).
    func knobActivity(now: Double) -> Double {
        let age = now - knobTouched
        return age < 1.6 ? 1 : max(0, 1 - (age - 1.6) / 0.6)
    }

    /// Eases the drawn knob toward the real one; called once per frame.
    func stepKnob(reduceMotion: Bool) {
        knobAngle = reduceMotion ? knobTarget : knobAngle + (knobTarget - knobAngle) * 0.28
    }

    /// Colours for the on-screen keyboard right now.
    func displayColors(at t: Double) -> [RGBf] {
        if liveOn {
            let colors = engine.latestColors
            if !colors.isEmpty { return colors }
        }
        var colors: [RGBf]
        if let scene {
            colors = scene.colors(at: t)
        } else {
            var shown = previewState ?? state
            if let previewEffect { shown.effect = previewEffect }
            colors = EffectPreview.colors(shown, off: lightsOff && previewState == nil && previewEffect == nil, at: t)
        }
        // A band of light passing across the board after a change.
        let age = t - sweepAt
        if age < 0.8 {
            let pos = -2 + age / 0.8 * (Layout.width + 4)
            for k in Layout.keys {
                let v = 0.6 * exp(-pow(k.x - pos, 2) / 1.1) * (1 - age / 0.8 * 0.4)
                let c = colors[k.led]
                colors[k.led] = (min(1, c.0 + v), min(1, c.1 + v * 0.96), min(1, c.2 + v * 0.9))
            }
        }
        return colors
    }

    func applyMood(_ mood: Mood) {
        previewState = nil
        state = mood.state  // live mode sends it; otherwise Apply does
        if !live { apply(mood.state) }
        showToast(mood.name)
    }

    /// A key on the drawing was clicked.
    func tapKey(_ key: KeyPos) {
        lastPress[key.led] = LiveEngine.now
        if liveOn { engine.press(key) } else { scene?.press(key, at: LiveEngine.now) }
    }

    func testRipple() {
        guard let g = Layout.byUsage[0x0A] else { return }
        tapKey(g)
    }

    // MARK: Modes

    func setMode(_ new: Mode) {
        guard new != mode else { return }
        if mode == .game { gameScene.cancel() }
        if !new.isLive && liveOn { setLive(false) }
        withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) { mode = new }
        UserDefaults.standard.set(new.rawValue, forKey: "mode")
        previewEffect = nil; previewState = nil
        sweep()
        if liveOn, let scene { engine.setScene(scene) }
    }

    /// Streams the current scene to the real keyboard (or stops and restores its lighting).
    func setLive(_ on: Bool) {
        guard on != liveOn else { return }
        pending?.cancel()
        if on && !Keyboard.isPresent() {
            status = "Live modes need the USB-C cable or the 2.4 GHz receiver"
            showToast("Connect the cable or the receiver")
            return
        }
        do {
            if on {
                try engine.start(scene ?? rippleScene)
                liveOn = true
                connected = true
                status = "Live on the keyboard"
                showToast("Now on the keyboard")
            } else {
                liveOn = false
                try engine.stop()
                status = "Live lighting off, previous lighting restored"
                showToast("Your lighting is back")
            }
        } catch {
            liveOn = false
            status = error.localizedDescription
        }
    }

    /// Saves the keyboard's own built-in ripple ("Ripples shining") in the ripple colour.
    /// The keyboard then runs it by itself on any connection, Bluetooth included, with no app.
    func useBuiltInRipple() {
        if liveOn { setLive(false) }  // restores the saved lighting first
        let target = LightState(effect: .ripplesShining,
                                brightness: max(state.brightness, 6),
                                speed: min(4, max(0, Int((ripple.speed / 7).rounded()))),
                                rainbow: ripple.rainbow,
                                color: ripple.color)
        lastSent = target  // the automatic "apply changes" shouldn't send it a second time
        state = target
        setMode(.effects)
        apply(target)
        showToast("Ripples is now running on the keyboard itself")
    }

    func startGame() {
        if connected && !liveOn { setLive(true) }  // light the real board too, when we can
        gameScene.start(at: LiveEngine.now)
    }

    // MARK: Built-in effects

    func refresh() {
        guard !liveOn else { return }
        busy = true
        queue.async {
            let result = Result { () throws -> LightState in
                let device = try Keyboard.open()
                var current = try device.state()
                // Left in per-key mode over the receiver by a crash mid-stream? Put it back.
                if let link = device as? WirelessLink, current.effect == .perKey,
                   let disk = try? Data(contentsOf: LiveEngine.radioBackupURL), disk.count == 200 {
                    try link.restoreConfig(stride(from: 0, to: 200, by: 20).map { Array(disk[$0..<$0 + 20]) })
                    try? FileManager.default.removeItem(at: LiveEngine.radioBackupURL)
                    return try link.state()
                }
                guard let kb = device as? F75 else { return current }
                // Left in per-key mode by a crash mid-stream? Put the old lighting back.
                if current.effect == .perKey, let saved = try? Data(contentsOf: LiveEngine.backupURL) {
                    try kb.restoreSettings([UInt8](saved))
                    try? FileManager.default.removeItem(at: LiveEngine.backupURL)
                    current = try kb.state()
                }
                return current
            }
            let via = (try? Keyboard.open())?.connectionName ?? "USB-C"
            DispatchQueue.main.async {
                self.busy = false
                switch result {
                case .success(let current):
                    self.connection = via
                    var shown = current
                    if current.effect == .off || current.effect == .perKey { shown.effect = .fixedOn }
                    self.lastSent = shown
                    self.state = shown
                    self.lightsOff = current.effect == .off
                    self.connected = true
                    self.needsPermission = false
                    self.status = current.effect == .off ? "Connected over \(via), lighting is off" : "Connected over \(via)"
                case .failure(let error):
                    self.connected = false
                    if case .needsPermission? = error as? AulaError { self.needsPermission = true } else { self.needsPermission = false }
                    self.status = (error as? AulaError).map { if case .notFound = $0 { "Plug in the USB-C cable to control the lights" } else { $0.localizedDescription } }
                        ?? error.localizedDescription
                }
            }
        }
    }

    /// Called whenever an effect control changes. In live mode, waits for a short pause
    /// so dragging a slider sends one write instead of dozens.
    func changed() {
        guard live, !liveOn, mode == .effects, state != lastSent else { return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self.map { $0.apply($0.state) } }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    func apply(_ target: LightState) {
        if liveOn { setLive(false) }
        pending?.cancel()
        busy = true
        queue.async {
            let result = Result { () throws -> String in
                let kb = try Keyboard.open()
                try kb.apply(target)
                return kb.connectionName
            }
            DispatchQueue.main.async {
                self.busy = false
                switch result {
                case .success(let via):
                    Controller.lastColor = target.color
                    self.connection = via
                    if target.effect != .off { self.lastSent = target }
                    self.lightsOff = target.effect == .off
                    self.connected = true
                    self.status = target.effect == .off ? "Lighting off" : "On the keyboard: \(target.effect.title)"
                    self.sweep()
                    self.showToast(target.effect == .off ? "Lights off" : "Saved on the keyboard")
                case .failure(let error):
                    if case .notFound? = error as? AulaError { self.connected = false }
                    self.status = error.localizedDescription
                }
            }
        }
    }

    /// Opens System Settings at Privacy & Security > Input Monitoring.
    func openPermissionSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    /// macOS only applies a new Input Monitoring permission to a fresh launch.
    func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    func turnOff() {
        var s = state
        s.effect = .off
        apply(s)
    }

    func setDial(_ on: Bool) {
        guard ensureHelper() else { return }
        do {
            try KeyLayout.setKnob(dial: on)
            dialEnabled = on
            if !on { dial.close() }
            showToast(on ? "Knob is a dial now. Click it to open the ring" : "Knob is volume again")
        } catch {
            status = "Couldn't change the knob: \(error.localizedDescription)"
        }
    }

    /// The dial's Lights tool: one step of keyboard brightness, sent after a short pause.
    func nudgeBrightness(_ step: Int) {
        state.brightness = min(9, max(0, state.brightness + step))
        guard !liveOn else { return }  // live modes draw their own light
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self.map { $0.apply($0.state) } }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    /// Makes sure the background helper (Mac layout and the dial) is installed.
    func ensureHelper() -> Bool {
        if KeyLayout.helperInstalled { return true }
        do {
            try KeyLayout.installHelper()
            Thread.sleep(forTimeInterval: 0.3)  // let it start
            return true
        } catch {
            status = "Couldn't install the background helper: \(error.localizedDescription)"
            showToast("Couldn't install the helper")
            return false
        }
    }

    func setLayout(mac: Bool) {
        guard ensureHelper() else { return }
        do {
            try KeyLayout.set(mac: mac)
            macLayout = mac
            status = mac ? "Mac layout: Alt is Command, Win is Option" : "Windows layout: keys work as printed"
            showToast(mac ? "Mac layout on" : "Windows layout on")
        } catch {
            status = "Couldn't switch layout: \(error.localizedDescription)"
        }
    }
}

// MARK: - Control row

struct ControlColumn<Content: View>: View {
    let title: String
    var width: CGFloat? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title).label()
            content
        }
        .frame(width: width, alignment: .leading)
    }
}

/// Effect names set as a quiet text list; the chosen one gets a champagne mark.
struct EffectList: View {
    @ObservedObject var c: Controller
    @State private var hovered: Effect?

    var body: some View {
        let columns = Array(repeating: GridItem(.fixed(134), spacing: 4, alignment: .leading), count: 4)
        LazyVGrid(columns: columns, alignment: .leading, spacing: 9) {
            ForEach(Effect.builtIn) { effect in
                let chosen = c.state.effect == effect && !c.lightsOff
                Button { c.state.effect = effect } label: {
                    HStack(spacing: 7) {
                        Circle().fill(Color.accent).frame(width: 4, height: 4).opacity(chosen ? 1 : 0)
                        Text(effect.title).font(Typeface.text(12.5, weight: chosen ? .semibold : .regular))
                            .foregroundStyle(chosen ? Ink.primary : (hovered == effect ? Ink.secondary : Ink.tertiary))
                            .lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { inside in
                    hovered = inside ? effect : (hovered == effect ? nil : hovered)
                    c.previewEffect = hovered  // show it on the drawing before committing
                }
            }
        }
        .animation(.easeOut(duration: 0.15), value: hovered)
    }
}

struct EffectsPanel: View {
    @ObservedObject var c: Controller

    var body: some View {
        HStack(alignment: .top, spacing: 44) {
            ControlColumn(title: "Effect") { EffectList(c: c) }
            ControlColumn(title: "Colour", width: 246) {
                if c.state.effect.supportsColor {
                    Swatches(color: $c.state.color, rainbow: $c.state.rainbow)
                } else {
                    Text("\(c.state.effect.title) brings its own colours.").font(Typeface.text(12.5)).foregroundStyle(Ink.tertiary)
                }
            }
            ControlColumn(title: "Tune", width: 200) {
                LineSlider(title: "Brightness", value: Binding(get: { Double(c.state.brightness) }, set: { c.state.brightness = Int($0.rounded()) }),
                           range: 0...9, step: 1) { "\(Int($0))" }
                LineSlider(title: "Speed", value: Binding(get: { Double(c.state.speed) }, set: { c.state.speed = Int($0.rounded()) }),
                           range: 0...4, step: 1) { "\(Int($0))" }
                HStack(spacing: 18) {
                    MiniSwitch(title: "Live", isOn: $c.live)
                    Spacer()
                    if !c.live { TextAction("Apply") { c.apply(c.state) } }
                    TextAction("Lights off") { c.turnOff() }
                }
            }
        }
        .onChange(of: c.state) { c.changed() }
    }
}

struct RipplePanel: View {
    @ObservedObject var c: Controller

    var body: some View {
        HStack(alignment: .top, spacing: 48) {
            ControlColumn(title: "Colour", width: 230) { Swatches(color: $c.ripple.color, rainbow: $c.ripple.rainbow) }
            ControlColumn(title: "Wave", width: 190) {
                LineSlider(title: "Intensity", value: $c.ripple.intensity, range: 0.1...1) { "\(Int($0 * 100))%" }
                LineSlider(title: "Reach", value: $c.ripple.spread, range: 2...16) { "\(Int($0)) keys" }
            }
            ControlColumn(title: "Motion", width: 190) {
                LineSlider(title: "Speed", value: $c.ripple.speed, range: 3...30) { "\(Int($0))" }
                LineSlider(title: "Ring width", value: $c.ripple.width, range: 0.4...3) { String(format: "%.1f", $0) }
            }
            ControlColumn(title: "Texture", width: 190) {
                LineSlider(title: "Echo rings", value: Binding(get: { Double(c.ripple.rings) }, set: { c.ripple.rings = Int($0.rounded()) }),
                           range: 1...3, step: 1) { "\(Int($0))" }
                LineSlider(title: "Idle glow", value: $c.ripple.background, range: 0...0.4) { "\(Int($0 * 100))%" }
            }
            ControlColumn(title: "Try") {
                TextAction("Drop one") { c.testRipple() }
                TextAction("Defaults") { c.ripple = RippleSettings() }
                TextAction("Use the keyboard's own ripple") { c.useBuiltInRipple() }
                    .help("Saves the keyboard's built-in Ripples effect in this colour. It then runs on the keyboard by itself, on Bluetooth too, without the app.")
                Text("Runs on Bluetooth without the app, but always crosses the whole board; Reach and the sliders here only shape this app's ripple.")
                    .font(Typeface.text(11)).foregroundStyle(Ink.tertiary).frame(width: 190, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct HeatmapPanel: View {
    @ObservedObject var c: Controller

    var body: some View {
        HStack(alignment: .top, spacing: 64) {
            ControlColumn(title: "Scale", width: 260) {
                LinearGradient(colors: stride(from: 0.0, through: 1.0, by: 0.125).map { v in
                    let c = HeatmapScene.ramp(v); return Color(red: c.0, green: c.1, blue: c.2)
                }, startPoint: .leading, endPoint: .trailing)
                .frame(height: 3).clipShape(Capsule())
                HStack { Text("Rested"); Spacer(); Text("Well used") }
                    .font(Typeface.text(11.5)).foregroundStyle(Ink.tertiary)
            }
            ControlColumn(title: "Memory", width: 240) {
                LineSlider(title: "Cools off after", value: $c.heatMemory, range: 10...180) { "\(Int($0)) s" }
            }
            ControlColumn(title: "Map") {
                TextAction("Clear it") { c.heatScene.reset(); c.showToast("Map cleared") }
                Text("Counts keys typed anywhere on your Mac. Nothing is stored or sent.")
                    .font(Typeface.text(11.5)).foregroundStyle(Ink.tertiary).frame(width: 260, alignment: .leading)
            }
        }
    }
}

struct GamePanel: View {
    @ObservedObject var c: Controller

    private var playing: Bool {
        if case .countdown = c.game.phase { return true }
        return c.game.phase == .playing
    }

    var body: some View {
        HStack(alignment: .top, spacing: 64) {
            ControlColumn(title: "Round") {
                PrimaryButton(title: playing ? "Stop" : (c.game.phase == .over ? "Play again" : "Play")) {
                    if playing { c.gameScene.cancel(); c.game = GameState() } else { c.startGame() }
                }
                Text("Space starts a round").font(Typeface.text(11.5)).foregroundStyle(Ink.tertiary)
                MiniSwitch(title: "Sounds", isOn: $c.sounds)
            }
            ControlColumn(title: "Rules", width: 330) {
                Text("Hit the lit key. A quick hit scores double, every fifth in a row adds three, and a wrong key resets the run.")
                    .font(Typeface.text(12.5)).lineSpacing(3).foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ControlColumn(title: "Best") {
                Text("\(c.game.best)").font(Typeface.display(40)).monospacedDigit().foregroundStyle(Color.accent)
            }
        }
    }
}

/// The calm strip of controls along the bottom, under a single hairline.
struct ControlRow: View {
    @ObservedObject var c: Controller

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.hairline).frame(height: 1)
            Group {
                switch c.mode {
                case .effects: EffectsPanel(c: c)
                case .ripple: RipplePanel(c: c)
                case .heatmap: HeatmapPanel(c: c)
                case .game: GamePanel(c: c)
                }
            }
            .id(c.mode)
            .transition(.opacity)
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
            .padding(.horizontal, MainView.margin).padding(.top, 30).padding(.bottom, 36)
        }
        .background(Color.stage.opacity(0.55))
        .animation(.easeOut(duration: 0.3), value: c.mode)
    }
}

/// Under the title in live modes: whether the real keyboard shows it too.
struct LiveToggle: View {
    @ObservedObject var c: Controller

    var body: some View {
        HStack(spacing: 16) {
            MiniSwitch(title: "Show on the keyboard", isOn: Binding(get: { c.liveOn }, set: { c.setLive($0) }))
            if !c.connected {
                Text("Needs the USB-C cable or the 2.4 GHz receiver").font(Typeface.text(11.5)).foregroundStyle(Ink.tertiary)
            } else if c.connection != "USB-C" {
                Text("Over the receiver: 20 updates a second").font(Typeface.text(11.5)).foregroundStyle(Ink.tertiary)
            }
        }
    }
}

struct MainView: View {
    @ObservedObject var c: Controller
    @Environment(\.colorScheme) private var systemScheme
    static let margin: CGFloat = 80

    private var theme: Theme {
        let dark = switch c.appearance {
        case .dark: true
        case .light: false
        case .auto: systemScheme == .dark
        }
        return Theme(dark: dark, accentChoice: c.accent)
    }

    var body: some View {
        let theme = theme
        let _ = { Theme.current = theme }()  // everything below draws from this
        content
            .id(theme)  // a new theme redraws the whole window
            .preferredColorScheme(c.appearance == .auto ? nil : (theme.dark ? .dark : .light))
            .animation(.easeInOut(duration: 0.35), value: theme)
    }

    private var content: some View {
        ZStack(alignment: .top) {
            KeyboardStage(c: c, topInset: 322, bottomInset: 262)
            VStack(alignment: .leading, spacing: 0) {
                TopBar(c: c)
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 22) {
                        TitleBlock(c: c)
                        if c.mode.isLive { LiveToggle(c: c).transition(.opacity) }
                    }
                    Spacer()
                    StatsBlock(c: c)
                }
                .padding(.horizontal, MainView.margin).padding(.top, 34)
                Spacer()
                ControlRow(c: c)
            }
            ToastView(c: c)
            if c.showShortcuts { ShortcutsCard(c: c) }
            if c.showTheme { ThemePanel(c: c) }
            if c.showWelcome { WelcomeView(c: c).transition(.opacity) }
        }
        .animation(.easeOut(duration: 0.3), value: c.showWelcome)
        .frame(minWidth: 1220, minHeight: 880)
        .background(Color.stage)
        .tint(.accent)
        .onAppear { c.refresh() }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        // Never leave the keyboard in per-key mode when the app goes away.
        if Controller.shared.liveOn { try? Controller.shared.engine.stop() }
        // Give the knob back to volume (the helper also does this if the app crashes).
        if Controller.shared.dialEnabled { try? KeyLayout.setKnob(dial: false) }
    }
}

struct AulaLightsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var controller = Controller.shared
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("Aula Lights", id: "main") {
            MainView(c: controller)
        }
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)

        MenuBarExtra("AULA Lights", systemImage: "keyboard.badge.ellipsis") {
            Button("Open AULA Lights") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
            Divider()
            ForEach(Mode.allCases) { mode in
                Button(mode.title) { controller.setMode(mode); openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
            }
            Toggle("Light up the keyboard", isOn: Binding(get: { controller.liveOn }, set: { controller.setLive($0) }))
                .disabled(!controller.mode.isLive)
            Toggle("Mac layout (Alt = Command, Win = Option)", isOn: Binding(get: { controller.macLayout }, set: { controller.setLayout(mac: $0) }))
            Toggle("Use the knob as a dial", isOn: Binding(get: { controller.dialEnabled }, set: { controller.setDial($0) }))
            Divider()
            Button("Breathing Jarvis blue") {
                controller.setMode(.effects)
                controller.apply(LightState(effect: .respire, brightness: 9, speed: controller.state.speed, rainbow: false, color: RGB(r: 0, g: 170, b: 255)))
            }
            Button("Lights off") { controller.setMode(.effects); controller.turnOff() }
            Divider()
            Button("Quit") { NSApp.terminate(nil) }
        }
    }
}

@main
enum Entry {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst()).filter { !$0.hasPrefix("-psn_") }
        Typeface.register()
        if args.first == "make-icon", args.count > 1 { exit(IconMaker.write(to: URL(fileURLWithPath: args[1]))) }
        if args.first == "snapshot", args.count > 1 { exit(snapshot(to: args[1], mode: args.count > 2 ? Int(args[2]) ?? 0 : 0)) }
        if args.isEmpty { AulaLightsApp.main() } else { exit(CLI.run(args)) }
    }

    /// Developer aid: draws the main window into a PNG (no screen-recording permission needed).
    /// Native controls (sliders, pickers) render blank this way; the drawing is what it's for.
    @MainActor static func snapshot(to path: String, mode: Int) -> Int32 {
        _ = NSApplication.shared
        Controller.snapshotMode = true
        let c = Controller.shared
        c.setMode(Mode(rawValue: mode) ?? .effects)
        c.sweepAt = -10
        c.connected = true
        c.status = "Connected over USB"
        let keys = Layout.keys
        switch c.mode {
        case .ripple:
            if let g = Layout.byUsage[0x0A] { c.tapKey(g) }
            Thread.sleep(forTimeInterval: 0.35)
        case .heatmap:
            for _ in 0..<400 { if let k = keys.filter({ "ETAOINSHRDLU".contains($0.name) || $0.name == "Space" }).randomElement() { c.heatScene.press(k, at: LiveEngine.now) } }
        case .game:
            c.gameScene.start(at: LiveEngine.now - 3.1)
            _ = c.gameScene.colors(at: LiveEngine.now)
        case .effects: break
        }
        if let v = ProcessInfo.processInfo.environment["AULA_APPEARANCE"].flatMap(Appearance.init) { c.appearance = v }
        if mode == 13 {  // the dial's level readout
            Theme.current = Theme(dark: c.appearance != .light, accentChoice: c.accent)
            c.dial.previewReadout()
            let host = NSHostingView(rootView: DialReadout(dial: c.dial).frame(width: 280, height: 84).background(Color(white: 0.5)))
            host.frame = NSRect(x: 0, y: 0, width: 280, height: 84)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return 1 }
            host.cacheDisplay(in: host.bounds, to: rep)
            return (try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))) == nil ? 1 : 0
        }
        if mode == 5 || mode == 4 {  // the dial ring (5) or its Apps ring (4)
            Theme.current = Theme(dark: c.appearance != .light, accentChoice: c.accent)
            let track = ProcessInfo.processInfo.environment["AULA_TRACK"] != nil
            c.dial.preview(apps: mode == 4, index: track ? 4 : 1)
            if track { c.dial.refreshNowPlaying(); RunLoop.main.run(until: Date().addingTimeInterval(1.5)) }
            let host = NSHostingView(rootView: DialRing(dial: c.dial).frame(width: 360, height: 360).background(Color(white: 0.5)))
            host.frame = NSRect(x: 0, y: 0, width: 360, height: 360)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return 1 }
            host.cacheDisplay(in: host.bounds, to: rep)
            return (try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))) == nil ? 1 : 0
        }
        if mode == 6 {  // the in-app colour picker on its own
            let dark = c.appearance != .light
            Theme.current = Theme(dark: dark, accentChoice: c.accent)
            let host = NSHostingView(rootView: InAppColorPicker(color: .constant(RGB(r: 0, g: 170, b: 255)), rainbow: .constant(false))
                .environment(\.colorScheme, dark ? .dark : .light))
            host.frame = NSRect(x: 0, y: 0, width: 292, height: 320)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return 1 }
            host.cacheDisplay(in: host.bounds, to: rep)
            return (try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))) == nil ? 1 : 0
        }
        if mode == 9 {  // the welcome screen, as a fresh user sees it
            let renderer = ImageRenderer(content: WelcomeView(c: c).frame(width: 1320, height: 900).background(Color.stage).environment(\.colorScheme, .dark))
            renderer.scale = 1
            guard let tiff = renderer.nsImage?.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return 1 }
            return (try? png.write(to: URL(fileURLWithPath: path))) == nil ? 1 : 0
        }
        if mode == 8 { c.toast = "Saved on the keyboard"; c.showShortcuts = true }
        if mode == 7 { c.showTheme = true }
        if let a = ProcessInfo.processInfo.environment["AULA_APPEARANCE"].flatMap(Appearance.init) { c.appearance = a }
        if let a = ProcessInfo.processInfo.environment["AULA_ACCENT"].flatMap(Accent.init) { c.accent = a }
        c.monitor.onKnob?(0xE9)       // show the knob's volume ring
        c.monitor.onKey?(0x0B, true)  // and one held key (H)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let renderer = ImageRenderer(content: MainView(c: c).frame(width: 1320, height: 900).environment(\.colorScheme, c.appearance == .light ? .light : .dark))
        renderer.scale = 1
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return 1 }
        return (try? png.write(to: URL(fileURLWithPath: path))) == nil ? 1 : 0
    }
}

// MARK: - Overlays

/// A small confirmation that fades in under the menu and leaves on its own.
struct ToastView: View {
    @ObservedObject var c: Controller

    var body: some View {
        VStack {
            if let text = c.toast {
                HStack(spacing: 9) {
                    Circle().fill(Color.accent).frame(width: 5, height: 5)
                    Text(text).font(Typeface.text(12.5, weight: .semibold)).foregroundStyle(Ink.primary)
                }
                .padding(.horizontal, 18).frame(height: 36)
                .background(Capsule().fill(Color.panel))
                .overlay(Capsule().strokeBorder(Color.hairline))
                .shadow(color: .black.opacity(0.5), radius: 16, y: 6)
                .transition(.opacity.combined(with: .offset(y: -6)))
                .padding(.top, 74)
            }
            Spacer()
        }
        .allowsHitTesting(false)
    }
}

/// Press ? for this card; Esc or ? again closes it.
struct ShortcutsCard: View {
    @ObservedObject var c: Controller

    private let rows: [(String, String)] = [
        ("⌘1 to ⌘4", "Switch mode"),
        ("← →", "Previous or next effect"),
        ("↑ ↓", "Brightness"),
        ("Space", "Start a round"),
        ("?", "Show or hide shortcuts"),
        ("Knob click", "Open the dial ring (when Dial is on)"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Shortcuts").label()
            ForEach(rows, id: \.0) { keys, action in
                HStack {
                    Text(keys).font(Typeface.text(12.5, weight: .semibold)).foregroundStyle(Ink.primary).frame(width: 96, alignment: .leading)
                    Text(action).font(Typeface.text(12.5)).foregroundStyle(Ink.secondary)
                }
            }
        }
        .padding(26)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.panel))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.hairline))
        .shadow(color: .black.opacity(0.6), radius: 30, y: 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(.top, 70).padding(.trailing, MainView.margin)
        .transition(.opacity.combined(with: .offset(y: -6)))
        .onTapGesture { c.showShortcuts = false }
    }
}

/// First launch (or lost access): three steps, each ticking itself off as it happens.
struct WelcomeView: View {
    @ObservedObject var c: Controller

    var body: some View {
        ZStack {
            Color.stage.opacity(0.82).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 30) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("Welcome to").font(Typeface.display(44))
                        Text("Aula").font(Typeface.display(44, italic: true)).foregroundStyle(Color.accent)
                    }
                    .foregroundStyle(Ink.primary)
                    Text("Two quick things and your F75 is ready.")
                        .font(Typeface.text(14)).foregroundStyle(Ink.secondary)
                }

                step(1, "Connect with the cable or the 2.4 GHz receiver",
                     detail: c.cablePresent ? "Found your keyboard." : "Lighting needs the USB-C cable or the receiver. Bluetooth works for typing only.",
                     done: c.cablePresent) { EmptyView() }

                step(2, "Allow keyboard access",
                     detail: c.accessGranted ? "Allowed." : "macOS asks apps that talk to keyboards for Input Monitoring. Turn on AulaLights, then reopen the app.",
                     done: c.accessGranted) {
                    if !c.accessGranted {
                        HStack(spacing: 20) {
                            TextAction("Open Input Monitoring") { c.openPermissionSettings() }
                            TextAction("Reopen Aula Lights") { c.relaunch() }
                        }
                    }
                }

                HStack(spacing: 22) {
                    PrimaryButton(title: "Start") {
                        c.onboarded = true
                        c.refresh()
                    }
                    .disabled(!c.accessGranted)
                    .opacity(c.accessGranted ? 1 : 0.35)
                    if c.accessGranted && !c.cablePresent {
                        Text("You can start without the cable; lighting waits until it's plugged in.")
                            .font(Typeface.text(12)).foregroundStyle(Ink.tertiary)
                    }
                }
            }
            .padding(48)
            .frame(width: 560, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.panel))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.hairline))
            .shadow(color: .black.opacity(0.7), radius: 50, y: 20)
        }
    }

    private func step<Extra: View>(_ n: Int, _ title: String, detail: String, done: Bool, @ViewBuilder extra: () -> Extra) -> some View {
        HStack(alignment: .top, spacing: 18) {
            ZStack {
                Circle().strokeBorder(done ? Color.accent : Color.hairline.opacity(2), lineWidth: 1).frame(width: 28, height: 28)
                if done {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.accent)
                } else {
                    Text("\(n)").font(Typeface.text(12, weight: .semibold)).foregroundStyle(Ink.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(Typeface.text(15, weight: .semibold)).foregroundStyle(Ink.primary)
                Text(detail).font(Typeface.text(12.5)).lineSpacing(3).foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                extra().padding(.top, 4)
            }
        }
        .animation(.easeOut(duration: 0.3), value: done)
    }
}

/// The theme panel: appearance, accent colour and the ambient touches.
struct ThemePanel: View {
    @ObservedObject var c: Controller

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Appearance").label()
                TextTabs(options: Appearance.allCases.map { ($0, $0.title) }, selection: $c.appearance, size: 12.5)
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("Accent").label()
                HStack(spacing: 10) {
                    ForEach(Accent.allCases) { accent in
                        let chosen = c.accent == accent
                        Button { c.accent = accent } label: {
                            Circle().fill(accent.color(dark: Theme.current.dark)).frame(width: 18, height: 18)
                                .padding(3)
                                .overlay(Circle().strokeBorder(chosen ? Ink.primary : .clear, lineWidth: 1))
                        }
                        .buttonStyle(PressStyle()).help(accent.title).accessibilityLabel(accent.title)
                    }
                }
                Text(c.accent.title).font(Typeface.text(12)).foregroundStyle(Ink.secondary)
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("Ambient").label()
                MiniSwitch(title: "Spotlight and light sweep", isOn: $c.ambient)
            }
        }
        .padding(26)
        .frame(width: 300, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.panel))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.hairline))
        .shadow(color: .black.opacity(Theme.current.dark ? 0.6 : 0.18), radius: 30, y: 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(.top, 70).padding(.trailing, MainView.margin + 34)
        .transition(.opacity.combined(with: .offset(y: -6)))
    }
}
