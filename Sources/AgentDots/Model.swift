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
}

struct Session: Identifiable, Equatable {
    let id: String
    var label: String
    var state: AgentState
    var app: String?
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
        let host = app?.replacingOccurrences(of: " (Beta)", with: "")
        switch (tool, host) {
        case let (t?, h?) where t == h: return "\(t) app"
        case let (t?, h?): return "\(t) in \(h)"
        case let (t?, nil): return t
        case let (nil, h?): return h
        default: return nil
        }
    }
}

@MainActor
final class Store: ObservableObject {
    @Published private(set) var sessions: [Session] = []
    var muted = false
    private static let stale: TimeInterval = 6 * 60 * 60

    @discardableResult
    func apply(_ ev: AgentEvent) -> Bool {
        guard !ev.session.isEmpty else { return false }
        let now = Date()
        if let i = sessions.firstIndex(where: { $0.id == ev.session }) {
            let changed = sessions[i].state != ev.state
            sessions[i].state = ev.state
            if let l = ev.label { sessions[i].label = l }
            if let a = ev.app { sessions[i].app = a }
            sessions[i].updated = now
            if changed {
                sessions[i].since = now
                Sounds.play(ev.state, muted: muted)
            }
        } else {
            sessions.append(Session(id: ev.session, label: ev.label ?? ev.session, state: ev.state,
                                    app: ev.app, updated: now, since: now))
            Sounds.play(ev.state, muted: muted)
        }
        return true
    }

    func activate(_ id: String) {
        guard let s = sessions.first(where: { $0.id == id }) else { return }
        if let app = s.app {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-a", app]
            try? p.run()
        }
        if s.state.acknowledgeable { sessions.removeAll { $0.id == id } }
    }

    func prune() {
        let cutoff = Date().addingTimeInterval(-Self.stale)
        sessions.removeAll { $0.updated < cutoff }
    }

    var json: Data {
        let list = sessions.map { ["id": $0.id, "label": $0.label, "state": $0.state.rawValue, "app": $0.app ?? NSNull()] as [String: Any] }
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

    static func play(_ state: AgentState, muted: Bool) {
        guard !muted, let url = url(state) else { return }
        let sound = cache[state] ?? NSSound(contentsOf: url, byReference: true)
        cache[state] = sound
        sound?.stop()
        sound?.play()
    }
}
