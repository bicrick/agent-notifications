//! agent-dots: a tiny always-on-top row of dots showing what your AI coding agents are doing.
//!
//!   agent-dots                          run the overlay (listens on 127.0.0.1:47321)
//!   agent-dots hook claude              Claude Code hook (payload JSON on stdin)
//!   agent-dots hook codex '<json>'      Codex `notify` (payload JSON as last argument)
//!   agent-dots set <session> <state> [label] [app]
//!   agent-dots demo                     send fake sessions to a running overlay
//!
//! States: working (blue, pulsing), done (green), error (red),
//! attention (yellow, flashing), idle (gray).

use eframe::egui::{self, Color32, Pos2, Sense, Vec2};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::io::{Read, Write};
use std::net::TcpStream;
use std::path::Path;
use std::process::Command;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

// Each session is a slim vertical mark on a dark rail hugging the screen edge.
// Deliberately not round, so it never reads as macOS window buttons.
const MARK_W: f32 = 4.0;
const MARK_H: f32 = 18.0;
const GAP: f32 = 6.0;
const PAD: f32 = 4.0;
const RAIL_W: f32 = MARK_W + PAD * 2.0;
// Width of the panel the rail slides out into on hover.
const PANEL_W: f32 = 280.0;
const OPEN_ROW_H: f32 = 40.0;
const STALE: Duration = Duration::from_secs(6 * 60 * 60);

fn port() -> u16 {
    std::env::var("AGENT_DOTS_PORT").ok().and_then(|p| p.parse().ok()).unwrap_or(47321)
}

#[derive(Serialize, Deserialize, Clone)]
struct Event {
    session: String,
    state: String,
    label: Option<String>,
    app: Option<String>,
}

#[derive(Clone)]
struct Session {
    id: String,
    label: String,
    state: String,
    app: Option<String>,
    updated: Instant,
    since: Instant,
}

type Shared = Arc<Mutex<Vec<Session>>>;

fn valid(state: &str) -> bool {
    matches!(state, "working" | "done" | "error" | "attention" | "idle")
}

// Cuelume cues, rendered to WAV by scripts/render-cues.mjs and embedded in the binary.
const SOUNDS: [(&str, &[u8]); 3] = [
    ("done", include_bytes!("../assets/sounds/done.wav")),
    ("error", include_bytes!("../assets/sounds/error.wav")),
    ("attention", include_bytes!("../assets/sounds/attention.wav")),
];

fn sound_path(state: &str) -> Option<std::path::PathBuf> {
    let (_, bytes) = SOUNDS.iter().find(|(s, _)| *s == state)?;
    let path = std::env::temp_dir().join(format!("agent-dots-{state}.wav"));
    if std::fs::metadata(&path).map(|m| m.len()).ok() != Some(bytes.len() as u64) {
        std::fs::write(&path, bytes).ok()?;
    }
    Some(path)
}

fn play(state: &str) {
    if std::env::var_os("AGENT_DOTS_MUTE").is_some() {
        return;
    }
    if !cfg!(target_os = "macos") {
        return;
    }
    if let Some(path) = sound_path(state) {
        let _ = Command::new("afplay").arg(path).spawn();
    }
}

fn apply(sessions: &Shared, ev: Event) -> bool {
    if ev.session.is_empty() || !valid(&ev.state) {
        return false;
    }
    let mut list = sessions.lock().unwrap();
    let changed = match list.iter_mut().find(|s| s.id == ev.session) {
        Some(s) => {
            let changed = s.state != ev.state;
            if changed {
                s.since = Instant::now();
            }
            s.state = ev.state.clone();
            if let Some(l) = ev.label {
                s.label = l;
            }
            if ev.app.is_some() {
                s.app = ev.app;
            }
            s.updated = Instant::now();
            changed
        }
        None => {
            list.push(Session {
                label: ev.label.unwrap_or_else(|| ev.session.clone()),
                id: ev.session,
                state: ev.state.clone(),
                app: ev.app,
                updated: Instant::now(),
                since: Instant::now(),
            });
            true
        }
    };
    if changed {
        play(&ev.state);
    }
    true
}

