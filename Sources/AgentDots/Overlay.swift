import AppKit
import SwiftUI

@MainActor
enum Metrics {
    static var p: Prefs { .shared }
    static var k: CGFloat { CGFloat(p.scale) }
    static var markWidth: CGFloat { CGFloat(p.markWidth) * k }
    static var railWidth: CGFloat { markWidth + 10 * k }
    static var panelWidth: CGFloat { CGFloat(p.panelWidth) * k }
    /// Transparent room around the shape, so the window shadow isn't clipped.
    static let margin: CGFloat = 2
    static let edgeInset: CGFloat = 6
    static func rowHeight(_ open: Bool) -> CGFloat { (open ? 44 : 24) * k }
    static func markHeight(_ open: Bool) -> CGFloat { (open ? 22 : 16) * k }
    static func padding(_ open: Bool) -> CGFloat { (open ? 6 : 5) * k }
    static func radius(_ open: Bool) -> CGFloat { open ? 16 * k : railWidth / 2 }
    static func size(rows: Int, open: Bool) -> CGSize {
        let n = CGFloat(max(rows, 1))
        return CGSize(width: (open ? panelWidth : railWidth) + margin * 2,
                      height: padding(open) * 2 + n * rowHeight(open) + margin * 2)
    }
}

@MainActor
final class UIState: ObservableObject {
    @Published var open = false
    var snapshot = false
}

// MARK: - Root

struct OverlayView: View {
    @ObservedObject var store: Store
    @ObservedObject var ui: UIState
    @ObservedObject var prefs = Prefs.shared
    var onHover: (Bool) -> Void = { _ in }

    var body: some View {
        let open = ui.open
        let leftEdge = prefs.edge == .left
        let list = visible(store.sessions, prefs)
        VStack(spacing: 0) {
            ForEach(Array(list.enumerated()), id: \.element.id) { i, s in
                Row(session: s, open: open, leftEdge: leftEdge, last: i == list.count - 1) { store.activate(s.id) }
            }
            if list.isEmpty { Color.clear.frame(height: Metrics.rowHeight(open)) }
        }
        .padding(.vertical, Metrics.padding(open))
        .frame(width: open ? Metrics.panelWidth : Metrics.railWidth, alignment: leftEdge ? .leading : .trailing)
        .surface(radius: Metrics.radius(open), style: prefs.surface, tint: railTint(list), snapshot: ui.snapshot)
        .contentShape(RoundedRectangle(cornerRadius: Metrics.radius(open), style: .continuous))
        .onHover(perform: onHover)
        .padding(Metrics.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: leftEdge ? .topLeading : .topTrailing)
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: list.map(\.id))
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: list.map(\.state))
    }
}

/// The colour of the most urgent live session, for the Tinted background.
@MainActor
func railTint(_ list: [Session]) -> Color {
    guard let top = list.max(by: { $0.state.urgency < $1.state.urgency }), top.state.urgency >= 2 else { return .clear }
    return Color(nsColor: top.state.color)
}

/// What the rail shows, in the order the user picked.
@MainActor
func visible(_ sessions: [Session], _ prefs: Prefs) -> [Session] {
    var list = sessions
    if prefs.dormant == .hidden { list.removeAll { $0.state == .idle } }
    switch prefs.sort {
    case .stable: break
    case .recent: list.sort { $0.since > $1.since }
    case .urgency: list.sort { ($0.state.urgency, $0.since) > ($1.state.urgency, $1.since) }
    }
    return Array(list.prefix(max(prefs.limit, 1)))
}

// MARK: - Row

