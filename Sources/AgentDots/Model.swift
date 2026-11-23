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

    var color: NSColor {
        switch self {
        case .working: NSColor(srgbRed: 0.38, green: 0.65, blue: 1.0, alpha: 1)
        case .done: NSColor(srgbRed: 0.20, green: 0.83, blue: 0.60, alpha: 1)
        case .error: NSColor(srgbRed: 1.0, green: 0.42, blue: 0.42, alpha: 1)
        case .attention: NSColor(srgbRed: 1.0, green: 0.75, blue: 0.14, alpha: 1)
        case .idle: NSColor(white: 0.55, alpha: 1)
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
        if s.state.acknowledgeable {
            dismissed[id] = s.since
            if id.hasPrefix("t3:") {
                if let i = sessions.firstIndex(where: { $0.id == id }) { sessions[i].state = .idle }
            } else {
                sessions.removeAll { $0.id == id }
            }
        }
    }

    func prune() {
        let cutoff = Date().addingTimeInterval(-Self.stale)
        sessions.removeAll { $0.updated < cutoff }
    }

    var json: Data {
        let list = sessions.map { ["id": $0.id, "label": $0.label, "state": $0.state.rawValue, "app": $0.app ?? NSNull(), "project": $0.project ?? NSNull(), "link": $0.link ?? NSNull()] as [String: Any] }
        return (try? JSONSerialization.data(withJSONObject: list)) ?? Data("[]".utf8)
    }
}

enum Sounds {
    private static var cache: [AgentState: NSSound] = [:]

    /// Cuelume cues shipped in the app bundle's Resources (see scripts/render-cues.mjs).
    static func url(_ state: AgentState) -> URL? {
        let names: [AgentState: String] = [.done: "done", .error: "error", .attention: "attention"]
        guard let name = names[state] else { return nil }
        if let u = Bundle.main.url(forResource: name, withExtension: "wav") { return u }
        let dev = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../assets/sounds/\(name).wav").standardized
        return FileManager.default.fileExists(atPath: dev.path) ? dev : nil
    }

    @MainActor
    static func play(_ state: AgentState, muted: Bool) {
        guard !muted, Prefs.shared.sound(state), let url = url(state) else { return }
        let sound = cache[state] ?? NSSound(contentsOf: url, byReference: true)
        cache[state] = sound
        sound?.stop()
        sound?.volume = Float(Prefs.shared.volume)
        sound?.play()
    }

    @MainActor
    static func preview() {
        for (i, s) in [AgentState.done, .attention, .error].enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.9) {
                guard let url = url(s), let snd = NSSound(contentsOf: url, byReference: true) else { return }
                snd.volume = Float(Prefs.shared.volume)
                snd.play()
                cache[s] = snd
            }
        }
    }
}
