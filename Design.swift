// Design system: type, colour and the custom controls.
//
// Direction: quiet, editorial and premium. Playfair Display for display type and big
// numbers, Open Sans for everything else. Dark graphite or warm paper, one accent the
// user picks. Hairlines instead of boxes; controls drawn by hand rather than stock widgets.

import AppKit
import CoreText
import SwiftUI

// MARK: - Type

enum Typeface {
    /// Registers the bundled fonts (in the app's Resources, or next to the sources in dev builds).
    static func register() {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("Fonts"),
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fonts"),
        ].compactMap { $0 }
        guard let dir = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "ttf" {
            CTFontManagerRegisterFontsForURL(file as CFURL, .process, nil)
        }
    }

    static func display(_ size: CGFloat, italic: Bool = false, weight: Font.Weight = .regular) -> Font {
        .custom(italic ? "PlayfairDisplay-Italic" : "PlayfairDisplay-Regular", size: size).weight(weight)
    }

    static func text(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom("OpenSans-Regular", size: size).weight(weight)
    }
}

extension View {
    /// Small spaced-out label, the quiet way to title a group of controls.
    func label() -> some View {
        font(Typeface.text(10.5, weight: .semibold)).tracking(1.6).textCase(.uppercase).foregroundStyle(Ink.tertiary)
    }
}

// MARK: - Theme

enum Appearance: String, CaseIterable, Identifiable {
    case dark, light, auto
    var id: String { rawValue }
    var title: String { switch self { case .dark: "Dark"; case .light: "Light"; case .auto: "Auto" } }
}

enum Accent: String, CaseIterable, Identifiable {
    case champagne, keycap, sage, coral, arc, mono
    var id: String { rawValue }

    var title: String {
        switch self {
        case .champagne: "Champagne"
        case .keycap: "Keycap"
        case .sage: "Sage"
        case .coral: "Coral"
        case .arc: "Arc blue"
        case .mono: "Mono"
        }
    }

    /// Each accent has a lighter tone for dark backgrounds and a deeper one for light,
    /// so it keeps its contrast either way.
    func color(dark: Bool) -> Color {
        switch self {
        case .champagne: Color(hex: dark ? 0xCFAE6E : 0x9C7A36)
        case .keycap: Color(hex: dark ? 0xE6B64C : 0xA87A12)
        case .sage: Color(hex: dark ? 0x9DB58C : 0x56704A)
        case .coral: Color(hex: dark ? 0xE58A6E : 0xB4503A)
        case .arc: Color(hex: dark ? 0x6CB6FF : 0x1F6FC4)
        case .mono: Color(hex: dark ? 0xEDE7DC : 0x2A2826)
        }
    }
}

/// The colours the whole window draws from. Changing it redraws the window.
struct Theme: Hashable {
    var dark: Bool
    var accentChoice: Accent

    var accent: Color { accentChoice.color(dark: dark) }
    var onAccent: Color { dark ? Color(hex: 0x0C0C0D) : Color(hex: 0xFBF9F5) }  // text on a filled accent
    var stage: Color { Color(hex: dark ? 0x0C0C0D : 0xEFECE6) }                 // warm graphite, or warm paper
    var stageLift: Color { Color(hex: dark ? 0x1C1B1D : 0xFAF8F4) }             // soft light behind the board
    var panel: Color { Color(hex: dark ? 0x141415 : 0xFBF9F5) }
    var ink: Color { Color(hex: dark ? 0xF4EFE6 : 0x1D1B18) }
    var hairline: Color { ink.opacity(dark ? 0.08 : 0.1) }
    var shadow: Double { dark ? 0.7 : 0.32 }                                    // how hard the board's shadow falls

    /// Read while drawing. Set once per render at the top of the window (see MainView).
    static var current = Theme(dark: true, accentChoice: .champagne)
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
    static var accent: Color { Theme.current.accent }
    static var onAccent: Color { Theme.current.onAccent }
    static var stage: Color { Theme.current.stage }
    static var stageLift: Color { Theme.current.stageLift }
    static var panel: Color { Theme.current.panel }
    static var hairline: Color { Theme.current.hairline }
    /// The physical keycap legend colour; the drawing keeps it whatever the theme.
    static let keycapLegend = Color(hex: 0xE6B64C)
}

