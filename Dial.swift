// The knob as a dial, Surface Dial style. Turning does the current tool (Volume by
// default). A click opens a ring of tools on screen; turn to move, click to pick.
// "Apps" opens a second ring of the apps in your Dock. A double click mutes.
//
// The remap helper stops the AULA knob's own volume/mute reaching macOS while this is on
// (and hands it back whenever the app isn't running); the app reads the knob directly.

import AppKit
import AudioToolbox
import CoreAudio
import SwiftUI

// MARK: - System controls

extension SystemVolume {
    private static func device() -> AudioObjectID? {
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return nil }
        return device
    }

    static func set(level: Double) {
        guard let device = device() else { return }
        var value = Float32(min(max(level, 0), 1))
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                                 mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
    }

    static func set(muted: Bool) {
        guard let device = device() else { return }
        var value = UInt32(muted ? 1 : 0)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                                 mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }
}

/// The Mac's own brightness and media keys. Sending them needs Accessibility permission.
enum SystemKey {
    static let brightnessUp: Int32 = 2, brightnessDown: Int32 = 3
    static let playPause: Int32 = 16, next: Int32 = 17, previous: Int32 = 18

    static var allowed: Bool { AXIsProcessTrusted() }

    /// Asks macOS for Accessibility (shows the system prompt once).
    static func requestAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func press(_ key: Int32) {
        for down in [true, false] {
            let event = NSEvent.otherEvent(with: .systemDefined, location: .zero,
                                           modifierFlags: NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00),
                                           timestamp: 0, windowNumber: 0, context: nil, subtype: 8,
                                           data1: Int((key << 16) | ((down ? 0xA : 0xB) << 8)), data2: -1)
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
    }
}

// MARK: - Now Playing

struct NowPlayingInfo: Equatable {
    var title: String
    var artist: String
    var app: String       // bundle identifier
    var playing: Bool

    /// The song name without video-site clutter: "Surat Ni - Official Music Video | ft. …" → "Surat Ni".
    var cleanTitle: String {
        var t = title.components(separatedBy: " | ").first ?? title
        let noise = ["official music video", "official video", "official audio", "lyric video", "lyrics", "music video", "full video", "video song", "audio", "video", "hd", "4k"]
        for sep in [" - ", " – ", " — "] {
            let parts = t.components(separatedBy: sep)
            if parts.count > 1, let last = parts.last, noise.contains(where: { last.lowercased().contains($0) }) {
                t = parts.dropLast().joined(separator: sep)
            }
        }
        for bracket in [("(", ")"), ("[", "]")] {
            while let open = t.range(of: bracket.0), let close = t.range(of: bracket.1, range: open.upperBound..<t.endIndex),
                  noise.contains(where: { t[open.upperBound..<close.lowerBound].lowercased().contains($0) }) {
                t.removeSubrange(open.lowerBound..<close.upperBound)
            }
        }
        let cleaned = t.trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? title : cleaned
    }

    var appName: String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app) else { return "" }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

/// What's playing in any app (Arc, Spotify, Music…), and play/pause, next, previous.
/// Runs the bundled NowPlaying.dylib inside /usr/bin/perl, which macOS answers.
enum NowPlaying {
    enum Command: String { case info, toggle, next, previous }

    private static let library: URL? = {
        let candidates = [Bundle.main.resourceURL?.appendingPathComponent("NowPlaying.dylib"),
                          FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/AulaLights.app/Contents/Resources/NowPlaying.dylib")]
        return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
    }()

    private static let queue = DispatchQueue(label: "aula-lights.nowplaying")

    /// Runs off the main thread; calls back on main with what's playing afterwards (nil if nothing).
    static func run(_ command: Command, then: @escaping (NowPlayingInfo?) -> Void = { _ in }) {
        guard let library else { then(nil); return }
        queue.async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            p.arguments = ["-e", "use DynaLoader; DynaLoader::dl_load_file($ARGV[0], 0);", library.path]
            p.environment = ["AULA_NP": command.rawValue]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            var info: NowPlayingInfo?
            if (try? p.run()) != nil {
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let title = json["title"] as? String, !title.isEmpty {
                    info = NowPlayingInfo(title: title, artist: json["artist"] as? String ?? "",
                                          app: json["app"] as? String ?? "", playing: (json["playing"] as? Bool) ?? false)
                }
            }
            DispatchQueue.main.async { then(info) }
        }
    }
}