fn serve(sessions: Shared, ctx: egui::Context) {
    let server = match tiny_http::Server::http(("127.0.0.1", port())) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("agent-dots: cannot listen on port {}: {e}", port());
            std::process::exit(1);
        }
    };
    for mut req in server.incoming_requests() {
        let status = match (req.method(), req.url()) {
            (tiny_http::Method::Post, "/event") => {
                let mut body = String::new();
                let _ = req.as_reader().read_to_string(&mut body);
                let ok = serde_json::from_str::<Event>(&body).is_ok_and(|ev| apply(&sessions, ev));
                ctx.request_repaint();
                if ok { 204 } else { 400 }
            }
            (tiny_http::Method::Get, "/state") => {
                let list: Vec<Value> = sessions
                    .lock()
                    .unwrap()
                    .iter()
                    .map(|s| serde_json::json!({"id": s.id, "label": s.label, "state": s.state, "app": s.app}))
                    .collect();
                let _ = req.respond(tiny_http::Response::from_string(Value::from(list).to_string()));
                continue;
            }
            _ => 404,
        };
        let _ = req.respond(tiny_http::Response::empty(status));
    }
}

struct Overlay {
    sessions: Shared,
    start: Instant,
    last_size: Option<Vec2>,
    glass: bool,
    /// Snapshot mode: (output path, forced open amount 0..1, frames drawn).
    snapshot: Option<(String, f32, u32)>,
}

impl Overlay {
    fn base(state: &str) -> Color32 {
        match state {
            "working" => Color32::from_rgb(96, 165, 250),
            "done" => Color32::from_rgb(52, 211, 153),
            "error" => Color32::from_rgb(248, 113, 113),
            "attention" => Color32::from_rgb(251, 191, 36),
            _ => Color32::from_rgb(120, 120, 130),
        }
    }

    /// Draws one session mark. Shape and motion differ by state, not just colour:
    /// working = dim track with a light sweeping down it, done = solid,
    /// error = solid with a dark notch, attention = full-height and breathing,
    /// idle = short and faint.
    fn draw(&self, p: &egui::Painter, rect: egui::Rect, state: &str) {
        let t = self.start.elapsed().as_secs_f32();
        let c = Self::base(state);
        let r = MARK_W / 2.0;
        match state {
            "working" => {
                p.rect_filled(rect, r, c.gamma_multiply(0.28));
                let phase = (t / 1.2).fract();
                let h = MARK_H * 0.45;
                let y = rect.top() - h + phase * (MARK_H + h);
                let seg = egui::Rect::from_min_max(
                    Pos2::new(rect.left(), y.max(rect.top())),
                    Pos2::new(rect.right(), (y + h).min(rect.bottom())),
                );
                if seg.height() > 0.5 {
                    p.rect_filled(seg, r, c);
                }
            }
            "done" => {
                p.rect_filled(rect, r, c);
            }
            "error" => {
                p.rect_filled(rect, r, c);
                let mid = rect.center().y;
                let notch = egui::Rect::from_min_max(Pos2::new(rect.left(), mid - 1.0), Pos2::new(rect.right(), mid + 1.0));
                p.rect_filled(notch, 0.0, Color32::from_black_alpha(170));
            }
            "attention" => {
                let a = 0.55 + 0.45 * (0.5 + 0.5 * (t * std::f32::consts::TAU / 0.9).cos());
                p.rect_filled(rect.expand(1.5), r + 1.5, c.gamma_multiply(0.25 * a));
                p.rect_filled(rect, r, c.gamma_multiply(a));
            }
            _ => {
                let short = egui::Rect::from_center_size(rect.center(), Vec2::new(MARK_W, MARK_H * 0.4));
                p.rect_filled(short, r, c.gamma_multiply(0.45));
            }
        }
    }

