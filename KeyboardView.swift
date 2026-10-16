// The live drawing of the F75 and the stage it sits on.
//
// The keyboard's own light is the product, so it is the only thing on screen that glows.
// Everything around it stays quiet: graphite, hairlines, one champagne accent.

import AppKit
import SwiftUI

/// Fine film grain so the dark surfaces don't look flat.
enum Grain {
    static let image: NSImage = {
        let side = 192
        var pixels = [UInt8](repeating: 255, count: side * side * 4)
        for i in 0..<(side * side) {
            let v = UInt8.random(in: 0...255)
            pixels[i * 4] = v; pixels[i * 4 + 1] = v; pixels[i * 4 + 2] = v
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let cg = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                         provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        return NSImage(cgImage: cg, size: NSSize(width: side, height: side))
    }()
}

func average(_ colors: [RGBf]) -> RGBf {
    var sum: RGBf = (0, 0, 0)
    for k in Layout.keys {
        let c = colors[k.led]
        sum.0 += c.0; sum.1 += c.1; sum.2 += c.2
    }
    let n = Double(Layout.keys.count)
    return (sum.0 / n, sum.1 / n, sum.2 / n)
}

// MARK: - Keyboard

struct KeyboardView: View {
    @ObservedObject var c: Controller
    let unit: CGFloat
    let colors: [RGBf]
    let now: Double
    var hovered: Int? = nil
    var reflection = false

    static let pad = 0.55  // case border, in key units
    static let depth = 0.16  // visible front edge of the case
    static func size(unit u: CGFloat) -> CGSize {
        CGSize(width: (Layout.width + 2 * pad) * u, height: (Layout.height + 2 * pad + depth) * u)
    }

    static func keyRect(_ k: KeyPos, unit u: CGFloat) -> CGRect {
        CGRect(x: (pad + k.x - k.w / 2) * u, y: (pad + k.y) * u, width: k.w * u, height: u)
    }

    var body: some View {
        Canvas { ctx, size in draw(&ctx, size: size) }
            .frame(width: KeyboardView.size(unit: unit).width, height: KeyboardView.size(unit: unit).height)
    }

    // MARK: Styling

    private func capStyle(_ name: String) -> (side: Color, top: Color, legend: Color) {
        switch name {
        case "Esc", "Enter", "Space", "Up", "Down", "Left", "Right":
            (Color(hex: 0xA97C1C), Color(hex: 0xE6B64C), Color(hex: 0x1A1C22))
        case "Tab", "Caps", "LShift", "RShift", "LCtrl", "LWin", "LAlt", "Fn", "RCtrl", "Backspace", "Del", "PgUp", "PgDn", "End":
            (Color(hex: 0x111216), Color(hex: 0x272930), .keycapLegend)
        default:
            (Color(hex: 0x131828), Color(hex: 0x29324A), .keycapLegend)
        }
    }

    /// (main legend, shifted legend above it, is it a word-style modifier label)
    private func legend(_ name: String) -> (String, String?, Bool) {
        let shifted: [String: String] = [
            "`": "~", "1": "!", "2": "@", "3": "#", "4": "$", "5": "%", "6": "^", "7": "&", "8": "*", "9": "(",
            "0": ")", "-": "_", "=": "+", "[": "{", "]": "}", "\\": "|", ";": ":", "'": "\"", ",": "<", ".": ">", "/": "?",
        ]
        if let top = shifted[name] { return (name, top, false) }
        switch name {
        case "Backspace": return ("Backspace", nil, true)
        case "Del": return ("Delete", nil, true)
        case "Caps": return ("Caps Lock", nil, true)
        case "Enter": return ("Enter", nil, true)
        case "LShift", "RShift": return ("Shift", nil, true)
        case "LCtrl", "RCtrl": return ("Ctrl", nil, true)
        case "Tab": return ("Tab", nil, true)
        case "LWin": return (c.macLayout ? "option" : "Win", c.macLayout ? "⌥" : nil, true)
        case "LAlt": return (c.macLayout ? "command" : "Alt", c.macLayout ? "⌘" : nil, true)
        case "PgUp", "PgDn", "End", "Esc", "Fn": return (name, nil, true)
        case "Space": return ("", nil, false)
        case "Up": return ("↑", nil, false)
        case "Down": return ("↓", nil, false)
        case "Left": return ("←", nil, false)
        case "Right": return ("→", nil, false)
        default: return (name, nil, false)
        }
    }

