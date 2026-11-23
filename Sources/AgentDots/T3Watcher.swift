import AppKit
import SQLite3

/// Mirrors T3 Code threads straight from T3's local state database, so every T3 agent shows
/// up whatever its provider (OpenCode, Claude, Codex) and with T3's own titles. Read-only.
@MainActor
final class T3Watcher {
    private let store: Store
    private let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".t3/userdata")
    private var db: OpaquePointer?
    private var first = true
    /// How long a finished thread shows as Done/Failed before settling to idle.
    private let keepFinished: TimeInterval = 30 * 60
    /// While T3 is open, show this many of its most recent threads (running ones always show).
    static let limit = 10

    init(store: Store) {
        self.store = store
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        poll()
    }

    private lazy var environmentID: String? = {
        let id = try? String(contentsOf: home.appendingPathComponent("environment-id"), encoding: .utf8)
        return id?.trimmingCharacters(in: .whitespacesAndNewlines)
    }()

    private func open() -> Bool {
        if db != nil { return true }
        let path = home.appendingPathComponent("statev2.sqlite").path
        guard FileManager.default.fileExists(atPath: path) else { return false }
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) != SQLITE_OK {
            sqlite3_close(db); db = nil; return false
        }
        sqlite3_busy_timeout(db, 200)
        return true
    }

    private static let query = """
        SELECT t.thread_id, t.title, COALESCE(p.title, ''), COALESCE(t.provider_instance_id, t.default_provider, ''),
               r.status, r.requested_at, COALESCE(r.completed_at, ''),
               (SELECT COUNT(*) FROM orchestration_v2_projection_runtime_requests q
                 WHERE q.thread_id = t.thread_id AND q.status = 'pending'),
               COALESCE(json_extract(t.payload_json, '$.settledAt'), '')
        FROM orchestration_v2_projection_threads t
        JOIN orchestration_v2_projection_runs r ON r.thread_id = t.thread_id
         AND r.ordinal = (SELECT MAX(ordinal) FROM orchestration_v2_projection_runs x WHERE x.thread_id = t.thread_id)
        LEFT JOIN projection_projects p ON p.project_id = t.project_id
        WHERE t.deleted_at IS NULL AND t.archived_at IS NULL
          AND json_extract(t.payload_json, '$.lineage.parentThreadId') IS NULL
        ORDER BY r.requested_at DESC
        LIMIT 40
        """

    private var t3Running: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.t3tools.t3code" }
    }

    private func poll() {
        guard t3Running else {
            store.sync(prefix: "t3:", [], quiet: true)
            first = true
            return
        }
        guard open() else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, Self.query, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_close(db); db = nil; return   // schema changed or file replaced: reopen next tick
        }
        defer { sqlite3_finalize(stmt) }

        var events: [AgentEvent] = []
        let now = Date()
        while sqlite3_step(stmt) == SQLITE_ROW {
            let col = { (i: Int32) in sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? "" }
            let (id, title, project, provider, status) = (col(0), col(1), col(2), col(3), col(4))
            let requested = date(col(5)), completed = date(col(6))
            let pending = sqlite3_column_int(stmt, 7)
            let settled = !col(8).isEmpty

            var state: AgentState
            var since = requested ?? now
            switch status {
            case "queued", "preparing", "starting", "running": state = .working
            case "waiting": state = .attention
            case "completed": state = .done; since = completed ?? since
            case "failed": state = .error; since = completed ?? since
            default: state = .idle; since = completed ?? since  // interrupted / cancelled
            }
            if pending > 0 && state == .working { state = .attention }
            if (state == .done || state == .error) && (settled || now.timeIntervalSince(since) > keepFinished) {
                state = .idle
            }

            var ev = AgentEvent(session: "t3:\(id)", state: state,
                                label: "\(providerName(provider)) · \(clean(title))", app: "T3 Code (Beta)")
            ev.project = project.isEmpty ? nil : project
            ev.since = since
            if let env = environmentID { ev.link = "t3code://threads/\(env)/\(id)" }
            events.append(ev)
        }
        // Live threads always show; dormant ones fill the rest, most recent first.
        let live = events.filter { $0.state != .idle }
        let limit = Prefs.shared.limit
        let dormant = Prefs.shared.showDormant ? Array(events.filter { $0.state == .idle }.prefix(max(0, limit - live.count))) : []
        let shown = Set((live + dormant).map(\.session))
        store.sync(prefix: "t3:", events.filter { shown.contains($0.session) }, quiet: first)
        first = false
    }

    private func clean(_ title: String) -> String {
        title.hasSuffix("...") ? String(title.dropLast(3)).trimmingCharacters(in: .whitespaces) : title
    }

    private func providerName(_ p: String) -> String {
        let l = p.lowercased()
        if l.contains("opencode") { return "OpenCode" }
        if l.contains("claude") { return "Claude" }
        if l.contains("codex") { return "Codex" }
        if l.contains("cursor") { return "Cursor" }
        return p.isEmpty ? "Agent" : p.prefix(1).uppercased() + p.dropFirst()
    }
}

private let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
private func iso(_ d: Date) -> String { isoFormatter.string(from: d) }
private func date(_ s: String) -> Date? { s.isEmpty ? nil : isoFormatter.date(from: s) }
