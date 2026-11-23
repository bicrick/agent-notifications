import AppKit
import SwiftUI

/// User settings, persisted in UserDefaults. Everything the rail looks and sounds like comes from here.
@MainActor
final class Prefs: ObservableObject {
    static let shared = Prefs()
    private let d = UserDefaults.standard

    enum Surface: String, CaseIterable, Identifiable {
        case glass, frosted, solid, tinted, bare
        var id: String { rawValue }
        var title: String { ["glass": "Glass", "frosted": "Frosted", "solid": "Solid", "tinted": "Tinted", "bare": "None"][rawValue]! }
    }
    enum MarkStyle: String, CaseIterable, Identifiable {
        case bar, line, dot, glow
        var id: String { rawValue }
        var title: String { ["bar": "Bars", "line": "Line", "dot": "Dots", "glow": "Glow"][rawValue]! }
    }
    enum Palette: String, CaseIterable, Identifiable {
        case system, vivid, pastel, mono
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }
    enum Dormant: String, CaseIterable, Identifiable {
        case faint, ring, tick, hidden
        var id: String { rawValue }
        var title: String { ["faint": "Faint", "ring": "Outline", "tick": "Tick", "hidden": "Hidden"][rawValue]! }
    }
    enum Sort: String, CaseIterable, Identifiable {
        case recent, urgency, stable
        var id: String { rawValue }
        var title: String { ["recent": "Most recent", "urgency": "Needs you first", "stable": "First seen"][rawValue]! }
    }
    enum Edge: String, CaseIterable, Identifiable { case right, left; var id: String { rawValue } }

    @Published var surface: Surface { didSet { save(surface.rawValue, "surface") } }
    @Published var markStyle: MarkStyle { didSet { save(markStyle.rawValue, "markStyle") } }
    @Published var palette: Palette { didSet { save(palette.rawValue, "palette") } }
    @Published var dormant: Dormant { didSet { save(dormant.rawValue, "dormant") } }
    @Published var animate: Bool { didSet { save(animate, "animate") } }
    @Published var edge: Edge { didSet { save(edge.rawValue, "edge") } }
    /// 0 = top of the screen, 1 = bottom.
    @Published var position: Double { didSet { save(position, "position") } }
    @Published var scale: Double { didSet { save(scale, "scale") } }
    @Published var markWidth: Double { didSet { save(markWidth, "markWidth") } }
    @Published var panelWidth: Double { didSet { save(panelWidth, "panelWidth") } }

    @Published var limit: Int { didSet { save(limit, "limit") } }
    @Published var showDormant: Bool { didSet { save(showDormant, "showDormant") } }
    @Published var sort: Sort { didSet { save(sort.rawValue, "sort") } }
    @Published var keepFinishedMinutes: Int { didSet { save(keepFinishedMinutes, "keepFinishedMinutes") } }
    @Published var useT3: Bool { didSet { save(useT3, "useT3") } }

    @Published var soundTheme: String { didSet { save(soundTheme, "soundTheme") } }
    @Published var cueDone: String { didSet { save(cueDone, "cueDone") } }
    @Published var cueAttention: String { didSet { save(cueAttention, "cueAttention") } }
    @Published var cueError: String { didSet { save(cueError, "cueError") } }
    @Published var cueWorking: String { didSet { save(cueWorking, "cueWorking") } }
    @Published var volume: Double { didSet { save(volume, "volume") } }
    /// Replay the attention cue every N seconds while something waits on you. 0 = never.
    @Published var remindEvery: Int { didSet { save(remindEvery, "remindEvery") } }
    @Published var mutedUntil: Date? { didSet { d.set(mutedUntil, forKey: "mutedUntil") } }

    private func save(_ v: Any, _ k: String) { d.set(v, forKey: k) }
    private func get<T>(_ k: String, _ def: T) -> T { d.object(forKey: k) as? T ?? def }
    private func pick<E: RawRepresentable>(_ k: String, _ def: E) -> E where E.RawValue == String {
        E(rawValue: d.string(forKey: k) ?? "") ?? def
    }