    // MARK: Drawing

    private func draw(_ ctx: inout GraphicsContext, size: CGSize) {
        let u = unit
        let p = KeyboardView.pad
        let full = CGRect(origin: .zero, size: size)
        let top = CGRect(x: 0, y: 0, width: size.width, height: size.height - KeyboardView.depth * u).insetBy(dx: 1, dy: 1)

        // Case: front edge (thickness), then the top face lit from above, then the plate.
        ctx.fill(Path(roundedRect: full.insetBy(dx: 1, dy: 1), cornerRadius: u * 0.5), with: .color(Color(hex: 0x08090C)))
        ctx.fill(Path(roundedRect: top, cornerRadius: u * 0.48),
                 with: .linearGradient(Gradient(colors: [Color(hex: 0x30323A), Color(hex: 0x17181D)]),
                                       startPoint: .zero, endPoint: CGPoint(x: 0, y: top.height)))
        ctx.stroke(Path(roundedRect: top.insetBy(dx: 0.5, dy: 0.5), cornerRadius: u * 0.48),
                   with: .linearGradient(Gradient(colors: [.white.opacity(0.16), .white.opacity(0.02)]),
                                         startPoint: .zero, endPoint: CGPoint(x: 0, y: top.height)), lineWidth: 1)
        let plate = CGRect(x: (p - 0.22) * u, y: (p - 0.22) * u, width: (Layout.width + 0.44) * u, height: (Layout.height + 0.44) * u)
        ctx.fill(Path(roundedRect: plate, cornerRadius: u * 0.22), with: .color(Color(hex: 0x07080A)))

        let strength = { (k: KeyPos) -> Double in let c = colors[k.led]; return max(c.0, c.1, c.2) }
        let lit = { (k: KeyPos) -> Color in let c = colors[k.led]; return Color(red: c.0, green: c.1, blue: c.2) }

        // Light spilling from under the caps onto the plate: wide and soft, then tight.
        ctx.drawLayer { layer in
            layer.addFilter(.blur(radius: u * 0.38))
            for k in Layout.keys where strength(k) > 0.01 {
                layer.fill(Path(roundedRect: KeyboardView.keyRect(k, unit: u).insetBy(dx: -u * 0.04, dy: -u * 0.04), cornerRadius: u * 0.2),
                           with: .color(lit(k).opacity(min(1, 0.22 + 0.85 * strength(k)))))
            }
        }
        ctx.drawLayer { layer in
            layer.addFilter(.blur(radius: u * 0.09))
            for k in Layout.keys where strength(k) > 0.01 {
                layer.fill(Path(roundedRect: KeyboardView.keyRect(k, unit: u).insetBy(dx: u * 0.03, dy: u * 0.03), cornerRadius: u * 0.14),
                           with: .color(lit(k)))
            }
        }

        // Keycaps
        for k in Layout.keys {
            let press = c.pressAmount(k.led, now: now)
            let hover = hovered == k.led && !reflection
            let style = capStyle(k.name)
            let sink = u * 0.05 * press
            let r = KeyboardView.keyRect(k, unit: u).insetBy(dx: u * 0.075, dy: u * 0.075).offsetBy(dx: 0, dy: sink)
            ctx.fill(Path(roundedRect: r, cornerRadius: u * 0.13), with: .color(style.side))
            let face = CGRect(x: r.minX + u * 0.09, y: r.minY + u * 0.035, width: r.width - u * 0.18,
                              height: r.height - u * (0.2 - 0.06 * press))
            ctx.fill(Path(roundedRect: face, cornerRadius: u * 0.1),
                     with: .linearGradient(Gradient(colors: [style.top.opacity(hover ? 1 : 0.94), style.top.opacity(0.72)]),
                                           startPoint: CGPoint(x: face.midX, y: face.minY), endPoint: CGPoint(x: face.midX, y: face.maxY)))
            // Inner top highlight: a 1px rim instead of an outer glow.
            ctx.stroke(Path(roundedRect: face.insetBy(dx: 0.5, dy: 0.5), cornerRadius: u * 0.1),
                       with: .linearGradient(Gradient(colors: [.white.opacity(hover ? 0.22 : 0.1), .clear]),
                                             startPoint: CGPoint(x: face.midX, y: face.minY), endPoint: CGPoint(x: face.midX, y: face.midY)),
                       lineWidth: 1)
            if strength(k) > 0.02 {  // the cap's skirt catches its own light
                ctx.stroke(Path(roundedRect: r, cornerRadius: u * 0.13), with: .color(lit(k).opacity(0.5)), lineWidth: max(1, u * 0.024))
            }
            if press > 0.05 {  // the light flares briefly where you press
                ctx.fill(Path(roundedRect: face, cornerRadius: u * 0.1), with: .color(.white.opacity(0.1 * press)))
            }

            let (main, upper, word) = legend(k.name)
            if main.isEmpty { continue }
            let font = { (s: CGFloat, w: Font.Weight) in Typeface.text(u * s * 0.95, weight: w) }
            if let upper, !word {
                ctx.draw(Text(upper).font(font(0.17, .semibold)).foregroundColor(style.legend.opacity(0.75)),
                         at: CGPoint(x: face.minX + u * 0.13, y: face.minY + u * 0.07), anchor: .topLeading)
                ctx.draw(Text(main).font(font(0.2, .bold)).foregroundColor(style.legend),
                         at: CGPoint(x: face.minX + u * 0.13, y: face.maxY - u * 0.06), anchor: .bottomLeading)
            } else if word {
                if let upper {
                    ctx.draw(Text(upper).font(font(0.2, .semibold)).foregroundColor(style.legend),
                             at: CGPoint(x: face.maxX - u * 0.1, y: face.minY + u * 0.06), anchor: .topTrailing)
                }
                ctx.draw(Text(main).font(font(0.135, .semibold)).foregroundColor(style.legend),
                         at: CGPoint(x: face.minX + u * 0.11, y: face.maxY - u * 0.07), anchor: .bottomLeading)
            } else {
                ctx.draw(Text(main).font(font(0.25, .bold)).foregroundColor(style.legend),
                         at: CGPoint(x: face.minX + u * 0.13, y: face.minY + u * 0.07), anchor: .topLeading)
            }
        }

        drawKnob(&ctx, unit: u)

        // Status light between Esc and F1, tinted with the board's light.
        let avg = average(colors)
        let light = CGRect(x: (p + 1.43) * u, y: (p + 0.22) * u, width: u * 0.07, height: u * 0.56)
        let lightColor = c.connected ? Color(red: min(1, avg.0 * 4), green: min(1, avg.1 * 4), blue: min(1, avg.2 * 4)) : Color.white.opacity(0.15)
        ctx.fill(Path(roundedRect: light, cornerRadius: u * 0.035), with: .color(lightColor))
    }

