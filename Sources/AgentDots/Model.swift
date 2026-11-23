import AppKit
import Foundation

enum AgentState: String, Codable {
    case working, done, error, attention, idle

    var title: String {
        switch self {
        case .working: "Working"
        case .done: "Done"
        case .error: "Failed"
        case .attention: "Needs you"
        case .idle: "Idle"
        }
    }

    @MainActor var color: NSColor { Prefs.shared.color(self) }

    /// Higher is more urgent; used to order the rail and pick the menu bar tint.
    var urgency: Int {
        switch self {
        case .attention: 4
        case .error: 3
        case .working: 2
        case .done: 1
        case .idle: 0
        }
    }

    /// Finished states clear when clicked; live ones stay.
    var acknowledgeable: Bool { self == .done || self == .error }
}

struct AgentEvent: Codable {
    var session: String
    var state: AgentState
    var label: String?
    var app: String?
    /// Optional extras: project name, a URL that opens this exact session, and when the state began.
    var project: String? = nil
    var link: String? = nil
    var since: Date? = nil
}

struct Session: Identifiable, Equatable {
    let id: String
    var label: String
    var state: AgentState
    var app: String?
    var project: String?
    var link: String?
    var updated: Date
    var since: Date

    /// "OpenCode · Fix the build" -> ("OpenCode", "Fix the build")
    var parts: (tool: String?, title: String) {
        if let r = label.range(of: " · ") {
            return (String(label[..<r.lowerBound]), String(label[r.upperBound...]))
        }
        return (nil, label)
    }

    var source: String? {
        let tool = parts.tool
        if app == "T3 Code (Beta)", project != nil { return tool }
        let host = app?.replacingOccurrences(of: " (Beta)", with: "")
        switch (tool, host) {
        case let (t?, h?) where t == h: return "\(t) app"
        case let (t?, h?): return "\(t) in \(h)"
        case let (t?, nil): return t
        case let (nil, h?): return h
        default: return nil
        }
    }

