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
        VStack(spacing: 0) {
            ForEach(Array(store.sessions.enumerated()), id: \.element.id) { i, s in
                Row(session: s, open: open, leftEdge: leftEdge, last: i == store.sessions.count - 1) { store.activate(s.id) }
            }
            if store.sessions.isEmpty { Color.clear.frame(height: Metrics.rowHeight(open)) }
        }
        .padding(.vertical, Metrics.padding(open))
        .frame(width: open ? Metrics.panelWidth : Metrics.railWidth, alignment: leftEdge ? .leading : .trailing)
        .surface(radius: Metrics.radius(open), style: prefs.style, snapshot: ui.snapshot)
        .contentShape(RoundedRectangle(cornerRadius: Metrics.radius(open), style: .continuous))
        .onHover(perform: onHover)
        .padding(Metrics.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: leftEdge ? .topLeading : .topTrailing)
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: store.sessions.map(\.state))
    }
}

// MARK: - Row

struct Row: View {
    let session: Session
    let open: Bool
    let leftEdge: Bool
    let last: Bool
    let action: () -> Void
    @State private var hovered = false

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
        var text = Text(session.state.title).foregroundColor(session.state == .idle ? .secondary : Color(nsColor: session.state.color))
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

/// Shape and motion carry the state, not just colour:
/// working = a light sweeping down a dim track, done = solid,
/// error = split in two, attention = breathing with a glow, idle = short and faint.
struct Mark: View {
    let state: AgentState
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        let c = Color(nsColor: state.color)
        TimelineView(.animation(paused: !(state == .working || state == .attention))) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            ZStack {
                switch state {
                case .working:
                    Capsule().fill(c.opacity(0.25))
                    GeometryReader { g in
                        let phase = CGFloat((t / 1.3).truncatingRemainder(dividingBy: 1))
                        let seg = g.size.height * 0.5
                        Capsule()
                            .fill(LinearGradient(colors: [c.opacity(0), c, c.opacity(0)], startPoint: .top, endPoint: .bottom))
                            .frame(height: seg)
                            .offset(y: -seg + phase * (g.size.height + seg))
                    }
                    .clipShape(Capsule())
                case .done:
                    Capsule().fill(c)
                case .error:
                    VStack(spacing: 2) { Capsule().fill(c); Capsule().fill(c) }
                case .attention:
                    let a = 0.55 + 0.45 * (0.5 + 0.5 * cos(t * 2 * .pi / 1.1))
                    Capsule().fill(c.opacity(a)).shadow(color: c.opacity(0.7 * a), radius: 3)
                case .idle:
                    Capsule().fill(Color.primary.opacity(0.28)).frame(height: height * 0.4)
                }
            }
        }
        .frame(width: width, height: height)
    }
}

// MARK: - Surface

extension View {
    /// The rail's background. Glass is the native material, clipped by AppKit itself
    /// (SwiftUI clipping doesn't apply to behind-window blur). The shadow is the
    /// window's own, so it is never boxed in by the window bounds.
    @ViewBuilder
    func surface(radius: CGFloat, style: Prefs.Style, snapshot: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        switch style {
        case .bare:
            self
        case .solid:
            self.background(shape.fill(Color(nsColor: .windowBackgroundColor)))
                .overlay(shape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        case .glass:
            if snapshot {
                self.background(shape.fill(.regularMaterial)).overlay(shape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
            } else if #available(macOS 26, *) {
                self.glassEffect(.regular, in: shape)
            } else {
                self.background(BlurView(radius: radius))
                    .overlay(shape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
            }
        }
    }
}

struct BlurView: NSViewRepresentable {
    var radius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .popover
        v.blendingMode = .behindWindow
        v.state = .active
        v.wantsLayer = true
        v.layer?.cornerCurve = .continuous
        v.layer?.masksToBounds = true
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
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