    /// The board's light at a point along the home row, brightened to full strength,
    /// so the knob ring shows the same colours as the keys.
    private func lightAlongBoard(_ f: Double) -> (color: Color, level: Double)? {
        let x = 0.5 + f * (Layout.width - 1)
        guard let key = Layout.keys.filter({ abs($0.y - Layout.rowY(3)) < 0.1 }).min(by: { abs($0.x - x) < abs($1.x - x) }) else { return nil }
        let c = colors[key.led]
        let m = max(c.0, c.1, c.2)
        guard m > 0.015 else { return nil }
        return (Color(red: c.0 / m, green: c.1 / m, blue: c.2 / m), m)
    }

    private func drawKnob(_ ctx: inout GraphicsContext, unit u: CGFloat) {
        let p = KeyboardView.pad
        let centre = CGPoint(x: (p + Layout.knob.x) * u, y: (p + Layout.knob.y + 0.5) * u)
        let radius = u * 0.46
        let angle = c.knobAngle * .pi / 180
        let activity = c.knobActivity(now: now)

        // Ring of ticks in the board's own colours. It's always faintly lit with the keys;
        // turning the knob brightens it and fills it to the Mac's volume.
        let ticks = 30
        let filled = c.muted ? 0 : Int(((c.volume ?? 0) * Double(ticks)).rounded())
        for i in 0..<ticks {
            let f = Double(i) / Double(ticks - 1)
            let a = -.pi * 0.75 + f * .pi * 1.5 - .pi / 2
            let inner = radius * 1.2, outer = radius * 1.42
            var tick = Path()
            tick.move(to: CGPoint(x: centre.x + cos(a) * inner, y: centre.y + sin(a) * inner))
            tick.addLine(to: CGPoint(x: centre.x + cos(a) * outer, y: centre.y + sin(a) * outer))
            let light = lightAlongBoard(f)
            let base = light?.color ?? .accent
            let on = i < filled
            let idle = (light.map { 0.15 + 0.5 * min(1, $0.level * 2) } ?? 0.08) * (on ? 1 : 0.35)
            let busy = on ? 1.0 : 0.16
            let alpha = idle + (busy - idle) * activity
            ctx.stroke(tick, with: .color(base.opacity(alpha)), style: StrokeStyle(lineWidth: max(1.5, u * 0.045), lineCap: .round))
        }

        // Body, lit from the top left
        let knob = Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2))
        ctx.fill(knob, with: .radialGradient(Gradient(colors: [Color(hex: 0x50535D), Color(hex: 0x17181C)]),
                                            center: CGPoint(x: centre.x - radius * 0.35, y: centre.y - radius * 0.4),
                                            startRadius: 0, endRadius: radius * 1.5))
        // Knurled edge that turns with the real knob
        for i in 0..<40 {
            let a = angle + Double(i) / 40 * 2 * .pi
            var line = Path()
            line.move(to: CGPoint(x: centre.x + cos(a) * radius * 0.84, y: centre.y + sin(a) * radius * 0.84))
            line.addLine(to: CGPoint(x: centre.x + cos(a) * radius * 0.98, y: centre.y + sin(a) * radius * 0.98))
            ctx.stroke(line, with: .color(.black.opacity(0.45)), lineWidth: 1)
        }
        ctx.stroke(knob, with: .linearGradient(Gradient(colors: [.white.opacity(0.28), .white.opacity(0.03)]),
                                               startPoint: CGPoint(x: centre.x, y: centre.y - radius),
                                               endPoint: CGPoint(x: centre.x, y: centre.y + radius)), lineWidth: 1)
        // Indicator notch, in the board's average colour
        let avg = average(colors)
        let m = max(avg.0, avg.1, avg.2)
        let notchColor = c.muted ? Color.white.opacity(0.3) : (m > 0.01 ? Color(red: avg.0 / m, green: avg.1 / m, blue: avg.2 / m) : .accent)
        let a = angle - .pi / 2
        var notch = Path()
        notch.move(to: CGPoint(x: centre.x + cos(a) * radius * 0.42, y: centre.y + sin(a) * radius * 0.42))
        notch.addLine(to: CGPoint(x: centre.x + cos(a) * radius * 0.72, y: centre.y + sin(a) * radius * 0.72))
        ctx.stroke(notch, with: .color(notchColor), style: StrokeStyle(lineWidth: max(1.5, u * 0.05), lineCap: .round))
    }
}