enum Ink {
    static var primary: Color { Theme.current.ink }
    static var secondary: Color { Theme.current.ink.opacity(0.58) }
    static var tertiary: Color { Theme.current.ink.opacity(Theme.current.dark ? 0.36 : 0.45) }
}

// MARK: - Controls

/// A hairline slider: thin track, champagne fill, small warm-white thumb.
struct LineSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double? = nil
    let format: (Double) -> String
    @State private var dragging = false
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(Typeface.text(12)).foregroundStyle(Ink.secondary)
                Spacer()
                Text(format(value)).font(Typeface.text(12, weight: .semibold)).monospacedDigit().foregroundStyle(Ink.primary)
            }
            GeometryReader { geo in
                let f = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
                let x = geo.size.width * f
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.hairline.opacity(1.6)).frame(height: 1)
                    Capsule().fill(Color.accent).frame(width: max(0, x), height: 1.5)
                    Circle().fill(Ink.primary)
                        .frame(width: dragging ? 13 : (hovering ? 12 : 10), height: dragging ? 13 : (hovering ? 12 : 10))
                        .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                        .offset(x: x - (dragging ? 6.5 : 5))
                }
                .frame(height: 16)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        dragging = true
                        var v = range.lowerBound + (range.upperBound - range.lowerBound) * min(max(g.location.x / geo.size.width, 0), 1)
                        if let step { v = (v / step).rounded() * step }
                        if v != value { value = v }
                    }
                    .onEnded { _ in dragging = false })
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.15), value: dragging)
                .animation(.easeOut(duration: 0.15), value: hovering)
            }
            .frame(height: 16)
        }
        .accessibilityElement()
        .accessibilityLabel(title)
        .accessibilityValue(format(value))
        .accessibilityAdjustableAction { direction in
            let delta = step ?? (range.upperBound - range.lowerBound) / 20
            value = min(max(value + (direction == .increment ? delta : -delta), range.lowerBound), range.upperBound)
        }
    }
}