    fn click(&self, id: &str) {
        let mut list = self.sessions.lock().unwrap();
        let Some(i) = list.iter().position(|s| s.id == id) else { return };
        if let Some(app) = &list[i].app {
            if cfg!(target_os = "macos") {
                let _ = Command::new("open").args(["-a", app]).spawn();
            }
        }
        // Clicking acknowledges a finished or failed session.
        if matches!(list[i].state.as_str(), "done" | "error") {
            list.remove(i);
        }
    }
}

impl Overlay {
    /// In snapshot mode: wait for layout to settle, grab the frame, composite it over a
    /// desktop-like backdrop (the real blur isn't in the GL buffer), write a PNG, exit.
    fn snap(&mut self, ctx: &egui::Context) {
        let Some((path, _, frames)) = &mut self.snapshot else { return };
        *frames += 1;
        if *frames == 12 {
            ctx.send_viewport_cmd(egui::ViewportCommand::Screenshot(Default::default()));
        }
        let shot = ctx.input(|i| i.raw.events.iter().find_map(|e| match e {
            egui::Event::Screenshot { image, .. } => Some(image.clone()),
            _ => None,
        }));
        let Some(img) = shot else { return };
        let [w, h] = img.size;
        let (bw, bh, m) = (w + 80, h + 80, 40);
        let mut out = vec![0u8; bw * bh * 3];
        for y in 0..bh {
            for x in 0..bw {
                // stand-in for the blurred desktop behind the glass
                let g = (34.0 + 18.0 * (x as f32 / bw as f32) + 10.0 * (y as f32 / bh as f32)) as u8;
                let mut px = [g, g + 2, g + 6];
                if (m..m + w).contains(&x) && (m..m + h).contains(&y) {
                    let c = img.pixels[(y - m) * w + (x - m)];
                    let a = c.a() as f32 / 255.0;
                    // egui pixels are premultiplied
                    for (k, v) in [c.r(), c.g(), c.b()].into_iter().enumerate() {
                        px[k] = (v as f32 + px[k] as f32 * (1.0 - a)).min(255.0) as u8;
                    }
                }
                out[(y * bw + x) * 3..][..3].copy_from_slice(&px);
            }
        }
        let file = std::fs::File::create(&*path).expect("snapshot path");
        let mut enc = png::Encoder::new(std::io::BufWriter::new(file), bw as u32, bh as u32);
        enc.set_color(png::ColorType::Rgb);
        enc.write_header().unwrap().write_image_data(&out).unwrap();
        println!("wrote {path} ({bw}x{bh})");
        std::process::exit(0);
    }
}

impl eframe::App for Overlay {
    fn clear_color(&self, _: &egui::Visuals) -> [f32; 4] {
        [0.0; 4]
    }