// MARK: - Stage

/// The keyboard on a quiet graphite stage, tilted a few degrees like a product shot.
/// Its light falls softly on the surface below. Click keys to play.
struct KeyboardStage: View {
    @ObservedObject var c: Controller
    let topInset: CGFloat
    let bottomInset: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered: Int?
    @State private var lean = CGSize.zero
    @State private var pointer: CGPoint?
    @State private var appeared = Controller.snapshotMode

    var body: some View {
        GeometryReader { geo in
            let usableH = geo.size.height - topInset - bottomInset
            let u = min((geo.size.width * 0.66) / (Layout.width + 2 * KeyboardView.pad),
                        usableH / (Layout.height + 2 * KeyboardView.pad + KeyboardView.depth))
            let size = KeyboardView.size(unit: u)
            let centreX = geo.size.width * 0.5
            let centreY = topInset + usableH / 2

            TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
                let now = LiveEngine.now
                let colors = c.displayColors(at: now)
                let avg = average(colors)
                let m = max(avg.0, avg.1, avg.2)
                let glow = m > 0.004 ? Color(red: avg.0 / m, green: avg.1 / m, blue: avg.2 / m) : Color.accent
                let level = min(1, m * 3)
                let _ = c.stepKnob(reduceMotion: reduceMotion)

                ZStack {
                    // Light falling on the surface below, and a faint wash behind.
                    Ellipse().fill(glow).frame(width: size.width * 1.3, height: size.height * 1.2)
                        .blur(radius: 170).opacity(0.12 * level)
                        .position(x: centreX, y: centreY)
                    Ellipse().fill(glow).frame(width: size.width * 0.9, height: size.height * 0.22)
                        .blur(radius: 42).opacity(0.38 * level)
                        .position(x: centreX, y: centreY + size.height * 0.52)

                    KeyboardView(c: c, unit: u, colors: colors, now: now, hovered: hovered)
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            if case .active(let point) = phase {
                                hovered = Layout.keys.first { KeyboardView.keyRect($0, unit: u).contains(point) }?.led
                            } else { hovered = nil }
                        }
                        .onTapGesture(coordinateSpace: .local) { point in
                            guard let key = Layout.keys.first(where: { KeyboardView.keyRect($0, unit: u).contains(point) }) else { return }
                            c.tapKey(key)
                        }
                        .rotation3DEffect(.degrees(9 - (reduceMotion ? 0 : lean.height * 1.5)), axis: (x: 1, y: 0, z: 0),
                                          anchor: .center, perspective: 0.35)
                        .rotation3DEffect(.degrees(reduceMotion ? 0 : lean.width * 2), axis: (x: 0, y: 1, z: 0),
                                          anchor: .center, perspective: 0.35)
                        .shadow(color: .black.opacity(Theme.current.shadow), radius: 34, y: 26)
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 12)
                        .saturation(c.connected || c.mode != .effects ? 1 : 0.15)
                        .position(x: centreX, y: centreY)

                    GameOverlay(c: c).position(x: centreX, y: centreY)
                }
                .background {
                    // a faint pool of light that follows the cursor
                    if let pointer, !reduceMotion, c.ambient {
                        RadialGradient(colors: [Ink.primary.opacity(0.045), .clear], center: .center, startRadius: 0, endRadius: 320)
                            .frame(width: 640, height: 640)
                            .position(pointer)
                            .allowsHitTesting(false)
                    }
                }
            }
            .onContinuousHover { phase in
                guard !reduceMotion else { return }
                var target = CGSize.zero
                if case .active(let p) = phase {
                    target = CGSize(width: (p.x / geo.size.width - 0.5) * 2, height: (p.y / geo.size.height - 0.5) * 2)
                    pointer = p
                } else { pointer = nil }
                withAnimation(.easeOut(duration: 1.2)) { lean = target }
            }
        }
        .background(
            ZStack {
                Color.stage
                RadialGradient(colors: [Color.stageLift, .clear], center: UnitPoint(x: 0.5, y: 0.45), startRadius: 0, endRadius: 760)
                Image(nsImage: Grain.image).resizable(resizingMode: .tile).opacity(0.03).blendMode(.overlay)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        )
        .onAppear {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 1.1).delay(0.1)) { appeared = true }
        }
    }
}

