import AppKit
import SwiftUI

//   agent-dots                                   run the overlay (127.0.0.1:47321)
//   agent-dots hook claude                       Claude Code hook (payload JSON on stdin)
//   agent-dots hook codex '<json>'               Codex `notify`
//   agent-dots set <session> <state> [label] [app]
//   agent-dots demo                              send fake sessions to a running overlay
//   agent-dots snapshot <out.png> [open 0|1]     render sample sessions to a PNG

final class Panel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class Controller: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let store = Store()
    let ui = UIState()
    var panel: Panel!
    var server: Server?
    var t3: T3Watcher?
    var hovering = false
    var collapseWork: DispatchWorkItem?
    var observer: Any?
    var prefsObserver: Any?
    var status: NSStatusItem?
    var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ note: Notification) {
        panel = Panel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isMovable = false
        panel.hidesOnDeactivate = false

        let host = NSHostingView(rootView: OverlayView(store: store, ui: ui) { [weak self] in self?.hover($0) })
        host.sizingOptions = []
        panel.contentView = host
        place(open: false)
        panel.orderFrontRegardless()

        do { server = try Server(port: UInt16(Hook.port), store: store) } catch {
            FileHandle.standardError.write(Data("agent-dots: \(error)\n".utf8)); exit(1)
        }

        t3 = T3Watcher(store: store)
        setupMenu()
        prefsObserver = Prefs.shared.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.place(open: self?.panelOpen ?? false) }
        }

        observer = store.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.place(open: self?.panelOpen ?? false) }
        }
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.store.prune() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.place(open: self?.panelOpen ?? false) }
        }
    }

    /// Whether the window is currently sized for the open panel.
    private var panelOpen = false

    /// Pins the window's top-right corner to the right screen edge, about a third down.
    func place(open: Bool) {
        panelOpen = open
        guard let screen = NSScreen.main else { return }
        let prefs = Prefs.shared
        let size = Metrics.size(rows: store.sessions.count, open: open)
        let f = screen.frame
        let top = f.maxY - f.height * prefs.position + Metrics.margin
        let x = prefs.edge == .right
            ? f.maxX - size.width - Metrics.edgeInset + Metrics.margin
            : f.minX + Metrics.edgeInset - Metrics.margin
        panel.setFrame(NSRect(x: x, y: top - size.height, width: size.width, height: size.height), display: true)
        panel.invalidateShadow()
    }

    func setupMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "circle.grid.3x3.fill", accessibilityDescription: "Agent Dots")
        item.button?.image?.size = NSSize(width: 14, height: 14)
        let menu = NSMenu()
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Mute for 1 Hour", action: #selector(toggleMute), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Agent Dots", action: #selector(quit), keyEquivalent: "q").target = self
        menu.delegate = self
        item.menu = menu
        status = item
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            w.title = "Agent Dots Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            settingsWindow = w
        }
        settingsWindow?.center()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func toggleMute() {
        let p = Prefs.shared
        p.mutedUntil = p.muted ? nil : Date().addingTimeInterval(3600)
    }

    @objc func quit() {
        // KeepAlive would restart us; unload the login item first.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["bootout", "gui/\(getuid())/dev.bicrick.agent-dots"]
        try? p.run()
        NSApp.terminate(nil)
    }

    /// Open: grow the window first, then let SwiftUI spring the panel out inside it.
    /// Close: spring the panel in, then shrink the window once it's settled.
    func hover(_ inside: Bool) {
        hovering = inside
        collapseWork?.cancel()
        if inside {
            place(open: true)
            withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) { ui.open = true }
        } else {
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.hovering else { return }
                withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) { self.ui.open = false }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    if !self.hovering { self.place(open: false) }
                }
            }
            collapseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        }
    }
}

extension Controller {
    nonisolated func menuWillOpen(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            menu.item(at: 1)?.title = Prefs.shared.muted ? "Unmute" : "Mute for 1 Hour"
        }
    }
}

@MainActor
func snapshot(path: String, open: Bool, light: Bool) {
    let store = Store()
    store.muted = true
    let samples: [(String, AgentState, String, String?)] = [
        ("t3:a", .working, "OpenCode · Agent Notification Sounds and Overlay Status Indicator Ideas", "T3 Code (Beta)"),
        ("b", .done, "Claude · token-tracker", "Terminal"),
        ("t3:c", .attention, "OpenCode · Experiment Design: Proximal vs. Distal Control", "T3 Code (Beta)"),
        ("d", .error, "Claude · personal-website", "Claude"),
    ]
    for (id, st, label, app) in samples {
        var ev = AgentEvent(session: id, state: st, label: label, app: app)
        if app == "T3 Code (Beta)" { ev.project = id == "t3:a" ? "token-tracker" : "proximal-power" }
        store.apply(ev)
    }
    let ui = UIState()
    ui.open = open
    ui.snapshot = true
    let size = Metrics.size(rows: samples.count, open: open)
    let view = ZStack {
        LinearGradient(colors: light ? [Color(white: 0.97), Color(red: 0.86, green: 0.89, blue: 0.95)]
                                     : [Color(white: 0.30), Color(red: 0.16, green: 0.18, blue: 0.24)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
        OverlayView(store: store, ui: ui).frame(width: size.width, height: size.height)
    }
    .frame(width: size.width + 60, height: size.height + 60)
    .environment(\.colorScheme, light ? .light : .dark)

    let r = ImageRenderer(content: view)
    r.scale = 2
    guard let cg = r.cgImage else { print("render failed"); exit(1) }
    let rep = NSBitmapImageRep(cgImage: cg)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case nil:
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let controller = MainActor.assumeIsolated { Controller() }
    app.delegate = controller
    app.run()
case "hook":
    Hook.run(args.count > 1 ? args[1] : "", Array(args.dropFirst(2)))
case "set" where args.count >= 3:
    guard let state = AgentState(rawValue: args[2]) else { exit(2) }
    Hook.send(AgentEvent(session: args[1], state: state, label: args.count > 3 ? args[3] : nil,
                         app: args.count > 4 ? args[4] : Hook.hostApp()))
case "demo":
    Hook.demo()
case "snapshot":
    MainActor.assumeIsolated {
        snapshot(path: args.count > 1 ? args[1] : "snapshot.png", open: (args.count > 2 ? args[2] : "1") != "0",
                 light: args.count > 3 && args[3] == "light")
    }
default:
    FileHandle.standardError.write(Data("usage: agent-dots [hook claude|hook codex <json>|set <session> <state> [label] [app]|demo|snapshot <out.png> [0|1]]\n".utf8))
    exit(2)
}