// MARK: - Dial

final class Dial: ObservableObject {
    enum Tool: String, CaseIterable, Identifiable {
        case volume, lights, brightness, media
        var id: String { rawValue }
        var title: String {
            switch self {
            case .volume: "Volume"
            case .lights: "Keyboard lights"
            case .brightness: "Screen brightness"
            case .media: "Tracks"
            }
        }
        var symbol: String {
            switch self {
            case .volume: "speaker.wave.2.fill"
            case .lights: "keyboard"
            case .brightness: "sun.max.fill"
            case .media: "forward.fill"
            }
        }
        var needsAccessibility: Bool { self == .brightness }  // tracks go through Now Playing
    }

    enum Item: Equatable {
        case tool(Tool), apps, playPause, app(URL), back

        var title: String {
            switch self {
            case .tool(let t): t.title
            case .apps: "Apps"
            case .playPause: "Play / Pause"
            case .app(let url): FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            case .back: "Back"
            }
        }
    }

    @Published private(set) var open = false
    @Published private(set) var items: [Item] = []
    @Published private(set) var index = 0
    /// Total clicks turned while the ring is open (not wrapped), so the wedge and the ticks
    /// spin smoothly in the knob's direction, even across the top.
    @Published private(set) var spin = 0
    @Published private(set) var inApps = false
    @Published private(set) var note: String?
    @Published private(set) var nowPlaying: NowPlayingInfo?
    private var lastSkip = 0.0
    private var playingTimer: Timer?
    @Published var tool = Dial.Tool(rawValue: UserDefaults.standard.string(forKey: "dial.tool") ?? "") ?? .volume {
        didSet { UserDefaults.standard.set(tool.rawValue, forKey: "dial.tool") }
    }
    /// The small readout shown while turning: tool and, where there is one, its level (0-1).
    @Published private(set) var readout: (tool: Tool, level: Double?, text: String)?

    private var clickTimer: DispatchWorkItem?
    private var closeTimer: DispatchWorkItem?
    private var readoutTimer: DispatchWorkItem?
    private lazy var ringWindow = OverlayPanel(size: CGSize(width: 360, height: 360), placement: .centre)
    private lazy var readoutWindow = OverlayPanel(size: CGSize(width: 280, height: 84), placement: .bottom)

    static let mainItems: [Item] = [.apps, .tool(.volume), .tool(.lights), .tool(.brightness), .tool(.media), .playPause]

    /// Developer aid for snapshots: the ring in a given state, without the knob.
    func preview(apps: Bool, index: Int) {
        inApps = apps
        let env = ProcessInfo.processInfo.environment
        let many = env["AULA_MANY_APPS"] != nil  // preview: a long list
        // Public screenshots: standard Mac apps instead of this Mac's own Dock.
        let demo = env["AULA_DEMO"] != nil
            ? ["Messages", "Mail", "Music", "Notes", "Calendar", "Photos", "Maps"]
                .map { URL(fileURLWithPath: "/System/Applications/\($0).app") }
                .map { FileManager.default.fileExists(atPath: $0.path) ? $0 : URL(fileURLWithPath: "/Applications/Safari.app") }
            : nil
        let base = demo ?? Dial.dockApps()
        let apps_ = many ? base + base : base
        items = apps ? apps_.map { .app($0) } + [.back] : Dial.mainItems
        self.index = index
        spin = index
        open = true
    }

    func previewReadout() { readout = (.volume, 0.62, "62%") }

    /// Public screenshots: a made-up track instead of what's really playing.
    func previewTrack() { nowPlaying = NowPlayingInfo(title: "Northern Lights", artist: "Sample Artist", app: "com.apple.Music", playing: true) }

    /// Shows the track summary in the centre for these items.
    var showsTrack: Bool {
        guard items.indices.contains(index), nowPlaying != nil else { return false }
        return items[index] == .tool(.media) || items[index] == .playPause
    }