    fn update(&mut self, ctx: &egui::Context, frame: &mut eframe::Frame) {
        if !self.glass {
            self.glass = true;
            apply_glass(frame);
        }
        let list: Vec<Session> = {
            let mut l = self.sessions.lock().unwrap();
            l.retain(|s| s.updated.elapsed() < STALE);
            l.clone()
        };

        // Hover slides the rail open into a glass panel. Spring-ish ease-out.
        let hovering = ctx.input(|i| i.pointer.hover_pos().is_some());
        let mut open = ctx.animate_bool_with_time(egui::Id::new("open"), hovering, 0.28);
        if let Some((_, forced, _)) = &self.snapshot {
            open = *forced;
        }
        let e = if hovering { 1.0 - (1.0 - open).powi(4) } else { open * open * (3.0 - 2.0 * open) };
        let lerp = |a: f32, b: f32| a + (b - a) * e;

        let n = list.len().max(1) as f32;
        let row_h = lerp(MARK_H + GAP, OPEN_ROW_H);
        let pad = lerp(PAD + 2.0, 8.0);
        let size = Vec2::new(lerp(RAIL_W + 4.0, PANEL_W), pad * 2.0 + n * row_h).round();
        if self.last_size != Some(size) {
            if let Some(monitor) = ctx.input(|i| i.viewport().monitor_size) {
                ctx.send_viewport_cmd(egui::ViewportCommand::InnerSize(size));
                ctx.send_viewport_cmd(egui::ViewportCommand::OuterPosition(Pos2::new(
                    monitor.x - size.x - 6.0,
                    monitor.y * 0.35,
                )));
                self.last_size = Some(size);
            }
        }

        let mut clicked = None;
        egui::CentralPanel::default().frame(egui::Frame::NONE).show(ctx, |ui| {
            let area = ui.max_rect();
            let p = ui.painter().clone();
            let radius = lerp((RAIL_W + 4.0) / 2.0, 14.0);
            set_glass_radius(radius);
            // Glass: the system blur sits behind; tint it slightly and add a crisp
            // hairline plus a brighter top edge, like a sheet of glass catching light.
            p.rect_filled(area, radius, Color32::from_rgba_unmultiplied(20, 20, 26, lerp(70.0, 95.0) as u8));
            p.rect_stroke(area.shrink(0.5), radius, egui::Stroke::new(1.0_f32, Color32::from_white_alpha(38)), egui::StrokeKind::Inside);
            // light catching the top edge: a short inner highlight that fades toward the ends
            let inset = radius.max(6.0) + 2.0;
            let steps = 24;
            for k in 0..steps {
                let t0 = k as f32 / steps as f32;
                let x0 = area.left() + inset + t0 * (area.width() - 2.0 * inset);
                let x1 = x0 + (area.width() - 2.0 * inset) / steps as f32;
                let fade = 1.0 - (2.0 * t0 - 1.0).abs().powi(2);
                p.hline(x0..=x1, area.top() + 1.0, egui::Stroke::new(1.0_f32, Color32::from_white_alpha((40.0 * fade) as u8)));
            }

            let mark_x = area.right() - pad - MARK_W + lerp(2.0, -2.0);
            for (i, s) in list.iter().enumerate() {
                let top = pad + i as f32 * row_h;
                let row = egui::Rect::from_min_size(Pos2::new(area.left() + 4.0, top), Vec2::new(area.width() - 8.0, row_h));
                let resp = ui.allocate_rect(row, Sense::click());
                if resp.hovered() && e > 0.6 {
                    p.rect_filled(row.shrink2(Vec2::new(2.0, 1.5)), 9.0, Color32::from_white_alpha(14));
                }
                let mh = lerp(MARK_H, MARK_H + 6.0);
                let mark = egui::Rect::from_min_size(Pos2::new(mark_x, row.center().y - mh / 2.0), Vec2::new(MARK_W, mh));
                self.draw(&p, mark, &s.state);

                // Two-line row: title, then state · time · app. Slides in from the rail.
                let alpha = ((e - 0.35) / 0.65).clamp(0.0, 1.0);
                if alpha > 0.0 {
                    let left = area.left() + 14.0 + (1.0 - alpha) * 14.0;
                    let width = (mark_x - 12.0 - left).max(10.0);
                    // "OpenCode · Fix the build" -> title "Fix the build", tool "OpenCode"
                    let (tool, name) = s.label.split_once(" · ").unwrap_or(("", &s.label));
                    let title = elided(ui, name, 12.5, Color32::from_white_alpha((235.0 * alpha) as u8), width);
                    let dim = Color32::from_white_alpha((120.0 * alpha) as u8);
                    let fmt = |c| egui::TextFormat::simple(egui::FontId::proportional(10.5), c);
                    let mut job = egui::text::LayoutJob::default();
                    job.append(state_name(&s.state), 0.0, fmt(Self::base(&s.state).gamma_multiply(alpha)));
                    let mut rest = format!("  ·  {}", ago(s.since.elapsed()));
                    match (tool, &s.app) {
                        ("", Some(app)) => rest.push_str(&format!("  ·  {app}")),
                        (t, Some(app)) if t == app => rest.push_str(&format!("  ·  {t} app")),
                        (t, Some(app)) => rest.push_str(&format!("  ·  {t} in {}", app.trim_end_matches(" (Beta)"))),
                        (t, None) if !t.is_empty() => rest.push_str(&format!("  ·  {t}")),
                        _ => {}
                    }
                    job.append(&rest, 0.0, fmt(dim));
                    job.wrap = egui::text::TextWrapping { max_width: width, max_rows: 1, break_anywhere: true, overflow_character: Some('…') };
                    let meta = ui.fonts_mut(|f| f.layout_job(job));
                    let block = title.size().y + 2.0 + meta.size().y;
                    let y = row.center().y - block / 2.0;
                    p.galley(Pos2::new(left, y), title.clone(), Color32::WHITE);
                    p.galley(Pos2::new(left, y + title.size().y + 2.0), meta, Color32::WHITE);
                }
                if i + 1 < list.len() && e > 0.5 {
                    let y = row.bottom();
                    p.hline(area.left() + 14.0..=area.right() - 14.0, y, egui::Stroke::new(1.0_f32, Color32::from_white_alpha((14.0 * e) as u8)));
                }
                if resp.clicked() {
                    clicked = Some(s.id.clone());
                }
            }
        });
        if let Some(id) = clicked {
            self.click(&id);
        }

        self.snap(ctx);
        let animating = self.snapshot.is_some() || open > 0.0 && open < 1.0 || list.iter().any(|s| matches!(s.state.as_str(), "working" | "attention"));
        ctx.request_repaint_after(Duration::from_millis(if animating { 16 } else { 1000 }));
    }
}