/// Slim bar across the top: wordmark, the four modes, connection and layout.
struct TopBar: View {
    @ObservedObject var c: Controller

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Aula").font(Typeface.display(21, italic: true)).foregroundStyle(Ink.primary)
                Text("F75").font(Typeface.text(10.5, weight: .semibold)).tracking(2.4).foregroundStyle(Ink.tertiary)
            }
            .frame(width: 330, alignment: .leading)

            Spacer()
            TextTabs(options: Mode.allCases.map { ($0, $0.short) },
                     selection: Binding(get: { c.mode }, set: { c.setMode($0) }))
            Spacer()

            HStack(spacing: 22) {
                HStack(spacing: 7) {
                    Circle().fill(c.connected ? Color.accent : (c.needsPermission ? Color(hex: 0xD9774A) : Ink.tertiary)).frame(width: 5, height: 5)
                    Text(c.connected ? "Connected" : (c.needsPermission ? "Needs access" : "Not connected"))
                        .font(Typeface.text(12)).foregroundStyle(Ink.secondary)
                }
                .help(c.status)
                TextTabs(options: [(true, "Mac"), (false, "Windows")],
                         selection: Binding(get: { c.macLayout }, set: { c.setLayout(mac: $0) }), size: 12)
                    .help(c.macLayout ? "Alt acts as Command and Win as Option" : "Keys work as printed")
                Button { c.setDial(!c.dialEnabled) } label: {
                    Image(systemName: "dial.medium").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(c.dialEnabled ? Color.onAccent : Ink.secondary)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(c.dialEnabled ? Color.accent : .clear))
                        .overlay(Circle().strokeBorder(Color.hairline.opacity(2)))
                }
                .buttonStyle(.plain)
                .help(c.dialEnabled ? "Knob: dial menu (click the knob to open it). Click here for plain volume." : "Use the knob as a dial menu")
                Button { withAnimation(.easeOut(duration: 0.25)) { c.showTheme.toggle(); c.showShortcuts = false } } label: {
                    Circle().fill(Color.accent).frame(width: 10, height: 10)
                        .frame(width: 22, height: 22)
                        .overlay(Circle().strokeBorder(Color.hairline.opacity(2)))
                }
                .buttonStyle(.plain).help("Theme")
                Button { withAnimation(.easeOut(duration: 0.25)) { c.showShortcuts.toggle(); c.showTheme = false } } label: {
                    Text("?").font(Typeface.text(12, weight: .semibold)).foregroundStyle(Ink.secondary)
                        .frame(width: 22, height: 22)
                        .overlay(Circle().strokeBorder(Color.hairline.opacity(2)))
                }
                .buttonStyle(.plain).help("Keyboard shortcuts")
            }
            .frame(width: 330, alignment: .trailing)
        }
        .padding(.leading, MainView.margin + 6).padding(.trailing, MainView.margin)  // clear of the window buttons
        .frame(height: 64)
    }
}