    private init() {
        surface = Prefs.Surface(rawValue: UserDefaults.standard.string(forKey: "surface") ?? UserDefaults.standard.string(forKey: "style") ?? "") ?? .glass
        markStyle = .bar; palette = .system; dormant = .tick; edge = .right; sort = .recent
        animate = true; position = 0.35; scale = 1; markWidth = 4; panelWidth = 284
        limit = 10; showDormant = true; keepFinishedMinutes = 30; useT3 = true
        soundTheme = "default"; cueDone = "success"; cueAttention = "attention"; cueError = "error"; cueWorking = "none"
        volume = 0.8; remindEvery = 0
        markStyle = pick("markStyle", .bar); palette = pick("palette", .system); dormant = pick("dormant", .tick)
        edge = pick("edge", .right); sort = pick("sort", .urgency)
        animate = get("animate", true); position = get("position", 0.35); scale = get("scale", 1.0)
        markWidth = get("markWidth", 4.0); panelWidth = get("panelWidth", 284.0)
        limit = get("limit", 10); showDormant = get("showDormant", true)
        keepFinishedMinutes = get("keepFinishedMinutes", 30); useT3 = get("useT3", true)
        soundTheme = get("soundTheme", "default"); cueDone = get("cueDone", "success")
        cueAttention = get("cueAttention", "attention"); cueError = get("cueError", "error")
        cueWorking = get("cueWorking", "none"); volume = get("volume", 0.8); remindEvery = get("remindEvery", 0)
        mutedUntil = d.object(forKey: "mutedUntil") as? Date
        // Old per-state switches from 0.2 map onto "none".
        if d.object(forKey: "soundDone") as? Bool == false { cueDone = "none" }
        if d.object(forKey: "soundAttention") as? Bool == false { cueAttention = "none" }
        if d.object(forKey: "soundError") as? Bool == false { cueError = "none" }
    }

    var muted: Bool { (mutedUntil ?? .distantPast) > Date() }

    func cue(for s: AgentState) -> String? {
        let c: String
        switch s {
        case .done: c = cueDone
        case .attention: c = cueAttention
        case .error: c = cueError
        case .working: c = cueWorking
        case .idle: return nil
        }
        return c == "none" ? nil : c
    }

    func color(_ s: AgentState) -> NSColor {
        let rgb: (Double, Double, Double)
        switch (palette, s) {
        case (_, .idle): return NSColor.labelColor.withAlphaComponent(0.35)
        case (.mono, _): return .labelColor
        case (.system, .working): rgb = (0.38, 0.65, 1.0)
        case (.system, .done): rgb = (0.20, 0.83, 0.60)
        case (.system, .error): rgb = (1.0, 0.42, 0.42)
        case (.system, .attention): rgb = (1.0, 0.75, 0.14)
        case (.vivid, .working): rgb = (0.16, 0.48, 1.0)
        case (.vivid, .done): rgb = (0.05, 0.80, 0.35)
        case (.vivid, .error): rgb = (1.0, 0.20, 0.28)
        case (.vivid, .attention): rgb = (1.0, 0.58, 0.0)
        case (.pastel, .working): rgb = (0.62, 0.76, 1.0)
        case (.pastel, .done): rgb = (0.58, 0.88, 0.74)
        case (.pastel, .error): rgb = (1.0, 0.66, 0.66)
        case (.pastel, .attention): rgb = (1.0, 0.86, 0.52)
        }
        return NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
    }

    func reset() {
        for k in ["surface", "style", "markStyle", "palette", "dormant", "animate", "edge", "position", "scale", "markWidth",
                  "panelWidth", "limit", "showDormant", "sort", "keepFinishedMinutes", "useT3", "soundTheme", "cueDone",
                  "cueAttention", "cueError", "cueWorking", "volume", "remindEvery", "mutedUntil",
                  "soundDone", "soundAttention", "soundError"] { d.removeObject(forKey: k) }
        let fresh = Prefs(); surface = fresh.surface; markStyle = fresh.markStyle; palette = fresh.palette
        dormant = fresh.dormant; animate = fresh.animate; edge = fresh.edge; position = fresh.position
        scale = fresh.scale; markWidth = fresh.markWidth; panelWidth = fresh.panelWidth; limit = fresh.limit
        showDormant = fresh.showDormant; sort = fresh.sort; keepFinishedMinutes = fresh.keepFinishedMinutes
        useT3 = fresh.useT3; soundTheme = fresh.soundTheme; cueDone = fresh.cueDone; cueAttention = fresh.cueAttention
        cueError = fresh.cueError; cueWorking = fresh.cueWorking; volume = fresh.volume
        remindEvery = fresh.remindEvery; mutedUntil = nil
    }
}

// MARK: - Settings window