    /// The selected item's current value, shown under its name in the centre.
    var detail: String? {
        guard items.indices.contains(index) else { return nil }
        switch items[index] {
        case .tool(.volume):
            guard let v = SystemVolume.read() else { return nil }
            return v.muted ? "Muted" : "\(Int((v.level * 100).rounded()))%"
        case .tool(.lights): return "\(Controller.shared.state.brightness) of 9"
        case .tool(.media), .playPause: return nowPlaying == nil ? "Nothing playing" : nil
        case .tool(let t) where t == tool: return "In use"
        case .apps: return "\(Dial.dockApps().count) apps"
        case .app(let url):
            let running = NSWorkspace.shared.runningApplications.contains { $0.bundleURL == url }
            let place = items.count > DialRing.slots ? "\(index + 1) of \(items.count - 1)" : nil
            return [place, running ? "Running" : nil].compactMap { $0 }.joined(separator: " · ").nilIfEmpty
        default: return nil
        }
    }

    // MARK: Knob input

    /// 0xE9 turn right, 0xEA turn left, 0xE2 click.
    func knob(_ usage: Int) {
        switch usage {
        case 0xE9: turn(+1)
        case 0xEA: turn(-1)
        case 0xE2: click()
        default: break
        }
    }

    private func click() {
        if open { select(); return }
        // Closed: wait a moment to tell a single click (open the ring) from a double (mute).
        if let pending = clickTimer {
            pending.cancel(); clickTimer = nil
            toggleMute()
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.clickTimer = nil; self?.show() }
        clickTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func turn(_ step: Int) {
        if open {
            index = (index + step + items.count) % items.count
            spin += step
            note = nil
            keepOpen()
        } else {
            use(tool, step: step)
        }
    }

    // MARK: Ring

    private func show() {
        inApps = false
        items = Dial.mainItems
        index = items.firstIndex(of: .tool(tool)) ?? 0
        spin = index
        note = nil
        open = true
        ringWindow.show(DialRing(dial: self))
        keepOpen()
        refreshNowPlaying()
        playingTimer?.invalidate()
        playingTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refreshNowPlaying() }
    }

    func refreshNowPlaying() { NowPlaying.run(.info) { [weak self] in self?.nowPlaying = $0 } }

    func close() {
        open = false
        playingTimer?.invalidate(); playingTimer = nil
        closeTimer?.cancel()
        ringWindow.hide()
    }