/// The mode's title and a line about it, set like an editorial headline.
struct TitleBlock: View {
    @ObservedObject var c: Controller

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(String(format: "%02d", c.mode.rawValue + 1) + "  /  04")
                .font(Typeface.text(10.5, weight: .semibold)).tracking(2).foregroundStyle(Ink.tertiary)
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(c.mode.headline.0).font(Typeface.display(52))
                Text(c.mode.headline.1).font(Typeface.display(52, italic: true)).foregroundStyle(Color.accent)
            }
            .foregroundStyle(Ink.primary)
            .tracking(-0.8)
            Text(c.mode.tagline)
                .font(Typeface.text(14)).lineSpacing(4).foregroundStyle(Ink.secondary)
                .frame(maxWidth: 360, alignment: .leading)
            if c.mode == .effects && c.connected {
                MoodsRow(c: c).padding(.top, 6)
            } else if !c.connected && c.mode == .effects {
                HStack(spacing: 14) {
                    Text("Lighting control needs the USB-C cable.").font(Typeface.text(12)).foregroundStyle(Ink.tertiary)
                    TextAction("Try again") { c.refresh() }
                }
                .padding(.top, 4)
            }
        }
        .id(c.mode)
        .transition(.opacity.combined(with: .offset(y: 6)))
        .animation(.easeOut(duration: 0.45), value: c.mode)
    }
}