struct SettingsView: View {
    var body: some View {
        TabView {
            AppearanceTab().tabItem { Label("Appearance", systemImage: "paintbrush") }
            SoundsTab().tabItem { Label("Sounds", systemImage: "speaker.wave.2") }
            SessionsTab().tabItem { Label("Sessions", systemImage: "list.bullet") }
            AboutTab().tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 520, height: 620)
    }
}

/// A live copy of the rail, fed sample sessions, so changes show as you make them.
struct PreviewRail: View {
    @StateObject private var store: Store = {
        let s = Store(); s.muted = true
        for (id, st, label, project) in [
            ("t3:a", AgentState.working, "OpenCode · Refactor the sync scheduler", "token-tracker"),
            ("t3:b", .attention, "Claude · Approve the database migration", "scorecard-shelf"),
            ("t3:c", .done, "OpenCode · Polish the landing page", "personal-website"),
            ("t3:d", .error, "Codex · Fix flaky CI tests", "proximal-power"),
            ("t3:e", .idle, "OpenCode · Notes on somatic anchors", "proximal-power"),
        ] {
            var ev = AgentEvent(session: id, state: st, label: label, app: "T3 Code (Beta)")
            ev.project = project
            ev.since = Date().addingTimeInterval(-Double.random(in: 20...900))
            s.apply(ev, quiet: true)
        }
        return s
    }()
    @StateObject private var closed = UIState()
    @StateObject private var open: UIState = { let u = UIState(); u.open = true; return u }()
    @ObservedObject var prefs = Prefs.shared

    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            Spacer(minLength: 0)
            OverlayView(store: store, ui: closed).fixedSize()
            OverlayView(store: store, ui: open).fixedSize()
            Spacer(minLength: 0)
        }
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(colors: [Color.primary.opacity(0.06), Color(nsColor: .controlAccentColor).opacity(0.12)],
                           startPoint: .topLeading, endPoint: .bottomTrailing))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .allowsHitTesting(false)
    }
}

