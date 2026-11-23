import Foundation

/// Hook side: a tiny client. Never fails loudly, so a missing overlay can't break an agent.
enum Hook {
    static var port: Int { Int(ProcessInfo.processInfo.environment["AGENT_DOTS_PORT"] ?? "") ?? 47321 }

    static func send(_ ev: AgentEvent) {
        guard let body = try? JSONEncoder().encode(ev),
              let url = URL(string: "http://127.0.0.1:\(port)/event") else { return }
        var req = URLRequest(url: url, timeoutInterval: 0.5)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { _, _, _ in done.signal() }.resume()
        _ = done.wait(timeout: .now() + 0.8)
    }

    /// Which app hosts this agent, guessed from the hook process's environment.
    static func hostApp() -> String? {
        let env = ProcessInfo.processInfo.environment
        let bundle = env["__CFBundleIdentifier"] ?? ""
        if env["T3CODE_CLI_PATH"] != nil || bundle.contains("t3code") { return "T3 Code (Beta)" }
        if bundle.contains("claudefordesktop") || (env["CLAUDE_CODE_ENTRYPOINT"] ?? "").contains("desktop") { return "Claude" }
        switch env["TERM_PROGRAM"] ?? "" {
        case "Apple_Terminal": return "Terminal"
        case "iTerm.app": return "iTerm"
        case "ghostty": return "Ghostty"
        case "WezTerm": return "WezTerm"
        case "vscode": return "Visual Studio Code"
        default: return nil
        }
    }

    private static func dirName(_ p: [String: Any]) -> String {
        guard let cwd = p["cwd"] as? String else { return "" }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }

    static func run(_ kind: String, _ rest: [String]) {
        // Agents running inside T3 Code are read from T3's own state instead.
        if hostApp() == "T3 Code (Beta)" { return }
        switch kind {
        case "claude":
            let data = FileHandle.standardInput.readDataToEndOfFile()
            let p = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            let state: AgentState
            switch p["hook_event_name"] as? String ?? "" {
            case "UserPromptSubmit", "PreToolUse", "PostToolUse": state = .working
            case "Notification", "PermissionRequest": state = .attention
            case "Stop": state = .done
            case "StopFailure": state = .error
            case "SessionEnd": state = .idle
            default: return
            }
            send(AgentEvent(session: "claude:\(p["session_id"] as? String ?? "?")", state: state,
                            label: "Claude · \(dirName(p))", app: hostApp()))
        case "codex":
            guard let raw = rest.last?.data(using: .utf8),
                  let p = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
                  p["type"] as? String == "agent-turn-complete" else { return }
            let id = p["thread-id"] as? String ?? p["turn-id"] as? String ?? "?"
            send(AgentEvent(session: "codex:\(id)", state: .done, label: "Codex · \(dirName(p))", app: hostApp()))
        default:
            return
        }
    }

    static func demo() {
        let wait = { (s: Double) in Thread.sleep(forTimeInterval: s) }
        send(AgentEvent(session: "demo-1", state: .working, label: "Claude · token-tracker", app: "Terminal"))
        send(AgentEvent(session: "demo-2", state: .working, label: "OpenCode · Refactor the sync scheduler", app: "T3 Code (Beta)"))
        send(AgentEvent(session: "demo-3", state: .working, label: "OpenCode · personal-website", app: nil))
        wait(2); send(AgentEvent(session: "demo-1", state: .done))
        wait(1.5); send(AgentEvent(session: "demo-2", state: .attention))
        wait(1.5); send(AgentEvent(session: "demo-3", state: .error))
        print("Demo sent. Hover the rail for details; click a session to open its app.")
    }
}