    /// Closes the ring after a few seconds without input.
    private func keepOpen() {
        closeTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.close() }
        closeTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    private func select() {
        guard items.indices.contains(index) else { return }
        switch items[index] {
        case .tool(let t):
            if t.needsAccessibility && !SystemKey.allowed {
                SystemKey.requestAccess()
                note = "Allow Aula Lights under Accessibility, then pick it again"
                keepOpen()
                return
            }
            tool = t
            close()
            showReadout(t, level: level(of: t), text: "Turning now sets \(t.title.lowercased())")
        case .apps:
            inApps = true
            items = Dial.dockApps().map { .app($0) } + [.back]
            index = 0
            spin = 0
            keepOpen()
        case .back:
            inApps = false
            items = Dial.mainItems
            index = 0
            spin = 0
            keepOpen()
        case .playPause:
            close()
            NowPlaying.run(.toggle) { [weak self] info in
                self?.nowPlaying = info
                self?.showReadout(.media, level: nil, text: info.map { $0.playing ? $0.cleanTitle : "Paused" } ?? "Nothing playing")
            }
        case .app(let url):
            close()
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    // MARK: Tools

    private func use(_ tool: Tool, step: Int) {
        switch tool {
        case .volume:
            let now = SystemVolume.read()
            let level = min(max((now?.level ?? 0.5) + Double(step) / 16, 0), 1)  // macOS's own 16 steps
            if now?.muted == true { SystemVolume.set(muted: false) }
            SystemVolume.set(level: level)
            showReadout(.volume, level: level, text: "\(Int((level * 100).rounded()))%")
        case .lights:
            let c = Controller.shared
            guard c.connected else { showReadout(.lights, level: nil, text: "Needs the cable or receiver"); return }
            c.nudgeBrightness(step)
            showReadout(.lights, level: Double(c.state.brightness) / 9, text: "\(c.state.brightness) of 9")
        case .brightness:
            guard SystemKey.allowed else { SystemKey.requestAccess(); return }
            SystemKey.press(step > 0 ? SystemKey.brightnessUp : SystemKey.brightnessDown)
            showReadout(.brightness, level: nil, text: step > 0 ? "Brighter" : "Dimmer")
        case .media:
            // One skip per turn: the clicks of a single flick of the knob count once.
            let now = ProcessInfo.processInfo.systemUptime
            defer { lastSkip = now }
            guard now - lastSkip > 0.6 else { return }
            showReadout(.media, level: nil, text: step > 0 ? "Next track" : "Previous track")
            NowPlaying.run(step > 0 ? .next : .previous) { [weak self] info in
                self?.nowPlaying = info
                self?.showReadout(.media, level: nil, text: info?.cleanTitle ?? "Nothing playing")
            }
        }
    }

    private func level(of tool: Tool) -> Double? {
        switch tool {
        case .volume: SystemVolume.read()?.level
        case .lights: Double(Controller.shared.state.brightness) / 9
        default: nil
        }
    }

    private func toggleMute() {
        let muted = !(SystemVolume.read()?.muted ?? false)
        SystemVolume.set(muted: muted)
        showReadout(.volume, level: muted ? 0 : SystemVolume.read()?.level, text: muted ? "Muted" : "Sound on")
    }

    private func showReadout(_ tool: Tool, level: Double?, text: String) {
        readout = (tool, level, text)
        readoutWindow.show(DialReadout(dial: self))
        readoutTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.readoutWindow.hide(); self?.readout = nil }
        readoutTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
    }

    /// The apps kept in the Dock, in Dock order; running apps if the Dock can't be read.
    static func dockApps() -> [URL] {
        let tiles = UserDefaults(suiteName: "com.apple.dock")?.array(forKey: "persistent-apps") as? [[String: Any]] ?? []
        let urls = tiles.compactMap { tile -> URL? in
            guard let data = tile["tile-data"] as? [String: Any],
                  let file = data["file-data"] as? [String: Any],
                  let string = file["_CFURLString"] as? String else { return nil }
            return URL(string: string) ?? URL(fileURLWithPath: string)
        }.filter { FileManager.default.fileExists(atPath: $0.path) }
        if !urls.isEmpty { return urls }
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.bundleURL)
            .map { $0 }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Overlay windows

/// A borderless, click-through panel that floats over every app and Space.
final class OverlayPanel {
    enum Placement { case centre, bottom }
    private let panel: NSPanel
    private let placement: Placement

    init(size: CGSize, placement: Placement) {
        self.placement = placement
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    }

    func show<V: View>(_ view: V) {
        if panel.contentView == nil || !panel.isVisible {
            panel.contentView = NSHostingView(rootView: view.frame(width: panel.frame.width, height: panel.frame.height))
        }
        if let screen = NSScreen.main?.visibleFrame {
            let size = panel.frame.size
            let origin = placement == .centre
                ? CGPoint(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2)
                : CGPoint(x: screen.midX - size.width / 2, y: screen.minY + 90)
            panel.setFrameOrigin(origin)
        }
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
        panel.contentView = nil
    }
}

// MARK: - Views

/// A slice of a ring, from `start` to `end` (radians, 0 = 3 o'clock, clockwise).
struct RingSlice: Shape {
    var inner: CGFloat
    var outer: CGFloat
    var start: Double
    var end: Double

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        var p = Path()
        p.addArc(center: c, radius: outer, startAngle: .radians(start), endAngle: .radians(end), clockwise: false)
        p.addArc(center: c, radius: inner, startAngle: .radians(end), endAngle: .radians(start), clockwise: true)
        p.closeSubpath()
        return p
    }
}

struct DialRing: View {
    /// Up to this many items the ring is fixed; beyond it, it becomes a wheel.
    static let slots = 8
    @ObservedObject var dial: Dial
    @State private var shown = Controller.snapshotMode

    private let outer: CGFloat = 150
    private let inner: CGFloat = 82
    private var mid: CGFloat { (outer + inner) / 2 }

