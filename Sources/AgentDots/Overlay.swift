import AppKit
import SwiftUI

enum Metrics {
    static let railWidth: CGFloat = 14
    static let panelWidth: CGFloat = 284
    static let margin: CGFloat = 10          // room for the shadow inside the window
    static let edgeInset: CGFloat = 6        // gap from the screen edge
    static func rowHeight(_ open: Bool) -> CGFloat { open ? 44 : 24 }
    static func padding(_ open: Bool) -> CGFloat { open ? 6 : 5 }
    static func radius(_ open: Bool) -> CGFloat { open ? 18 : 7 }
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
    var onHover: (Bool) -> Void = { _ in }

    var body: some View {
        let open = ui.open
        VStack(spacing: 0) {
            ForEach(Array(store.sessions.enumerated()), id: \.element.id) { i, s in
                Row(session: s, open: open, last: i == store.sessions.count - 1) { store.activate(s.id) }
            }
            if store.sessions.isEmpty { Color.clear.frame(height: Metrics.rowHeight(open)) }
        }
        .padding(.vertical, Metrics.padding(open))
        .frame(width: open ? Metrics.panelWidth : Metrics.railWidth, alignment: .trailing)
        .glass(radius: Metrics.radius(open), snapshot: ui.snapshot)
        .contentShape(RoundedRectangle(cornerRadius: Metrics.radius(open), style: .continuous))
        .onHover(perform: onHover)
        .padding(Metrics.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: store.sessions.map(\.state))
    }
}

// MARK: - Row

struct Row: View {
    let session: Session
    let open: Bool
    let last: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 10) {
            if open {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.parts.title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        meta(now: ctx.date)
                    }
                }
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .offset(x: 14)).animation(.easeOut(duration: 0.26).delay(0.06)),
                    removal: .opacity.animation(.easeIn(duration: 0.1))))
                Spacer(minLength: 0)
            }
            Mark(state: session.state, height: open ? 22 : 16)
        }
        .padding(.leading, open ? 14 : 0)
        .padding(.trailing, open ? 12 : 5)
        .frame(height: Metrics.rowHeight(open))
        .background {
            if open && hovered {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(.white.opacity(0.08))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
            }
        }
        .overlay(alignment: .bottom) {
            if open && !last {
                Rectangle().fill(.white.opacity(0.07)).frame(height: 0.5).padding(.horizontal, 14)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(perform: action)
        .help(session.label)
    }

    private func meta(now: Date) -> some View {
        var text = Text(session.state.title).foregroundColor(Color(nsColor: session.state.color))
        text = text + Text("  ·  \(ago(now.timeIntervalSince(session.since)))")
        if let src = session.source { text = text + Text("  ·  \(src)") }
        return text
            .font(.system(size: 10.5))
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
    default: return "\(s / 3600)h \(s / 60 % 60)m"
    }
}

// MARK: - Status mark

/// Shape and motion carry the state, not just colour:
/// working = a light sweeping down a dim track, done = solid,
/// error = split in two, attention = breathing with a glow, idle = short and faint.
struct Mark: View {
    let state: AgentState
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
                    Capsule().fill(c.opacity(a)).shadow(color: c.opacity(0.8 * a), radius: 4)
                case .idle:
                    Capsule().fill(c.opacity(0.45)).frame(height: height * 0.4)
                }
            }
        }
        .frame(width: 4, height: height)
    }
}

// MARK: - Glass

extension View {
    /// Liquid Glass on macOS 26+, the native behind-window blur before that.
    /// Snapshots can't capture either, so they get a painted stand-in.
    @ViewBuilder
    func glass(radius: CGFloat, snapshot: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if snapshot {
            self.background(shape.fill(Color(white: 0.14).opacity(0.82)))
                .overlay(shape.strokeBorder(rim, lineWidth: 0.75))
                .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
        } else if #available(macOS 26, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(BlurView().clipShape(shape))
                .background(shape.fill(Color.black.opacity(0.18)))
                .overlay(shape.strokeBorder(rim, lineWidth: 0.75))
                .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
        }
    }

    private var rim: LinearGradient {
        LinearGradient(colors: [.white.opacity(0.32), .white.opacity(0.10), .white.opacity(0.16)],
                       startPoint: .top, endPoint: .bottom)
    }
}

struct BlurView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}