fn state_name(s: &str) -> &str {
    match s {
        "working" => "Working",
        "done" => "Done",
        "error" => "Failed",
        "attention" => "Needs you",
        _ => "Idle",
    }
}

fn elided(ui: &egui::Ui, text: &str, size: f32, color: Color32, width: f32) -> Arc<egui::Galley> {
    let mut job = egui::text::LayoutJob::single_section(text.to_owned(), egui::TextFormat::simple(egui::FontId::proportional(size), color));
    job.wrap = egui::text::TextWrapping { max_width: width, max_rows: 1, break_anywhere: true, overflow_character: Some('…') };
    ui.fonts_mut(|f| f.layout_job(job))
}

/// Puts a real macOS blur (NSVisualEffectView) *behind* egui's GL view, by adding
/// it to the content view's superview below the content view.
#[cfg(target_os = "macos")]
fn apply_glass(frame: &eframe::Frame) {
    use objc2_app_kit::{NSAutoresizingMaskOptions, NSView, NSVisualEffectBlendingMode, NSVisualEffectMaterial, NSVisualEffectState, NSVisualEffectView, NSWindowOrderingMode};
    use raw_window_handle::{HasWindowHandle, RawWindowHandle};
    let Ok(h) = frame.window_handle() else { return };
    let RawWindowHandle::AppKit(h) = h.as_raw() else { return };
    let mtm = objc2::MainThreadMarker::new().unwrap();
    unsafe {
        let view: &NSView = h.ns_view.cast().as_ref();
        let Some(parent) = view.superview() else { return };
        let fx = NSVisualEffectView::initWithFrame(mtm.alloc(), parent.bounds());
        fx.setMaterial(NSVisualEffectMaterial::HUDWindow);
        fx.setBlendingMode(NSVisualEffectBlendingMode::BehindWindow);
        fx.setState(NSVisualEffectState::Active);
        fx.setAutoresizingMask(NSAutoresizingMaskOptions::ViewWidthSizable | NSAutoresizingMaskOptions::ViewHeightSizable);
        fx.setWantsLayer(true);
        if let Some(layer) = fx.layer() {
            layer.setCornerRadius(GLASS_RADIUS);
            layer.setMasksToBounds(true);
        }
        parent.addSubview_positioned_relativeTo(&fx, NSWindowOrderingMode::Below, Some(view));
        *GLASS.lock().unwrap() = Some(objc2::rc::Retained::into_raw(fx) as usize);
    }
}

