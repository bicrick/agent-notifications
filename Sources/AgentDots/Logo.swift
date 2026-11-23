import AppKit
import SwiftUI

/// The Agent Dots mark: one vertical line, split into status segments, like the rail itself.
struct Logo: View {
    var body: some View {
        GeometryReader { g in
            let s = g.size.width
            ZStack {
                RoundedRectangle(cornerRadius: s * 0.225, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.20), Color(white: 0.07)], startPoint: .top, endPoint: .bottom))
                RoundedRectangle(cornerRadius: s * 0.225, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.04)], startPoint: .top, endPoint: .bottom),
                                  lineWidth: max(1, s * 0.008))
                // the rail
                Capsule()
                    .fill(.white.opacity(0.07))
                    .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: max(0.5, s * 0.004)))
                    .frame(width: s * 0.17, height: s * 0.66)
                VStack(spacing: s * 0.035) {
                    segment(Color(red: 0.38, green: 0.65, blue: 1.0), s * 0.24, s)
                    segment(Color(red: 0.20, green: 0.83, blue: 0.60), s * 0.15, s)
                    segment(Color(red: 1.0, green: 0.75, blue: 0.14), s * 0.09, s)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func segment(_ c: Color, _ h: CGFloat, _ s: CGFloat) -> some View {
        Capsule()
            .fill(LinearGradient(colors: [c.opacity(1), c.opacity(0.78)], startPoint: .top, endPoint: .bottom))
            .frame(width: s * 0.055, height: h)
            .shadow(color: c.opacity(0.65), radius: s * 0.03)
    }
}

enum MenuIcon {
    /// A template image (adapts to the menu bar) unless something needs attention,
    /// in which case one segment takes that state's colour.
    @MainActor
    static func image(urgent: AgentState?) -> NSImage {
        let size = NSSize(width: 12, height: 16)
        let accent: NSColor? = urgent.flatMap { $0 == .attention || $0 == .error ? $0.color : nil }
        let img = NSImage(size: size, flipped: true) { _ in
            let x: CGFloat = 4.5, w: CGFloat = 3
            let parts: [(CGFloat, CGFloat)] = [(1.5, 6.5), (9.5, 3.5), (14, 1.5)]
            for (i, (y, h)) in parts.enumerated() {
                let color = (i == 0 ? accent : nil) ?? NSColor.black.withAlphaComponent(i == 2 ? 0.55 : 1)
                color.setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: w / 2, yRadius: w / 2).fill()
            }
            return true
        }
        img.isTemplate = accent == nil
        return img
    }
}

/// Renders the app icon at every size macOS wants, for scripts/install.sh.
@MainActor
func renderIconset(to dir: String) {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    for base in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let px = base * scale
            let r = ImageRenderer(content: Logo().padding(CGFloat(px) * 0.09).frame(width: CGFloat(px), height: CGFloat(px)))
            r.scale = 1
            guard let cg = r.cgImage else { continue }
            let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
            try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
        }
    }
}
