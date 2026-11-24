//! Tiny egui POC of the "ring": starts hidden, `ring-egui show`/`hide`
//! toggles a transparent overlay with six rounded-square buttons on a
//! circle, the one in the pointer's direction glowing, a centre dot.
//!
//! Honest limitation: this is **not** on
//! Wayland layer-shell. egui/eframe has no built-in layer-shell support
//! (unlike iced_layershell or Qt+LayerShellQt), and hand-rolling one with
//! smithay-client-toolkit (raw Wayland client, EGL context, feeding
//! egui::RawInput by hand) was out of this spike's time budget. So this is
//! a plain undecorated eframe/winit window instead, and two things that
//! follow from that are also honestly broken, not just "less polished":
//! - **No real always-on-top.** `ViewportCommand::WindowLevel(AlwaysOnTop)`
//!   is sent, but xdg-toplevel (a normal Wayland window) has no
//!   compositor-enforced stacking hint; Hyprland would need a window rule
//!   (`windowrulev2 = stayfocused`/`pin`) to approximate it, not something
//!   to set up from an off-screen spike.
//! - **No real cursor-centring.** `ViewportCommand::OuterPosition` is sent
//!   with the computed cursor position, but xdg-toplevel gives clients no
//!   positioning authority at all (by Wayland design); the compositor is
//!   free to ignore it, and wlroots compositors do. This is, concretely,
//!   the reason the ring wants layer-shell in the first place.
//! See spikes/rust-ui/README.md for the measured numbers and how this
//! compares to the other two toolkits.

use eframe::egui;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::process::Command;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

const RING_W: f32 = 420.0;
const RING_H: f32 = 420.0;
const RADIUS: f32 = 140.0;
const SQUARE: f32 = 72.0;
const LABELS: [&str; 6] = ["Term", "Files", "Web", "Mail", "Notes", "Lock"];

fn now_nanos() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos() as u64
}

fn socket_path() -> PathBuf {
    let dir = std::env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| "/tmp".to_string());
    PathBuf::from(dir).join("appring-spike-egui.sock")
}

fn hyprctl_bin() -> String {
    std::env::var("MIRQL_RING_HYPRCTL").unwrap_or_else(|_| "hyprctl".to_string())
}

/// The cursor's position and the focused monitor's origin, both in
/// Hyprland's global logical-pixel space. Best-effort: any failure (no
/// Hyprland, no `jq`-free JSON we understand, …) falls back to (0,0) for
/// both, which puts the window at the top-left of the first monitor
/// instead of at the pointer -- better than crashing.
fn cursor_and_focused_monitor_origin() -> ((i32, i32), (i32, i32)) {
    let hyprctl = hyprctl_bin();
    let cursor = Command::new(&hyprctl)
        .arg("cursorpos")
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .and_then(|s| {
            let mut it = s.trim().split(',').map(|p| p.trim().parse::<i32>());
            match (it.next(), it.next()) {
                (Some(Ok(x)), Some(Ok(y))) => Some((x, y)),
                _ => None,
            }
        })
        .unwrap_or((0, 0));
    let mon_origin = Command::new(&hyprctl)
        .args(["monitors", "-j"])
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .and_then(|s| serde_json::from_str::<serde_json::Value>(&s).ok())
        .and_then(|v| {
            let arr = v.as_array()?.clone();
            let mon = arr
                .iter()
                .find(|m| m.get("focused").and_then(|f| f.as_bool()).unwrap_or(false))
                .or_else(|| arr.first())?;
            Some((mon.get("x")?.as_i64()? as i32, mon.get("y")?.as_i64()? as i32))
        })
        .unwrap_or((0, 0));
    (cursor, mon_origin)
}

enum Cmd {
    Show,
    Hide,
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    match args.get(1).map(|s| s.as_str()) {
        Some("show") => client_run(Cmd::Show),
        Some("hide") => client_run(Cmd::Hide),
        None => daemon_run(),
        Some(other) => {
            eprintln!("usage: {} [show|hide]  (bare: run as the hidden daemon)", args[0]);
            eprintln!("unknown argument: {other}");
            std::process::exit(2);
        }
    }
}

/// `show`/`hide`: talk to the running daemon over its Unix socket, or (for
/// `show`, with nobody listening) start it ourselves -- and retry.
fn client_run(cmd: Cmd) {
    let path = socket_path();
    let stream = match UnixStream::connect(&path) {
        Ok(s) => s,
        Err(_) if matches!(cmd, Cmd::Hide) => {
            eprintln!("ring-egui: not running ({})", path.display());
            std::process::exit(1);
        }
        Err(_) => {
            let exe = std::env::current_exe().expect("current_exe");
            let _ = Command::new(exe)
                .stdin(std::process::Stdio::null())
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null())
                .spawn();
            let mut found = None;
            for _ in 0..200 {
                if let Ok(s) = UnixStream::connect(&path) {
                    found = Some(s);
                    break;
                }
                std::thread::sleep(Duration::from_millis(25));
            }
            match found {
                Some(s) => s,
                None => {
                    eprintln!("ring-egui: daemon did not start in time");
                    std::process::exit(1);
                }
            }
        }
    };
    let word = match cmd {
        Cmd::Show => "show",
        Cmd::Hide => "hide",
    };
    let mut stream = stream;
    stream.write_all(format!("{word}\n").as_bytes()).expect("write");
    let mut reader = BufReader::new(stream);
    let mut line = String::new();
    let _ = reader.read_line(&mut line);
    let line = line.trim();
    if let Cmd::Show = cmd {
        if let Some(ms) = line.strip_prefix("shown ") {
            println!("show-to-first-frame: {ms} ms");
        } else {
            println!("show-to-first-frame: unknown (daemon said {line:?})");
        }
    }
}