    private func icon(_ item: Dial.Item) -> some View {
        Group {
            switch item {
            case .app(let url):
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 30, height: 30)
            case .tool(let t):
                Image(systemName: t.symbol).font(.system(size: 17, weight: .semibold))
            case .apps:
                Image(systemName: "square.grid.2x2.fill").font(.system(size: 17, weight: .semibold))
            case .playPause:
                Image(systemName: "playpause.fill").font(.system(size: 17, weight: .semibold))
            case .back:
                Image(systemName: "chevron.backward").font(.system(size: 17, weight: .bold))
            }
        }
    }

    var body: some View {
        let count = max(dial.items.count, 1)
        let wheel = count > DialRing.slots   // the apps rotate under a fixed slot at the top
        let n = wheel ? DialRing.slots : count
        let slice = 2 * Double.pi / Double(n)
        let gap = 0.035  // radians between slices
        // Item i is centred at the top, then clockwise.
        let centre = { (i: Double) in -Double.pi / 2 + i * slice }

        ZStack {
            // Frosted ring body
            Circle().fill(.ultraThinMaterial)
                .overlay(Circle().fill(Color.panel.opacity(Theme.current.dark ? 0.72 : 0.6)))
                .frame(width: outer * 2 + 16, height: outer * 2 + 16)
                .overlay(Circle().strokeBorder(Color.hairline, lineWidth: 1))
                .shadow(color: .black.opacity(Theme.current.dark ? 0.5 : 0.18), radius: 28, y: 12)

            // Knurled edge: ticks that turn with the knob
            ForEach(0..<72, id: \.self) { t in
                Capsule().fill(Ink.primary.opacity(t % 6 == 0 ? 0.28 : 0.12))
                    .frame(width: 1.2, height: t % 6 == 0 ? 7 : 4)
                    .offset(y: -(outer + 3))
                    .rotationEffect(.degrees(Double(t) * 5))
            }
            .rotationEffect(.degrees(Double(dial.spin) * 5))
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: dial.spin)

            // Slice tracks
            ForEach(0..<n, id: \.self) { i in
                RingSlice(inner: inner, outer: outer - 4, start: centre(Double(i)) - slice / 2 + gap, end: centre(Double(i)) + slice / 2 - gap)
                    .fill(Ink.primary.opacity(0.055))
            }

            // The selection wedge, spinning with the knob
            RingSlice(inner: inner, outer: outer - 4, start: -Double.pi / 2 - slice / 2 + gap, end: -Double.pi / 2 + slice / 2 - gap)
                .fill(LinearGradient(colors: [Color.accent, Color.accent.opacity(0.78)], startPoint: .top, endPoint: .bottom))
                .shadow(color: Color.accent.opacity(0.45), radius: 10)
                .rotationEffect(.radians(wheel ? 0 : Double(dial.spin) * slice))
                .animation(.spring(response: 0.32, dampingFraction: 0.78), value: dial.spin)

            // Icons on the ring
            if wheel {
                // Positions around the spin: the selected one at the top, neighbours either side.
                ForEach((dial.spin - 3)...(dial.spin + 4), id: \.self) { j in
                    let item = dial.items[((j % count) + count) % count]
                    let offset = Double(j - dial.spin)
                    let a = -Double.pi / 2 + offset * slice
                    let chosen = j == dial.spin
                    icon(item)
                        .foregroundStyle(chosen ? Color.onAccent : Ink.secondary)
                        .scaleEffect(chosen ? 1.12 : 1)
                        .opacity(abs(offset) >= 3 ? 0.35 : 1)
                        .offset(x: cos(a) * mid, y: sin(a) * mid)
                        .transition(.opacity)
                }
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: dial.spin)
            } else {
                ForEach(Array(dial.items.enumerated()), id: \.offset) { i, item in
                    let a = centre(Double(i))
                    let chosen = i == dial.index
                    icon(item)
                        .foregroundStyle(chosen ? Color.onAccent : Ink.secondary)
                        .scaleEffect(chosen ? 1.12 : 1)
                        .offset(x: cos(a) * mid, y: sin(a) * mid)
                        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: dial.index)
                }
            }

            // Centre: name and value
            Circle().fill(Color.stage.opacity(Theme.current.dark ? 0.55 : 0.08))
                .frame(width: inner * 2 - 14, height: inner * 2 - 14)
                .overlay(Circle().strokeBorder(Color.hairline, lineWidth: 1))
            if dial.showsTrack, let np = dial.nowPlaying {
                VStack(spacing: 5) {
                    HStack(spacing: 5) {
                        Image(systemName: np.playing ? "waveform" : "pause.fill").font(.system(size: 9, weight: .bold))
                        Text((np.appName.isEmpty ? "Now playing" : np.appName) + (np.playing ? "" : " · Paused"))
                            .font(Typeface.text(9.5, weight: .semibold)).tracking(1).textCase(.uppercase)
                    }
                    .foregroundStyle(Color.accent)
                    Text(np.cleanTitle).font(Typeface.display(17)).foregroundStyle(Ink.primary)
                        .multilineTextAlignment(.center).lineLimit(3).minimumScaleFactor(0.85)
                        .frame(width: inner * 2 - 38)
                    if !np.artist.isEmpty {
                        Text(np.artist).font(Typeface.text(10.5)).foregroundStyle(Ink.secondary).lineLimit(1)
                            .frame(width: inner * 2 - 44)
                    }
                    Text(dial.items[dial.index] == .playPause ? "Click to \(np.playing ? "pause" : "play")" : "Pick, then turn to skip")
                        .font(Typeface.text(9.5)).foregroundStyle(Ink.tertiary)
                        .frame(width: inner * 2 - 50)
                }
                .id("track-\(np.title)")
                .transition(.opacity)
            } else {
            VStack(spacing: 4) {
                Text(dial.items.indices.contains(dial.index) ? dial.items[dial.index].title : "")
                    .font(Typeface.display(dial.items.indices.contains(dial.index) && dial.items[dial.index].title.count > 11 ? 16 : 21))
                    .foregroundStyle(Ink.primary)
                    .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.8)
                    .frame(width: inner * 2 - 34)
                if let note = dial.note {
                    Text(note).font(Typeface.text(10)).foregroundStyle(Color.accent)
                        .multilineTextAlignment(.center).frame(width: inner * 2 - 30)
                } else if let detail = dial.detail {
                    Text(detail).font(Typeface.text(11, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(Color.accent)
                }
            }
            .id(dial.index)
            .transition(.opacity)
            .animation(.easeOut(duration: 0.15), value: dial.index)
            }
        }
        .scaleEffect(shown ? 1 : 0.86)
        .opacity(shown ? 1 : 0)
        .onAppear { withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) { shown = true } }
        .preferredColorScheme(Theme.current.dark ? .dark : .light)
    }
}

