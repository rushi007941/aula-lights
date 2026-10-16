// The app icon, drawn in code so every size is sharp. `AulaLights make-icon <dir>` writes
// an .iconset that build/package scripts turn into AppIcon.icns with iconutil.

import AppKit
import SwiftUI

struct AppIconView: View {
    var body: some View {
        ZStack {
            // macOS icon grid: an 824 pt rounded square centred in 1024
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0x2A2A2F), Color(hex: 0x0E0E10)], startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 185, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.02)], startPoint: .top, endPoint: .bottom), lineWidth: 4))
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.45), radius: 24, y: 14)

            // Ticks round the dial
            ForEach(0..<60, id: \.self) { t in
                Capsule().fill(Color.white.opacity(t % 5 == 0 ? 0.45 : 0.16))
                    .frame(width: t % 5 == 0 ? 10 : 6, height: t % 5 == 0 ? 42 : 26)
                    .offset(y: -318)
                    .rotationEffect(.degrees(Double(t) * 6))
            }

            // The arc of RGB light
            Circle().trim(from: 0.06, to: 0.94)
                .stroke(AngularGradient(colors: [Color(hex: 0xFF3B30), Color(hex: 0xFF9500), Color(hex: 0xFFD60A), Color(hex: 0x34C759),
                                                 Color(hex: 0x00C7BE), Color(hex: 0x0A84FF), Color(hex: 0xBF5AF2), Color(hex: 0xFF3B30)],
                                        center: .center),
                        style: StrokeStyle(lineWidth: 46, lineCap: .round))
                .rotationEffect(.degrees(90))
                .frame(width: 500, height: 500)
                .blur(radius: 18).opacity(0.75)
            Circle().trim(from: 0.06, to: 0.94)
                .stroke(AngularGradient(colors: [Color(hex: 0xFF3B30), Color(hex: 0xFF9500), Color(hex: 0xFFD60A), Color(hex: 0x34C759),
                                                 Color(hex: 0x00C7BE), Color(hex: 0x0A84FF), Color(hex: 0xBF5AF2), Color(hex: 0xFF3B30)],
                                        center: .center),
                        style: StrokeStyle(lineWidth: 26, lineCap: .round))
                .rotationEffect(.degrees(90))
                .frame(width: 500, height: 500)

            // The knob, lit from the top left, with a keycap-yellow notch
            Circle()
                .fill(RadialGradient(colors: [Color(hex: 0x5A5D68), Color(hex: 0x1A1B20)],
                                     center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0, endRadius: 260))
                .frame(width: 370, height: 370)
                .overlay(Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.04)], startPoint: .top, endPoint: .bottom), lineWidth: 4))
                .shadow(color: .black.opacity(0.6), radius: 20, y: 12)
            ForEach(0..<48, id: \.self) { t in
                Capsule().fill(Color.black.opacity(0.35)).frame(width: 4, height: 22)
                    .offset(y: -172).rotationEffect(.degrees(Double(t) * 7.5))
            }
            Capsule().fill(Color(hex: 0xE6B64C))
                .frame(width: 26, height: 92)
                .offset(y: -100)
                .rotationEffect(.degrees(28))
                .shadow(color: Color(hex: 0xE6B64C).opacity(0.6), radius: 14)
        }
        .frame(width: 1024, height: 1024)
    }
}

enum IconMaker {
    /// Writes icon_16x16.png … icon_512x512@2x.png into `dir` (an .iconset folder).
    @MainActor static func write(to dir: URL) -> Int32 {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let renderer = ImageRenderer(content: AppIconView())
        renderer.scale = 1
        guard let big = renderer.nsImage else { return 1 }
        for size in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let px = size * scale
                let image = NSImage(size: NSSize(width: px, height: px))
                image.lockFocus()
                NSGraphicsContext.current?.imageInterpolation = .high
                big.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
                image.unlockFocus()
                guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else { return 1 }
                let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
                try? png.write(to: dir.appendingPathComponent(name))
            }
        }
        return 0
    }
}