/// Shared between the socket-accepting threads and the egui `update()`
/// loop. `generation` is bumped on every request (show, hide, or a local
/// Esc/click); `update()` notices the bump and acts, then -- on the frame
/// right after a show takes effect -- stamps `ack_nanos` so the thread
/// still blocked on that connection can reply with the elapsed time.
struct Shared {
    want_visible: AtomicBool,
    generation: AtomicU64,
    pending_origin: Mutex<Option<(f32, f32)>>,
    show_received_nanos: AtomicU64,
    ack_generation: AtomicU64,
    ack_nanos: AtomicU64,
    ctx: Mutex<Option<egui::Context>>,
}

impl Shared {
    fn new() -> Self {
        Self {
            want_visible: AtomicBool::new(false),
            generation: AtomicU64::new(0),
            pending_origin: Mutex::new(None),
            show_received_nanos: AtomicU64::new(0),
            ack_generation: AtomicU64::new(0),
            ack_nanos: AtomicU64::new(0),
            ctx: Mutex::new(None),
        }
    }

    fn wake(&self) {
        if let Some(ctx) = self.ctx.lock().unwrap().as_ref() {
            ctx.request_repaint();
        }
    }
}

fn daemon_run() {
    let path = socket_path();
    if path.exists() {
        // A stale socket from a crashed previous run, or a live one: tell
        // the two apart by trying to connect before unlinking it.
        if UnixStream::connect(&path).is_err() {
            let _ = std::fs::remove_file(&path);
        } else {
            eprintln!("ring-egui: already running ({})", path.display());
            std::process::exit(1);
        }
    }
    let listener = UnixListener::bind(&path).expect("bind socket");
    let shared = Arc::new(Shared::new());

    {
        let shared = Arc::clone(&shared);
        std::thread::spawn(move || {
            for conn in listener.incoming().flatten() {
                let shared = Arc::clone(&shared);
                std::thread::spawn(move || handle_conn(conn, shared));
            }
        });
    }

    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_inner_size([RING_W, RING_H])
            .with_decorations(false)
            .with_transparent(true)
            .with_resizable(false)
            .with_visible(false)
            .with_window_level(egui::WindowLevel::AlwaysOnTop)
            .with_taskbar(false),
        ..Default::default()
    };

    eframe::run_native(
        "appring-spike-egui",
        options,
        Box::new(move |cc| {
            *shared.ctx.lock().unwrap() = Some(cc.egui_ctx.clone());
            Ok(Box::new(App {
                shared,
                last_seen_generation: 0,
                awaiting_ack_for: None,
            }))
        }),
    )
    .expect("eframe::run_native");
}

fn handle_conn(mut conn: UnixStream, shared: Arc<Shared>) {
    let mut reader = BufReader::new(conn.try_clone().expect("clone stream"));
    let mut line = String::new();
    if reader.read_line(&mut line).unwrap_or(0) == 0 {
        return;
    }
    match line.trim() {
        "show" => {
            let t_recv = now_nanos();
            let (cursor, mon_origin) = cursor_and_focused_monitor_origin();
            let local = (
                (cursor.0 - mon_origin.0) as f32 - RING_W / 2.0,
                (cursor.1 - mon_origin.1) as f32 - RING_H / 2.0,
            );
            *shared.pending_origin.lock().unwrap() = Some(local);
            shared.show_received_nanos.store(t_recv, Ordering::SeqCst);
            shared.want_visible.store(true, Ordering::SeqCst);
            let my_gen = shared.generation.fetch_add(1, Ordering::SeqCst) + 1;
            shared.wake();
            // Wait (bounded) for update() to stamp the ack for this request.
            let deadline = std::time::Instant::now() + Duration::from_secs(2);
            loop {
                if shared.ack_generation.load(Ordering::SeqCst) == my_gen {
                    let ack = shared.ack_nanos.load(Ordering::SeqCst);
                    let ms = (ack.saturating_sub(t_recv)) as f64 / 1_000_000.0;
                    let _ = writeln!(conn, "shown {ms:.1}");
                    return;
                }
                if std::time::Instant::now() > deadline {
                    let _ = writeln!(conn, "shown timeout");
                    return;
                }
                std::thread::sleep(Duration::from_millis(1));
            }
        }
        "hide" => {
            shared.want_visible.store(false, Ordering::SeqCst);
            shared.generation.fetch_add(1, Ordering::SeqCst);
            shared.wake();
            let _ = writeln!(conn, "hidden");
        }
        other => {
            let _ = writeln!(conn, "unknown command {other:?}");
        }
    }
}