/// While turning with the ring closed: a compact capsule with a circular gauge.
struct DialReadout: View {
    @ObservedObject var dial: Dial

    var body: some View {
        if let r = dial.readout {
            HStack(spacing: 14) {
                ZStack {
                    Circle().stroke(Ink.primary.opacity(0.12), lineWidth: 3)
                    if let level = r.level {
                        Circle().trim(from: 0, to: level)
                            .stroke(Color.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: level)
                    }
                    Image(systemName: r.tool.symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.accent)
                }
                .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text(r.tool.title).font(Typeface.text(10.5, weight: .semibold)).tracking(1).textCase(.uppercase)
                        .foregroundStyle(Ink.tertiary)
                    Text(r.text).font(Typeface.display(r.text.count > 18 ? 15 : 19)).monospacedDigit().foregroundStyle(Ink.primary).lineLimit(1)
                        .truncationMode(.tail)
                        .contentTransition(.numericText())
                        .animation(.easeOut(duration: 0.2), value: r.text)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 12).padding(.trailing, 22)
            .frame(width: 270, height: 62)
            .background(Capsule().fill(.ultraThinMaterial))
            .background(Capsule().fill(Color.panel.opacity(0.7)))
            .overlay(Capsule().strokeBorder(Color.hairline))
            .shadow(color: .black.opacity(Theme.current.dark ? 0.4 : 0.15), radius: 18, y: 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .preferredColorScheme(Theme.current.dark ? .dark : .light)
        }
    }
}