/// One-click looks. Hover to preview on the drawing, click to put it on the keyboard.
struct MoodsRow: View {
    @ObservedObject var c: Controller
    @State private var hovered: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            Text("Moods").label()
            ForEach(Mood.all) { mood in
                Button { c.applyMood(mood) } label: {
                    Text(mood.name).font(Typeface.display(15, italic: true))
                        .foregroundStyle(hovered == mood.name ? Color.accent : Ink.secondary)
                }
                .buttonStyle(.plain)
                .onHover { inside in
                    hovered = inside ? mood.name : (hovered == mood.name ? nil : hovered)
                    c.previewState = Mood.all.first { $0.name == hovered }?.state
                }
            }
        }
        .animation(.easeOut(duration: 0.15), value: hovered)
    }
}

/// One or two quiet numbers on the right: typing speed, the game, or the volume.
struct StatsBlock: View {
    @ObservedObject var c: Controller

    var body: some View {
        VStack(alignment: .trailing, spacing: 26) {
            if c.mode == .game {
                stat("\(c.game.score)", "Score")
                stat("\(c.game.timeLeft)", "Seconds", highlight: c.game.timeLeft <= 5 && c.game.phase == .playing)
            } else {
                stat("\(c.wpm)", "Words a minute")
                if c.mode == .heatmap, let hot = c.heatScene.hottest() {
                    stat(hot.name.count <= 2 ? hot.name : hot.name.replacingOccurrences(of: "L", with: "").replacingOccurrences(of: "R", with: ""),
                         "Most used")
                }
            }
            if c.knobRecentlyTurned {
                stat(c.muted ? "Off" : "\(Int(((c.volume ?? 0) * 100).rounded()))", c.muted ? "Muted" : "Volume", highlight: true)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.35), value: c.knobRecentlyTurned)
    }

    private func stat(_ value: String, _ label: String, highlight: Bool = false) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(value).font(Typeface.display(44)).monospacedDigit()
                .foregroundStyle(highlight ? Color.accent : Ink.primary)
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.25), value: value)
            Text(label).label()
        }
    }
}

/// The countdown and the end-of-round card, over the keyboard.
struct GameOverlay: View {
    @ObservedObject var c: Controller

    var body: some View {
        Group {
            if c.mode == .game {
                switch c.game.phase {
                case .countdown(let n):
                    Text("\(n)")
                        .font(Typeface.display(170, italic: true))
                        .foregroundStyle(Ink.primary)
                        .shadow(color: .black.opacity(0.6), radius: 20)
                        .id(n)
                        .transition(.opacity.combined(with: .scale(scale: 1.08)))
                case .over:
                    VStack(spacing: 10) {
                        Text(c.game.newBest ? "A new best" : "Time").label()
                        Text("\(c.game.score)").font(Typeface.display(88)).foregroundStyle(Ink.primary).monospacedDigit()
                        Text("\(c.game.hits) hits, \(c.game.misses) misses. Best \(c.game.best).")
                            .font(Typeface.text(13)).foregroundStyle(Ink.secondary)
                    }
                    .padding(.horizontal, 52).padding(.vertical, 34)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.stage.opacity(0.88)))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.hairline))
                    .transition(.opacity)
                default:
                    EmptyView()
                }
            }
        }
        .animation(.easeOut(duration: 0.35), value: c.game.phase)
        .allowsHitTesting(false)
    }
}