    var detail: String? {
        [project, source].compactMap { $0 }.joined(separator: "  ·  ").nilIfEmpty
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

@MainActor
final class Store: ObservableObject {
    @Published private(set) var sessions: [Session] = []
    var muted = false
    private static let stale: TimeInterval = 6 * 60 * 60

    /// Sessions you clicked away, keyed by id, with the state start time they had.
    /// They stay hidden until that session enters a new state.
    private var dismissed: [String: Date] = [:]

    @discardableResult
    func apply(_ ev: AgentEvent, quiet: Bool = false) -> Bool {
        guard !ev.session.isEmpty else { return false }
        // T3 threads come from T3Watcher; drop copies older plugins/hooks send for them.
        if ev.app == "T3 Code (Beta)" && !ev.session.hasPrefix("t3:") {
            sessions.removeAll { $0.id == ev.session }
            return true
        }
        // A hook session that ended has nothing left to tell you. (T3 threads stay, dormant.)
        if ev.state == .idle && !ev.session.hasPrefix("t3:") {
            sessions.removeAll { $0.id == ev.session }
            return true
        }
        let now = Date()
        if let i = sessions.firstIndex(where: { $0.id == ev.session }) {
            var s = sessions[i]
            let changed = s.state != ev.state
            s.state = ev.state
            if let l = ev.label { s.label = l }
            if let a = ev.app { s.app = a }
            if let p = ev.project { s.project = p }
            if let l = ev.link { s.link = l }
            s.updated = now
            if let since = ev.since { s.since = since } else if changed { s.since = now }
            if s != sessions[i] { sessions[i] = s }
            if changed && !quiet { Sounds.play(ev.state, muted: muted) }
        } else {
            let since = ev.since ?? now
            if let d = dismissed[ev.session], abs(d.timeIntervalSince(since)) < 1, ev.state != .idle { return true }
            sessions.append(Session(id: ev.session, label: ev.label ?? ev.session, state: ev.state,
                                    app: ev.app, project: ev.project, link: ev.link, updated: now, since: since))
            if !quiet { Sounds.play(ev.state, muted: muted) }
        }
        return true
    }

    /// Replaces every session whose id starts with `prefix` with `events` (a full snapshot
    /// from a polled source); sessions missing from it are removed.
    func sync(prefix: String, _ events: [AgentEvent], quiet: Bool) {
        let ids = Set(events.map(\.session))
        let stale = sessions.filter { $0.id.hasPrefix(prefix) && !ids.contains($0.id) }.map(\.id)
        if !stale.isEmpty { sessions.removeAll { stale.contains($0.id) } }
        for ev in events {
            var ev = ev
            // A finished thread you clicked away settles to dormant rather than vanishing.
            if let d = dismissed[ev.session], let since = ev.since, abs(d.timeIntervalSince(since)) < 1 {
                guard ev.session.hasPrefix("t3:") else { continue }
                ev.state = .idle
            }
            apply(ev, quiet: quiet || ev.state == .idle)
        }
    }

    func activate(_ id: String) {
        guard let s = sessions.first(where: { $0.id == id }) else { return }
        if let link = s.link, let url = URL(string: link) {
            NSWorkspace.shared.open(url)
        } else if let app = s.app {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-a", app]
            try? p.run()
        }
        if s.state.acknowledgeable { dismiss(id) }
    }

    /// Marks a finished session as seen: T3 threads go dormant, others leave the rail.
    func dismiss(_ id: String) {
        guard let s = sessions.first(where: { $0.id == id }) else { return }
        dismissed[id] = s.since
        if id.hasPrefix("t3:"), let i = sessions.firstIndex(where: { $0.id == id }) {
            sessions[i].state = .idle
        } else {
            sessions.removeAll { $0.id == id }
        }
    }

    func prune() {
        let now = Date()
        let keep = Double(Prefs.shared.keepFinishedMinutes) * 60
        sessions.removeAll {
            $0.updated < now.addingTimeInterval(-Self.stale)
                || (!$0.id.hasPrefix("t3:") && $0.state.acknowledgeable && now.timeIntervalSince($0.since) > keep)
        }
    }

    var json: Data {
        let list = sessions.map { ["id": $0.id, "label": $0.label, "state": $0.state.rawValue, "app": $0.app ?? NSNull(), "project": $0.project ?? NSNull(), "link": $0.link ?? NSNull()] as [String: Any] }
        return (try? JSONSerialization.data(withJSONObject: list)) ?? Data("[]".utf8)
    }
}

@MainActor
enum Sounds {
    static let themes = ["default", "mech", "bubble", "press"]
    static let cues = ["success", "ready", "attention", "warning", "error", "open", "close",
                       "toggle", "select", "tap", "navigate", "loading", "count"]
    private static var playing: [NSSound] = []

    static func themeTitle(_ t: String) -> String {
        ["default": "Glass", "mech": "Mechanical", "bubble": "Bubble", "press": "Press"][t] ?? t.capitalized
    }
    static func cueTitle(_ c: String) -> String {
        ["success": "Success", "ready": "Ready", "attention": "Attention", "warning": "Warning", "error": "Error",
         "open": "Open", "close": "Close", "toggle": "Toggle", "select": "Select", "tap": "Tap",
         "navigate": "Navigate", "loading": "Loading", "count": "Count"][c] ?? c.capitalized
    }

    /// Cuelume cues shipped in the app bundle's Resources (see scripts/render-cues.mjs).
    static func url(cue: String, theme: String) -> URL? {
        let name = "\(theme)-\(cue)"
        if let u = Bundle.main.url(forResource: name, withExtension: "wav") { return u }
        let dev = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../assets/sounds/\(name).wav").standardized
        if FileManager.default.fileExists(atPath: dev.path) { return dev }
        return theme == "default" ? nil : url(cue: cue, theme: "default")
    }

    static func play(cue: String, theme: String? = nil) {
        guard cue != "none", let url = url(cue: cue, theme: theme ?? Prefs.shared.soundTheme),
              let snd = NSSound(contentsOf: url, byReference: true) else { return }
        snd.volume = Float(Prefs.shared.volume)
        playing.removeAll { !$0.isPlaying }
        playing.append(snd)  // keep a reference until it finishes
        snd.play()
    }

    static func play(_ state: AgentState, muted: Bool) {
        guard !muted, !Prefs.shared.muted, let cue = Prefs.shared.cue(for: state) else { return }
        play(cue: cue)
    }

    static func preview() {
        let p = Prefs.shared
        for (i, c) in [p.cueWorking, p.cueDone, p.cueAttention, p.cueError].filter({ $0 != "none" }).enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.9) { play(cue: c) }
        }
    }
}
