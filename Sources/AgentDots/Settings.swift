import AppKit
import SwiftUI

/// User settings, persisted in UserDefaults. Everything the rail looks like comes from here.
@MainActor
final class Prefs: ObservableObject {
    static let shared = Prefs()
    private let d = UserDefaults.standard

    enum Style: String, CaseIterable, Identifiable { case glass, solid, bare; var id: String { rawValue } }
    enum Edge: String, CaseIterable, Identifiable { case right, left; var id: String { rawValue } }

    @Published var style: Style { didSet { d.set(style.rawValue, forKey: "style") } }
    @Published var edge: Edge { didSet { d.set(edge.rawValue, forKey: "edge") } }
    /// 0 = top of the screen, 1 = bottom.
    @Published var position: Double { didSet { d.set(position, forKey: "position") } }
    /// Overall size multiplier for the rail and panel.
    @Published var scale: Double { didSet { d.set(scale, forKey: "scale") } }
    /// Width of each status mark, in points.
    @Published var markWidth: Double { didSet { d.set(markWidth, forKey: "markWidth") } }
    @Published var panelWidth: Double { didSet { d.set(panelWidth, forKey: "panelWidth") } }
    @Published var limit: Int { didSet { d.set(limit, forKey: "limit") } }
    @Published var showDormant: Bool { didSet { d.set(showDormant, forKey: "showDormant") } }
    @Published var volume: Double { didSet { d.set(volume, forKey: "volume") } }
    @Published var soundDone: Bool { didSet { d.set(soundDone, forKey: "soundDone") } }
    @Published var soundAttention: Bool { didSet { d.set(soundAttention, forKey: "soundAttention") } }
    @Published var soundError: Bool { didSet { d.set(soundError, forKey: "soundError") } }
    @Published var mutedUntil: Date? { didSet { d.set(mutedUntil, forKey: "mutedUntil") } }

    private init() {
        style = Style(rawValue: d.string(forKey: "style") ?? "") ?? .glass
        edge = Edge(rawValue: d.string(forKey: "edge") ?? "") ?? .right
        position = d.object(forKey: "position") as? Double ?? 0.35
        scale = d.object(forKey: "scale") as? Double ?? 1.0
        markWidth = d.object(forKey: "markWidth") as? Double ?? 4
        panelWidth = d.object(forKey: "panelWidth") as? Double ?? 284
        limit = d.object(forKey: "limit") as? Int ?? 10
        showDormant = d.object(forKey: "showDormant") as? Bool ?? true
        volume = d.object(forKey: "volume") as? Double ?? 0.8
        soundDone = d.object(forKey: "soundDone") as? Bool ?? true
        soundAttention = d.object(forKey: "soundAttention") as? Bool ?? true
        soundError = d.object(forKey: "soundError") as? Bool ?? true
        mutedUntil = d.object(forKey: "mutedUntil") as? Date
    }

    var muted: Bool { (mutedUntil ?? .distantPast) > Date() }

    func sound(_ s: AgentState) -> Bool {
        guard !muted else { return false }
        switch s {
        case .done: return soundDone
        case .attention: return soundAttention
        case .error: return soundError
        default: return false
        }
    }
}

struct SettingsView: View {
    @ObservedObject var prefs = Prefs.shared
    var preview: () -> Void = {}

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Style", selection: $prefs.style) {
                    Text("Glass").tag(Prefs.Style.glass)
                    Text("Solid").tag(Prefs.Style.solid)
                    Text("Marks only").tag(Prefs.Style.bare)
                }
                .pickerStyle(.segmented)
                slider("Size", $prefs.scale, 0.75...1.5, format: { "\(Int($0 * 100))%" })
                slider("Mark width", $prefs.markWidth, 2...8, step: 1, format: { "\(Int($0)) pt" })
                slider("Panel width", $prefs.panelWidth, 220...420, step: 4, format: { "\(Int($0)) pt" })
            }
            Section("Position") {
                Picker("Screen edge", selection: $prefs.edge) {
                    Text("Left").tag(Prefs.Edge.left)
                    Text("Right").tag(Prefs.Edge.right)
                }
                .pickerStyle(.segmented)
                slider("Height", $prefs.position, 0.05...0.85, format: { "\(Int($0 * 100))% down" })
            }
            Section("Sessions") {
                Stepper("Show up to \(prefs.limit)", value: $prefs.limit, in: 3...20)
                Toggle("Show dormant T3 threads", isOn: $prefs.showDormant)
            }
            Section("Sounds") {
                Toggle("Done", isOn: $prefs.soundDone)
                Toggle("Needs you", isOn: $prefs.soundAttention)
                Toggle("Failed", isOn: $prefs.soundError)
                slider("Volume", $prefs.volume, 0...1, format: { "\(Int($0 * 100))%" })
                HStack {
                    Button("Preview") { Sounds.preview() }
                    Spacer()
                    if prefs.muted {
                        Button("Unmute") { prefs.mutedUntil = nil }
                    } else {
                        Button("Mute for 1 hour") { prefs.mutedUntil = Date().addingTimeInterval(3600) }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func slider(_ title: String, _ v: Binding<Double>, _ r: ClosedRange<Double>, step: Double? = nil,
                        format: @escaping (Double) -> String) -> some View {
        LabeledContent(title) {
            HStack {
                if let step { Slider(value: v, in: r, step: step) } else { Slider(value: v, in: r) }
                Text(format(v.wrappedValue)).monospacedDigit().foregroundStyle(.secondary).frame(width: 74, alignment: .trailing)
            }
        }
    }
}