struct AppearanceTab: View {
    @ObservedObject var prefs = Prefs.shared
    var body: some View {
        Form {
            Section { PreviewRail().listRowInsets(EdgeInsets()) }
            Section("Style") {
                Picker("Background", selection: $prefs.surface) {
                    ForEach(Prefs.Surface.allCases) { Text($0.title).tag($0) }
                }
                Picker("Marks", selection: $prefs.markStyle) {
                    ForEach(Prefs.MarkStyle.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented)
                Picker("Colours", selection: $prefs.palette) {
                    ForEach(Prefs.Palette.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented)
                Picker("Dormant sessions", selection: $prefs.dormant) {
                    ForEach(Prefs.Dormant.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented)
                Toggle("Animate working and waiting marks", isOn: $prefs.animate)
            }
            Section("Size") {
                slider("Scale", $prefs.scale, 0.75...1.5) { "\(Int($0 * 100))%" }
                slider("Mark width", $prefs.markWidth, 2...8, step: 1) { "\(Int($0)) pt" }
                slider("Panel width", $prefs.panelWidth, 220...420) { "\(Int($0)) pt" }
            }
            Section("Position") {
                Picker("Screen edge", selection: $prefs.edge) {
                    Text("Left").tag(Prefs.Edge.left); Text("Right").tag(Prefs.Edge.right)
                }.pickerStyle(.segmented)
                slider("Height", $prefs.position, 0.05...0.85) { "\(Int($0 * 100))% down" }
            }
        }
        .formStyle(.grouped)
    }
}

struct SoundsTab: View {
    @ObservedObject var prefs = Prefs.shared
    var body: some View {
        Form {
            Section {
                Picker("Sound set", selection: $prefs.soundTheme) {
                    ForEach(Sounds.themes, id: \.self) { Text(Sounds.themeTitle($0)).tag($0) }
                }.pickerStyle(.segmented)
            } footer: {
                Text("Interaction sounds by Cuelume. Each set is a different material: glass, mechanical, bubbly, soft press.")
                    .foregroundStyle(.secondary)
            }
            Section("Play when a session…") {
                cue("Finishes", $prefs.cueDone, .done)
                cue("Needs you", $prefs.cueAttention, .attention)
                cue("Fails", $prefs.cueError, .error)
                cue("Starts working", $prefs.cueWorking, .working)
            }
            Section {
                slider("Volume", $prefs.volume, 0...1) { "\(Int($0 * 100))%" }
                Picker("Remind while waiting", selection: $prefs.remindEvery) {
                    Text("Never").tag(0); Text("Every 30 s").tag(30); Text("Every minute").tag(60)
                    Text("Every 2 minutes").tag(120); Text("Every 5 minutes").tag(300)
                }
                HStack {
                    Button("Preview all") { Sounds.preview() }
                    Spacer()
                    if prefs.muted {
                        Text("Muted until \(prefs.mutedUntil!.formatted(date: .omitted, time: .shortened))").foregroundStyle(.secondary)
                        Button("Unmute") { prefs.mutedUntil = nil }
                    } else {
                        Menu("Mute") {
                            Button("For 15 minutes") { prefs.mutedUntil = Date().addingTimeInterval(900) }
                            Button("For 1 hour") { prefs.mutedUntil = Date().addingTimeInterval(3600) }
                            Button("Until tomorrow") { prefs.mutedUntil = Calendar.current.startOfDay(for: Date().addingTimeInterval(86400)) }
                        }.fixedSize()
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func cue(_ title: String, _ value: Binding<String>, _ state: AgentState) -> some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                Picker("", selection: value) {
                    Text("None").tag("none")
                    Divider()
                    ForEach(Sounds.cues, id: \.self) { Text(Sounds.cueTitle($0)).tag($0) }
                }
                .labelsHidden()
                .onChange(of: value.wrappedValue) { _, new in Sounds.play(cue: new) }
                Button { Sounds.play(cue: value.wrappedValue) } label: { Image(systemName: "play.fill") }
                    .buttonStyle(.borderless)
                    .disabled(value.wrappedValue == "none")
                    .help("Play")
            }
        }
    }
}

struct SessionsTab: View {
    @ObservedObject var prefs = Prefs.shared
    var body: some View {
        Form {
            Section("Rail") {
                Stepper("Show up to \(prefs.limit) sessions", value: $prefs.limit, in: 3...20)
                Picker("Order", selection: $prefs.sort) {
                    ForEach(Prefs.Sort.allCases) { Text($0.title).tag($0) }
                }
                Picker("Keep finished sessions", selection: $prefs.keepFinishedMinutes) {
                    Text("5 minutes").tag(5); Text("15 minutes").tag(15); Text("30 minutes").tag(30)
                    Text("1 hour").tag(60); Text("Until clicked").tag(100_000)
                }
            }
            Section("Sources") {
                Toggle("T3 Code threads", isOn: $prefs.useT3)
                Toggle("Show dormant T3 threads", isOn: $prefs.showDormant).disabled(!prefs.useT3)
                LabeledContent("Claude Code") { Text(Integrations.claudeStatus).foregroundStyle(.secondary) }
                LabeledContent("OpenCode") { Text(Integrations.openCodeStatus).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
    }
}

struct AboutTab: View {
    var body: some View {
        VStack(spacing: 14) {
            Logo().frame(width: 84, height: 84)
            Text("Agent Dots").font(.title2.weight(.semibold))
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                .foregroundStyle(.secondary)
            Text("A quiet line on the edge of your screen for every AI agent you have running.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 320)
            HStack {
                Link("GitHub", destination: URL(string: "https://github.com/bicrick/agent-notifications")!)
                Text("·").foregroundStyle(.tertiary)
                Link("Sounds by Cuelume", destination: URL(string: "https://cuelume-site.pages.dev/")!)
            }
            Button("Reset all settings") { Prefs.shared.reset() }.padding(.top, 6)
        }
        .padding(30)
        .frame(maxWidth: .infinity)
    }
}

enum Integrations {
    static var claudeStatus: String {
        let p = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
        let s = (try? String(contentsOf: p, encoding: .utf8)) ?? ""
        return s.contains("agent-dots hook claude") ? "Connected (hooks)" : "Not connected"
    }
    static var openCodeStatus: String {
        let p = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/opencode/plugins/agent-dots.js")
        return FileManager.default.fileExists(atPath: p.path) ? "Connected (plugin)" : "Not connected"
    }
}

@MainActor
func slider(_ title: String, _ v: Binding<Double>, _ r: ClosedRange<Double>, step: Double? = nil,
            format: @escaping (Double) -> String) -> some View {
    LabeledContent(title) {
        HStack {
            if let step { Slider(value: v, in: r, step: step) } else { Slider(value: v, in: r) }
            Text(format(v.wrappedValue)).monospacedDigit().foregroundStyle(.secondary).frame(width: 74, alignment: .trailing)
        }
    }
}