/// Keeps the blur's rounded corners in step with the panel as it slides open.
#[cfg(target_os = "macos")]
fn set_glass_radius(r: f32) {
    let Some(ptr) = *GLASS.lock().unwrap() else { return };
    unsafe {
        let fx = &*(ptr as *const objc2_app_kit::NSVisualEffectView);
        if let Some(layer) = fx.layer() {
            layer.setCornerRadius(r as f64);
        }
    }
}
#[cfg(not(target_os = "macos"))]
fn set_glass_radius(_: f32) {}

#[cfg(target_os = "macos")]
static GLASS: Mutex<Option<usize>> = Mutex::new(None);
#[cfg(target_os = "macos")]
const GLASS_RADIUS: f64 = 8.0;

#[cfg(not(target_os = "macos"))]
fn apply_glass(_: &eframe::Frame) {}

fn system_font(ctx: &egui::Context) {
    let Ok(bytes) = std::fs::read("/System/Library/Fonts/SFNS.ttf") else { return };
    let mut fonts = egui::FontDefinitions::default();
    fonts.font_data.insert("sf".into(), Arc::new(egui::FontData::from_owned(bytes)));
    fonts.families.get_mut(&egui::FontFamily::Proportional).unwrap().insert(0, "sf".into());
    ctx.set_fonts(fonts);
}

fn ago(d: Duration) -> String {
    let s = d.as_secs();
    match s {
        0..=59 => format!("{s}s"),
        60..=3599 => format!("{}m", s / 60),
        _ => format!("{}h {}m", s / 3600, s / 60 % 60),
    }
}

fn run_overlay(snapshot: Option<(String, f32, u32)>) -> eframe::Result {
    let sessions: Shared = Arc::default();
    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_title("agent-dots")
            .with_decorations(false)
            .with_transparent(true)
            .with_resizable(false)
            .with_always_on_top()
            .with_taskbar(false)
            .with_has_shadow(false)
            .with_inner_size([RAIL_W, PAD * 2.0 + MARK_H]),
        ..Default::default()
    };
    eframe::run_native(
        "agent-dots",
        options,
        Box::new(move |cc| {
            let (s, ctx) = (sessions.clone(), cc.egui_ctx.clone());
            if snapshot.is_none() {
                std::thread::spawn(move || serve(s, ctx));
            } else {
                for (id, state, label, app) in [
                    ("a", "working", "OpenCode · Agent Notification Sounds and Overlay Status Indicator Ideas", Some("T3 Code (Beta)")),
                    ("b", "done", "Claude · token-tracker", Some("Terminal")),
                    ("c", "attention", "OpenCode · Experiment Design: Proximal vs. Distal Control", Some("T3 Code (Beta)")),
                    ("d", "error", "Claude · personal-website", Some("Claude")),
                ] {
                    apply(&s, Event { session: id.into(), state: state.into(), label: Some(label.into()), app: app.map(String::from) });
                }
            }
            system_font(&cc.egui_ctx);
            Ok(Box::new(Overlay { sessions, start: Instant::now(), last_size: None, glass: false, snapshot }))
        }),
    )
}

// ---- hook side: tiny client, never fails loudly so a missing overlay can't break an agent ----

fn send(ev: &Event) {
    let Ok(body) = serde_json::to_string(ev) else { return };
    let addr = ("127.0.0.1", port());
    let Ok(mut stream) = std::net::ToSocketAddrs::to_socket_addrs(&addr)
        .ok()
        .and_then(|mut a| a.next())
        .ok_or(())
        .and_then(|a| TcpStream::connect_timeout(&a, Duration::from_millis(300)).map_err(|_| ()))
    else {
        return;
    };
    let _ = stream.set_read_timeout(Some(Duration::from_millis(500)));
    let _ = write!(
        stream,
        "POST /event HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
        body.len(),
        body
    );
    let _ = stream.read(&mut [0u8; 64]);
}