struct Row: View {
    let session: Session
    let open: Bool
    let leftEdge: Bool
    let last: Bool
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let k = Metrics.k
        HStack(spacing: 10 * k) {
            if leftEdge { mark }
            if open {
                text.transition(.asymmetric(
                    insertion: .opacity.combined(with: .offset(x: (leftEdge ? -14 : 14) * k)).animation(.easeOut(duration: 0.26).delay(0.06)),
                    removal: .opacity.animation(.easeIn(duration: 0.1))))
                Spacer(minLength: 0)
            }
            if !leftEdge { mark }
        }
        .padding(.leading, open ? (leftEdge ? 12 : 14) * k : (leftEdge ? (Metrics.railWidth - Metrics.markWidth) / 2 : 0))
        .padding(.trailing, open ? (leftEdge ? 14 : 12) * k : (leftEdge ? 0 : (Metrics.railWidth - Metrics.markWidth) / 2))
        .frame(height: Metrics.rowHeight(open))
        .background {
            if open && hovered {
                RoundedRectangle(cornerRadius: 10 * k, style: .continuous)
                    .fill(.primary.opacity(0.08))
                    .padding(.horizontal, 5 * k)
                    .padding(.vertical, 1)
            }
        }
        .overlay(alignment: .bottom) {
            if open && !last {
                Rectangle().fill(.primary.opacity(0.08)).frame(height: 0.5).padding(.horizontal, 14 * k)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(perform: action)
        .help(session.label)
    }

    private var mark: some View {
        Mark(state: session.state, width: Metrics.markWidth, height: Metrics.markHeight(open))
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(session.parts.title)
                .font(.system(size: 12.5 * Metrics.k, weight: .medium))
                .foregroundStyle(session.state == .idle ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
            TimelineView(.periodic(from: .now, by: 1)) { ctx in meta(now: ctx.date) }
        }
    }

    private func meta(now: Date) -> some View {
        // Status colours are tuned for marks; darken them for text on light backgrounds.
        let c = session.state.color
        let readable = scheme == .light ? (c.blended(withFraction: 0.32, of: .black) ?? c) : c
        var text = Text(session.state.title).foregroundColor(session.state == .idle ? .secondary : Color(nsColor: readable))
        text = text + Text("  ·  \(ago(now.timeIntervalSince(session.since)))")
        if let d = session.detail { text = text + Text("  ·  \(d)") }
        return text
            .font(.system(size: 10.5 * Metrics.k))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .monospacedDigit()
    }
}

func ago(_ t: TimeInterval) -> String {
    let s = max(0, Int(t))
    switch s {
    case ..<60: return "\(s)s"
    case ..<3600: return "\(s / 60)m"
    case ..<86400: return "\(s / 3600)h \(s / 60 % 60)m"
    default: return "\(s / 86400)d"
    }
}

// MARK: - Status mark

/// Shape and motion carry the state as well as colour, so it reads in any palette:
/// working = moving, done = solid, error = split, attention = breathing, idle = quiet.
struct Mark: View {
    let state: AgentState
    let width: CGFloat
    let height: CGFloat
    @ObservedObject var prefs = Prefs.shared

    var body: some View {
        let c = Color(nsColor: state.color)
        let style = prefs.markStyle
        let live = prefs.animate && (state == .working || state == .attention)
        TimelineView(.animation(paused: !live)) { ctx in
            let t = prefs.animate ? ctx.date.timeIntervalSinceReferenceDate : 0
            let breathe = 0.55 + 0.45 * (0.5 + 0.5 * cos(t * 2 * .pi / 1.1))
            Group {
                if state == .idle {
                    dormant
                } else {
                    switch style {
                    case .dot: dot(c, t: t, breathe: breathe)
                    case .line: line(c, t: t, breathe: breathe)
                    case .bar, .glow: bar(c, t: t, breathe: breathe, glow: style == .glow)
                    }
                }
            }
        }
        .frame(width: max(width, style == .dot ? width + 4 : width), height: height)
    }

    /// Dormant: deliberately not a blob. A thin tick, a hollow ring, or a faint short bar.
    @ViewBuilder private var dormant: some View {
        let c = Color.primary
        switch prefs.dormant {
        case .ring:
            let d = min(width + 3, height * 0.5)
            Circle().strokeBorder(c.opacity(0.35), lineWidth: 1).frame(width: d, height: d)
        case .tick:
            Capsule().fill(c.opacity(0.22)).frame(width: max(1.5, width * 0.45), height: height * 0.55)
        default:
            Capsule().fill(c.opacity(0.18)).frame(width: width, height: height * 0.4)
        }
    }

    @ViewBuilder private func bar(_ c: Color, t: Double, breathe: Double, glow: Bool) -> some View {
        ZStack {
            switch state {
            case .working:
                Capsule().fill(c.opacity(0.25))
                sweep(c, t: t)
            case .done:
                Capsule().fill(c)
            case .error:
                VStack(spacing: 2) { Capsule().fill(c); Capsule().fill(c) }
            case .attention:
                Capsule().fill(c.opacity(breathe)).shadow(color: c.opacity(0.7 * breathe), radius: 3)
            case .idle:
                EmptyView()
            }
        }
        .shadow(color: glow ? c.opacity(0.75) : .clear, radius: glow ? 4 : 0)
        .shadow(color: glow ? c.opacity(0.4) : .clear, radius: glow ? 9 : 0)
    }