/// A small switch with a text label.
struct MiniSwitch: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 10) {
                Text(title).font(Typeface.text(12)).foregroundStyle(isOn ? Ink.primary : Ink.secondary)
                ZStack(alignment: isOn ? .trailing : .leading) {
                    Capsule().fill(isOn ? Color.accent : Color.hairline.opacity(2)).frame(width: 28, height: 16)
                    Circle().fill(isOn ? Color.onAccent : Ink.secondary).frame(width: 12, height: 12).padding(2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isOn)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

/// Text options with a thin champagne underline that slides to the selection.
struct TextTabs<T: Hashable>: View {
    let options: [(T, String)]
    @Binding var selection: T
    var size: CGFloat = 13
    @Namespace private var underline

    var body: some View {
        HStack(spacing: size * 2) {
            ForEach(options, id: \.0) { value, title in
                Button { selection = value } label: {
                    VStack(spacing: 7) {
                        Text(title).font(Typeface.text(size, weight: selection == value ? .semibold : .regular))
                            .foregroundStyle(selection == value ? Ink.primary : Ink.tertiary)
                        ZStack {
                            Color.clear.frame(height: 1)
                            if selection == value {
                                Rectangle().fill(Color.accent).frame(height: 1)
                                    .matchedGeometryEffect(id: "underline", in: underline)
                            }
                        }
                    }
                    .fixedSize()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: selection)
    }
}

/// A plain text action that underlines on hover.
struct TextAction: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title).font(Typeface.text(12, weight: .semibold))
                .foregroundStyle(hovering ? Ink.primary : Ink.secondary)
                .underline(hovering, color: .accent)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// The one filled button, kept for the single most important action on a screen.
struct PrimaryButton: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title).font(Typeface.text(13, weight: .semibold)).tracking(0.4)
                .foregroundStyle(Color.onAccent)
                .padding(.horizontal, 28).frame(height: 40)
                .background(Capsule().fill(hovering ? Ink.primary : Color.accent))
        }
        .buttonStyle(PressStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.2), value: hovering)
    }
}

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .offset(y: configuration.isPressed ? 1 : 0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Colour dots, plus a spectrum dot that opens the system colour picker.
struct Swatches: View {
    @Binding var color: RGB
    @Binding var rainbow: Bool

    /// Quick dots: colours that look the same on the keys as on screen.
    static let presets: [(String, RGB)] = [
        ("White", RGB(r: 255, g: 255, b: 255)), ("Amber", RGB(r: 255, g: 144, b: 0)),
        ("Red", RGB(r: 255, g: 0, b: 0)), ("Magenta", RGB(r: 255, g: 0, b: 192)),
        ("Violet", RGB(r: 128, g: 0, b: 255)), ("Blue", RGB(r: 0, g: 64, b: 255)),
        ("Mint", RGB(r: 0, g: 255, b: 144)),
    ]

    @State private var showPicker = false

    /// The current colour isn't one of the dots: the spectrum dot shows as selected.
    private var isCustom: Bool { !rainbow && !Swatches.presets.contains { $0.1 == color } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 9) {
                ForEach(Swatches.presets, id: \.0) { name, rgb in
                    let chosen = color == rgb && !rainbow
                    Button { color = rgb; rainbow = false } label: {
                        Circle().fill(rgb.color).frame(width: 16, height: 16)
                            .padding(3)
                            .overlay(Circle().strokeBorder(chosen ? Ink.primary : .clear, lineWidth: 1))
                            .overlay(Circle().strokeBorder(Ink.primary.opacity(0.15), lineWidth: 0.5).padding(3))  // keeps pale dots visible on paper
                    }
                    .buttonStyle(PressStyle()).help(name).accessibilityLabel(name)
                }
                // Spectrum dot: opens the in-app picker right below it.
                Button { showPicker.toggle() } label: {
                    Circle().fill(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center))
                        .frame(width: 16, height: 16).padding(3)
                        .overlay(Circle().strokeBorder(showPicker || isCustom ? Ink.primary : .clear, lineWidth: 1))
                }
                .buttonStyle(PressStyle())
                .help("Any colour")
                .accessibilityLabel("Choose any colour")
                .popover(isPresented: $showPicker, arrowEdge: .bottom) {
                    InAppColorPicker(color: $color, rainbow: $rainbow)
                }
            }
            MiniSwitch(title: "Rainbow", isOn: $rainbow)
        }
    }
}

// MARK: - Colour picker

/// Colours an RGB LED shows faithfully: any hue, from vivid to white, always at full
/// strength. Dark and muddy shades don't exist in LED light (they only look dim), so
/// the picker leaves them out; the Brightness slider does that job.
enum LEDColor {
    static let palette: [(String, RGB)] = [
        ("Red", RGB(r: 255, g: 0, b: 0)), ("Orange", RGB(r: 255, g: 80, b: 0)), ("Amber", RGB(r: 255, g: 144, b: 0)),
        ("Yellow", RGB(r: 255, g: 200, b: 0)), ("Lime", RGB(r: 144, g: 255, b: 0)), ("Green", RGB(r: 0, g: 255, b: 48)),
        ("Mint", RGB(r: 0, g: 255, b: 144)), ("Cyan", RGB(r: 0, g: 224, b: 255)), ("Blue", RGB(r: 0, g: 64, b: 255)),
        ("Violet", RGB(r: 128, g: 0, b: 255)), ("Magenta", RGB(r: 255, g: 0, b: 192)), ("White", RGB(r: 255, g: 255, b: 255)),
    ]

    /// hue 0-1, white 0 (vivid) to 1 (white), always at full strength.
    static func rgb(hue: Double, white: Double) -> RGB {
        guard let ns = NSColor(hue: hue, saturation: 1 - white, brightness: 1, alpha: 1).usingColorSpace(.sRGB) else { return RGB(r: 255, g: 255, b: 255) }
        return RGB(r: UInt8((ns.redComponent * 255).rounded()), g: UInt8((ns.greenComponent * 255).rounded()), b: UInt8((ns.blueComponent * 255).rounded()))
    }