/// Which app hosts this agent, guessed from the environment of the hook process.
fn host_app() -> Option<String> {
    let env = |k: &str| std::env::var(k).unwrap_or_default();
    let bundle = env("__CFBundleIdentifier");
    if !env("T3CODE_CLI_PATH").is_empty() || bundle.contains("t3code") {
        return Some("T3 Code (Beta)".into());
    }
    if bundle.contains("claudefordesktop") || env("CLAUDE_CODE_ENTRYPOINT").contains("desktop") {
        return Some("Claude".into());
    }
    let app = match env("TERM_PROGRAM").as_str() {
        "Apple_Terminal" => "Terminal",
        "iTerm.app" => "iTerm",
        "ghostty" => "Ghostty",
        "WezTerm" => "WezTerm",
                "vscode" => "Visual Studio Code",
        _ => return None,
    };
    Some(app.into())
}

fn dir_name(v: &Value) -> String {
    v["cwd"].as_str().and_then(|c| Path::new(c).file_name()?.to_str().map(String::from)).unwrap_or_default()
}

fn hook(kind: &str, rest: &[String]) {
    let ev = match kind {
        "claude" => {
            let mut s = String::new();
            let _ = std::io::stdin().read_to_string(&mut s);
            let p: Value = serde_json::from_str(&s).unwrap_or_default();
            let state = match p["hook_event_name"].as_str().unwrap_or("") {
                "UserPromptSubmit" | "PreToolUse" | "PostToolUse" => "working",
                "Notification" | "PermissionRequest" => "attention",
                "Stop" => "done",
                "StopFailure" => "error",
                "SessionEnd" => "idle",
                _ => return,
            };
            Event {
                session: format!("claude:{}", p["session_id"].as_str().unwrap_or("?")),
                state: state.into(),
                label: Some(format!("Claude · {}", dir_name(&p))),
                app: host_app(),
            }
        }
        "codex" => {
            let p: Value = rest.last().and_then(|s| serde_json::from_str(s).ok()).unwrap_or_default();
            if p["type"] != "agent-turn-complete" {
                return;
            }
            let id = p["thread-id"].as_str().or(p["turn-id"].as_str()).unwrap_or("?");
            Event {
                session: format!("codex:{id}"),
                state: "done".into(),
                label: Some(format!("Codex · {}", dir_name(&p))),
                app: host_app(),
            }
        }
        _ => return,
    };
    send(&ev);
}

fn demo() {
    let ev = |s: &str, st: &str, app: Option<&str>| Event {
        session: s.into(),
        state: st.into(),
        label: Some(s.into()),
        app: app.map(String::from),
    };
    let wait = |ms| std::thread::sleep(Duration::from_millis(ms));
    send(&ev("demo-1", "working", Some("Terminal")));
    send(&ev("demo-2", "working", Some("Finder")));
    send(&ev("demo-3", "working", None));
    wait(2000);
    send(&ev("demo-1", "done", None));
    wait(1500);
    send(&ev("demo-2", "attention", None));
    wait(1500);
    send(&ev("demo-3", "error", None));
    println!("Demo sent. Click a dot to open its app; done/error dots clear on click.");
}

fn main() -> eframe::Result {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        None => run_overlay(None),
        Some("snapshot") => {
            unsafe { std::env::set_var("AGENT_DOTS_MUTE", "1") };
            let path = args.get(1).cloned().unwrap_or_else(|| "snapshot.png".into());
            let open = args.get(2).and_then(|v| v.parse().ok()).unwrap_or(1.0);
            run_overlay(Some((path, open, 0)))
        }
        Some("hook") => {
            hook(args.get(1).map_or("", |s| s), &args[2..]);
            Ok(())
        }
        Some("set") if args.len() >= 3 => {
            send(&Event {
                session: args[1].clone(),
                state: args[2].clone(),
                label: args.get(3).cloned(),
                app: args.get(4).cloned().or_else(host_app),
            });
            Ok(())
        }
        Some("demo") => {
            demo();
            Ok(())
        }
        _ => {
            eprintln!("usage: agent-dots [hook claude|hook codex <json>|set <session> <state> [label] [app]|demo]");
            std::process::exit(2);
        }
    }
}