    /// A hairline that fills the row: the rail reads as one continuous line.
    @ViewBuilder private func line(_ c: Color, t: Double, breathe: Double) -> some View {
        let w = max(1.5, width * 0.5)
        ZStack {
            switch state {
            case .working:
                Capsule().fill(c.opacity(0.3))
                sweep(c, t: t)
            case .attention: Capsule().fill(c.opacity(breathe))
            case .error:
                VStack(spacing: 3) { Capsule().fill(c); Capsule().fill(c) }
            default: Capsule().fill(c)
            }
        }
        .frame(width: w, height: height * 1.25)
    }

    @ViewBuilder private func dot(_ c: Color, t: Double, breathe: Double) -> some View {
        let d = width + 4
        switch state {
        case .working:
            let phase = (t / 1.3).truncatingRemainder(dividingBy: 1)
            ZStack {
                Circle().fill(c.opacity(0.3))
                Circle().trim(from: 0, to: 0.3).stroke(c, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(phase * 360)).padding(1)
            }.frame(width: d, height: d)
        case .attention:
            Circle().fill(c.opacity(breathe)).frame(width: d, height: d)
                .scaleEffect(0.85 + 0.2 * breathe).shadow(color: c.opacity(0.6 * breathe), radius: 3)
        case .error:
            ZStack {
                Circle().fill(c)
                Capsule().fill(Color.black.opacity(0.45)).frame(width: d * 0.6, height: 1.5)
            }.frame(width: d, height: d)
        default:
            Circle().fill(c).frame(width: d, height: d)
        }
    }

    private func sweep(_ c: Color, t: Double) -> some View {
        GeometryReader { g in
            let phase = CGFloat((t / 1.3).truncatingRemainder(dividingBy: 1))
            let seg = g.size.height * 0.5
            Capsule()
                .fill(LinearGradient(colors: [c.opacity(0), c, c.opacity(0)], startPoint: .top, endPoint: .bottom))
                .frame(height: seg)
                .offset(y: prefs.animate ? -seg + phase * (g.size.height + seg) : g.size.height * 0.25)
        }
        .clipShape(Capsule())
    }
}

// MARK: - Surface

extension View {
    /// The rail's background. Glass is the native material, clipped by AppKit itself
    /// (SwiftUI clipping doesn't apply to behind-window blur). The shadow is the
    /// window's own, so it is never boxed in by the window bounds.
    @ViewBuilder
    func surface(radius: CGFloat, style: Prefs.Surface, tint: Color, snapshot: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let hairline = shape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
        switch style {
        case .bare:
            self
        case .solid:
            self.background(shape.fill(Color(nsColor: .windowBackgroundColor))).overlay(hairline)
        case .frosted:
            self.background(shape.fill(snapshot ? AnyShapeStyle(.thickMaterial) : AnyShapeStyle(Color.clear)))
                .background { if !snapshot { BlurView(radius: radius, material: .menu) } }
                .overlay(hairline)
        case .tinted:
            self.background(shape.fill(tint.opacity(0.16)))
                .background(shape.fill(snapshot ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(Color.clear)))
                .background { if !snapshot { BlurView(radius: radius) } }
                .overlay(shape.strokeBorder(tint.opacity(0.35), lineWidth: 0.75))
        case .glass:
            if snapshot {
                self.background(shape.fill(.regularMaterial)).overlay(hairline)
            } else if #available(macOS 26, *) {
                self.glassEffect(.regular, in: shape)
            } else {
                self.background(BlurView(radius: radius)).overlay(hairline)
            }
        }
    }
}

struct BlurView: NSViewRepresentable {
    var radius: CGFloat
    var material: NSVisualEffectView.Material = .popover

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        v.wantsLayer = true
        v.layer?.cornerCurve = .continuous
        v.layer?.masksToBounds = true
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.layer?.cornerRadius = radius
        v.maskImage = Self.mask(radius)
        v.window?.invalidateShadow()
    }

    /// Behind-window blur only honours a mask image, not layer clipping on its own.
    static func mask(_ r: CGFloat) -> NSImage {
        let size = NSSize(width: r * 2 + 1, height: r * 2 + 1)
        let img = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        img.resizingMode = .stretch
        return img
    }
}