struct App {
    shared: Arc<Shared>,
    last_seen_generation: u64,
    /// Set the frame we told the window to become visible; the *next*
    /// frame's start is our stand-in for "first frame after show" (eframe
    /// has no present-time callback on glow within this spike's budget).
    awaiting_ack_for: Option<u64>,
}

impl eframe::App for App {
    fn clear_color(&self, _visuals: &egui::Visuals) -> [f32; 4] {
        [0.0, 0.0, 0.0, 0.0]
    }

    fn ui(&mut self, ui: &mut egui::Ui, _frame: &mut eframe::Frame) {
        let ctx = ui.ctx().clone();
        let ctx = &ctx;
        if let Some(gen) = self.awaiting_ack_for.take() {
            self.shared.ack_nanos.store(now_nanos(), Ordering::SeqCst);
            self.shared.ack_generation.store(gen, Ordering::SeqCst);
        }

        let gen = self.shared.generation.load(Ordering::SeqCst);
        if gen != self.last_seen_generation {
            self.last_seen_generation = gen;
            if self.shared.want_visible.load(Ordering::SeqCst) {
                if let Some((x, y)) = self.shared.pending_origin.lock().unwrap().take() {
                    ctx.send_viewport_cmd(egui::ViewportCommand::OuterPosition(egui::pos2(x, y)));
                }
                ctx.send_viewport_cmd(egui::ViewportCommand::Visible(true));
                ctx.send_viewport_cmd(egui::ViewportCommand::Focus);
                self.awaiting_ack_for = Some(gen);
            } else {
                ctx.send_viewport_cmd(egui::ViewportCommand::Visible(false));
            }
        }

        // Esc or any click hides it too; still leaves
        // the daemon running for the next `show`.
        let hide_locally = ctx.input(|i| {
            i.key_pressed(egui::Key::Escape) || i.pointer.any_click()
        });
        if hide_locally && self.shared.want_visible.load(Ordering::SeqCst) {
            self.shared.want_visible.store(false, Ordering::SeqCst);
            self.shared.generation.fetch_add(1, Ordering::SeqCst);
            ctx.send_viewport_cmd(egui::ViewportCommand::Visible(false));
        }

        draw_ring(ui);

        if self.shared.want_visible.load(Ordering::SeqCst) {
            ctx.request_repaint_after(Duration::from_millis(16));
        }
    }
}

fn draw_ring(ui: &mut egui::Ui) {
    let rect = ui.max_rect();
    let center = rect.center();
    let painter = ui.painter();
    let pointer = ui.input(|i| i.pointer.latest_pos()).unwrap_or(center);
    let pointer_angle = (pointer.y - center.y).atan2(pointer.x - center.x);

    let mut nearest = 0usize;
    let mut best = f32::MAX;
    let slot_angle = |i: usize| -> f32 {
        -std::f32::consts::FRAC_PI_2 + (i as f32) * std::f32::consts::TAU / 6.0
    };
    for i in 0..6 {
        let a = slot_angle(i);
        let d = angular_distance(a, pointer_angle);
        if d < best {
            best = d;
            nearest = i;
        }
    }

    for (i, label) in LABELS.iter().enumerate() {
        let a = slot_angle(i);
        let pos = egui::pos2(center.x + RADIUS * a.cos(), center.y + RADIUS * a.sin());
        let r = egui::Rect::from_center_size(pos, egui::vec2(SQUARE, SQUARE));
        let highlighted = i == nearest;
        if highlighted {
            // A cheap glow: a larger, soft, translucent square behind it.
            let glow = egui::Rect::from_center_size(pos, egui::vec2(SQUARE + 24.0, SQUARE + 24.0));
            painter.rect_filled(glow, 14.0, egui::Color32::from_rgba_unmultiplied(120, 170, 255, 70));
        }
        let fill = if highlighted {
            egui::Color32::from_rgb(90, 140, 230)
        } else {
            egui::Color32::from_rgba_unmultiplied(40, 44, 56, 235)
        };
        painter.rect_filled(r, 10.0, fill);
        painter.rect_stroke(
            r,
            10.0,
            egui::Stroke::new(1.5, egui::Color32::from_rgba_unmultiplied(255, 255, 255, 60)),
            egui::StrokeKind::Inside,
        );
        painter.text(
            pos,
            egui::Align2::CENTER_CENTER,
            label,
            egui::FontId::proportional(14.0),
            egui::Color32::WHITE,
        );
    }

    painter.circle_filled(center, 4.0, egui::Color32::from_rgba_unmultiplied(255, 255, 255, 200));
}

fn angular_distance(a: f32, b: f32) -> f32 {
    let two_pi = std::f32::consts::TAU;
    let mut d = (a - b).abs() % two_pi;
    if d > std::f32::consts::PI {
        d = two_pi - d;
    }
    d
}