    /// Where a colour sits on the hue / white controls (its darkness is dropped).
    static func position(of c: RGB) -> (hue: Double, white: Double, wasDark: Bool) {
        let ns = NSColor(srgbRed: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return (h, 1 - s, b < 0.85)
    }
}

/// The in-app colour picker: twelve LED colours, a hue strip and a vivid-to-white strip,
/// and a hex field. Changes apply as you drag.
struct InAppColorPicker: View {
    @Binding var color: RGB
    @Binding var rainbow: Bool
    @State private var hue = 0.0
    @State private var white = 0.0
    @State private var hex = ""
    @State private var note: String?
    @FocusState private var editingHex: Bool

    private let width: CGFloat = 252

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(21), spacing: 0), count: 12), spacing: 0) {
                ForEach(LEDColor.palette, id: \.0) { name, rgb in
                    Button { set(rgb) } label: {
                        Circle().fill(rgb.color).frame(width: 16, height: 16).padding(2.5)
                            .overlay(Circle().strokeBorder(color == rgb ? Ink.primary : .clear, lineWidth: 1))
                            .overlay(Circle().strokeBorder(Ink.primary.opacity(0.15), lineWidth: 0.5).padding(2.5))
                    }
                    .buttonStyle(PressStyle()).help(name).accessibilityLabel(name)
                }
            }
            .frame(width: width, alignment: .leading)

            strip(title: "Hue", value: $hue, maxValue: 0.999,
                  colors: stride(from: 0.0, through: 1.0, by: 1.0 / 12).map { Color(hue: $0, saturation: 1, brightness: 1) },
                  thumb: Color(hue: hue, saturation: 1, brightness: 1))
            strip(title: "White", value: $white, maxValue: 1,
                  colors: [Color(hue: hue, saturation: 1, brightness: 1), .white],
                  thumb: LEDColor.rgb(hue: hue, white: white).color)

            HStack(spacing: 10) {
                Circle().fill(color.color).frame(width: 22, height: 22)
                    .overlay(Circle().strokeBorder(Ink.primary.opacity(0.2), lineWidth: 0.5))
                Text("#").font(Typeface.text(13, weight: .semibold)).foregroundStyle(Ink.tertiary)
                TextField("Hex", text: $hex)
                    .textFieldStyle(.plain)
                    .font(Typeface.text(13, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(Ink.primary)
                    .focused($editingHex)
                    .frame(width: 80)
                    .onSubmit(applyHex)
                    .onChange(of: editingHex) { if !editingHex { applyHex() } }
                Spacer()
            }
            Text(note ?? "Only colours the keys can show. Set how bright with the Brightness slider.")
                .font(Typeface.text(11)).foregroundStyle(Ink.tertiary)
                .frame(width: width, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .background(Color.panel)
        .preferredColorScheme(Theme.current.dark ? .dark : .light)
        .onAppear(perform: pull)
    }

    private func strip(title: String, value: Binding<Double>, maxValue: Double, colors: [Color], thumb: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(Typeface.text(11.5)).foregroundStyle(Ink.secondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
                        .frame(height: 10).clipShape(Capsule())
                        .overlay(Capsule().strokeBorder(Ink.primary.opacity(0.12), lineWidth: 0.5))
                    Circle().fill(thumb)
                        .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                        .frame(width: 16, height: 16)
                        .shadow(color: .black.opacity(0.4), radius: 2)
                        .offset(x: value.wrappedValue / maxValue * geo.size.width - 8)
                }
                .frame(height: 16)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    value.wrappedValue = min(max(g.location.x / geo.size.width, 0), 1) * maxValue
                    push()
                })
            }
            .frame(width: width, height: 16)
        }
    }

    private func pull() {
        let p = LEDColor.position(of: color)
        hue = p.hue; white = p.white
        hex = color.hex
    }

    private func set(_ rgb: RGB) {
        color = rgb
        rainbow = false
        note = nil
        pull()
    }

    private func push() {
        color = LEDColor.rgb(hue: hue, white: white)
        rainbow = false
        hex = color.hex
        note = nil
    }

    private func applyHex() {
        guard let parsed = RGB(hex: hex) else { hex = color.hex; return }
        let p = LEDColor.position(of: parsed)
        hue = p.hue; white = p.white
        color = LEDColor.rgb(hue: hue, white: white)
        rainbow = false
        hex = color.hex
        note = p.wasDark ? "LEDs can't show dark shades, so this is the same colour at full strength. Use Brightness to dim it." : nil
    }
}
