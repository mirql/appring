//! Tiny iced + iced_layershell POC of the "ring": starts hidden, `ring-iced
//! show`/`hide` toggles a transparent wlr-layer-shell overlay with six
//! rounded-square buttons on a circle, the one in the pointer's direction
//! glowing, a centre dot.
//!
//! "Hidden" is a single persistent layer surface shrunk to 1x1px, parked
//! off-screen (a large negative margin) with no keyboard interactivity --
//! iced_layershell (single-window mode) has no `hide()`/`show()` of its
//! own, only `AnchorSizeChange`/`MarginChange`/`KeyboardInteractivityChange`
//! actions (see its `to_layer_message` macro output), so this is the
//! smallest robust way to express "not visible" with the API it offers.

use futures::channel::mpsc;
use iced::keyboard;
use iced::mouse;
use iced::widget::canvas::{self, Canvas, Path, Stroke, Text};
use iced::{Color, Element, Event, Length, Point, Rectangle, Renderer, Subscription, Task, Theme};
use iced_layershell::application;
use iced_layershell::reexport::{Anchor, KeyboardInteractivity};
use iced_layershell::settings::{LayerShellSettings, Settings, StartMode};
use iced_layershell::to_layer_message;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, OnceLock};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

const RING_W: u32 = 420;
const RING_H: u32 = 420;
const RADIUS: f32 = 140.0;
const SQUARE: f32 = 72.0;
const LABELS: [&str; 6] = ["Term", "Files", "Web", "Mail", "Notes", "Lock"];

fn now_nanos() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos() as u64
}

fn socket_path() -> PathBuf {
    let dir = std::env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| "/tmp".to_string());
    PathBuf::from(dir).join("appring-spike-iced.sock")
}

fn hyprctl_bin() -> String {
    std::env::var("MIRQL_RING_HYPRCTL").unwrap_or_else(|_| "hyprctl".to_string())
}

/// Cursor position and the focused monitor's origin, both in Hyprland's
/// global logical-pixel space; see the egui spike's twin of this function
/// for the fallback behaviour and why.
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

// ---------------------------------------------------------------- client --

enum Cmd {
    Show,
    Hide,
}

fn client_run(cmd: Cmd) {
    let path = socket_path();
    let stream = match UnixStream::connect(&path) {
        Ok(s) => s,
        Err(_) if matches!(cmd, Cmd::Hide) => {
            eprintln!("ring-iced: not running ({})", path.display());
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
                    eprintln!("ring-iced: daemon did not start in time");
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

// ----------------------------------------------------------------- IPC ---

/// Everything the socket-accepting threads need to hand a request to the
/// running app and wait for its ack. The app -> socket direction goes
/// through a `futures` mpsc sender (into iced's subscription); the ack
/// comes back through these atomics, the same shape as the egui spike.
struct Shared {
    generation: AtomicU64,
    ack_generation: AtomicU64,
    ack_nanos: AtomicU64,
}

static SHARED: OnceLock<Arc<Shared>> = OnceLock::new();

fn shared() -> &'static Arc<Shared> {
    SHARED.get_or_init(|| {
        Arc::new(Shared {
            generation: AtomicU64::new(0),
            ack_generation: AtomicU64::new(0),
            ack_nanos: AtomicU64::new(0),
        })
    })
}

fn accept_loop(output: mpsc::Sender<Message>) {
    let path = socket_path();
    if path.exists() {
        if UnixStream::connect(&path).is_err() {
            let _ = std::fs::remove_file(&path);
        } else {
            eprintln!("ring-iced: already running ({})", path.display());
            std::process::exit(1);
        }
    }
    let listener = UnixListener::bind(&path).expect("bind socket");
    for conn in listener.incoming().flatten() {
        let output = output.clone();
        std::thread::spawn(move || handle_conn(conn, output));
    }
}

fn handle_conn(mut conn: UnixStream, mut output: mpsc::Sender<Message>) {
    let mut reader = BufReader::new(conn.try_clone().expect("clone stream"));
    let mut line = String::new();
    if reader.read_line(&mut line).unwrap_or(0) == 0 {
        return;
    }
    match line.trim() {
        "show" => {
            let t_recv = now_nanos();
            let (cursor, mon_origin) = cursor_and_focused_monitor_origin();
            let local_x = (cursor.0 - mon_origin.0) - (RING_W as i32) / 2;
            let local_y = (cursor.1 - mon_origin.1) - (RING_H as i32) / 2;
            let shared = shared();
            let my_gen = shared.generation.fetch_add(1, Ordering::SeqCst) + 1;
            let _ = output.try_send(Message::ShowAt {
                top: local_y,
                left: local_x,
                gen: my_gen,
            });
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
            let shared = shared();
            shared.generation.fetch_add(1, Ordering::SeqCst);
            let _ = output.try_send(Message::HideRequested);
            let _ = writeln!(conn, "hidden");
        }
        other => {
            let _ = writeln!(conn, "unknown command {other:?}");
        }
    }
}

// --------------------------------------------------------------- iced ----

#[to_layer_message]
#[derive(Debug, Clone)]
enum Message {
    IcedEvent(Event),
    ShowAt { top: i32, left: i32, gen: u64 },
    HideRequested,
}

#[derive(Default)]
struct Ring {
    visible: bool,
}

fn namespace() -> String {
    "appring-spike-iced".to_string()
}

fn hide_tasks() -> Task<Message> {
    Task::batch([
        Task::done(Message::KeyboardInteractivityChange(KeyboardInteractivity::None)),
        Task::done(Message::AnchorSizeChange(Anchor::Top | Anchor::Left, (1, 1))),
        Task::done(Message::MarginChange((-10_000, -10_000, 0, 0))),
    ])
}

fn update(ring: &mut Ring, message: Message) -> Task<Message> {
    match message {
        Message::ShowAt { top, left, gen } => {
            ring.visible = true;
            let shared = shared();
            shared.ack_nanos.store(now_nanos(), Ordering::SeqCst);
            shared.ack_generation.store(gen, Ordering::SeqCst);
            Task::batch([
                Task::done(Message::AnchorSizeChange(Anchor::Top | Anchor::Left, (RING_W, RING_H))),
                Task::done(Message::MarginChange((top, left, 0, 0))),
                Task::done(Message::KeyboardInteractivityChange(KeyboardInteractivity::Exclusive)),
            ])
        }
        Message::HideRequested => {
            ring.visible = false;
            hide_tasks()
        }
        Message::IcedEvent(Event::Keyboard(keyboard::Event::KeyPressed {
            key: keyboard::Key::Named(keyboard::key::Named::Escape),
            ..
        })) if ring.visible => {
            ring.visible = false;
            hide_tasks()
        }
        Message::IcedEvent(Event::Mouse(mouse::Event::ButtonPressed(_))) if ring.visible => {
            ring.visible = false;
            hide_tasks()
        }
        Message::IcedEvent(_) => Task::none(),
        // Layer-shell action messages are intercepted by the
        // iced_layershell runtime before reaching here; this arm only
        // exists to keep the match exhaustive.
        _ => Task::none(),
    }
}

fn view(_ring: &Ring) -> Element<'_, Message> {
    Canvas::new(RingCanvas).width(Length::Fill).height(Length::Fill).into()
}

fn subscription(_ring: &Ring) -> Subscription<Message> {
    Subscription::run(ipc_worker)
}

fn ipc_worker() -> impl futures::Stream<Item = Message> {
    iced::stream::channel(64, |output| async move {
        std::thread::spawn(move || accept_loop(output));
        std::future::pending::<()>().await
    })
}

fn style(_ring: &Ring, theme: &Theme) -> iced::theme::Style {
    use iced::theme::Style;
    Style {
        background_color: Color::TRANSPARENT,
        text_color: theme.palette().text,
    }
}

struct RingCanvas;

impl<Message> canvas::Program<Message> for RingCanvas {
    type State = ();

    fn draw(
        &self,
        _state: &Self::State,
        renderer: &Renderer,
        _theme: &Theme,
        bounds: Rectangle,
        cursor: mouse::Cursor,
    ) -> Vec<canvas::Geometry> {
        let mut frame = canvas::Frame::new(renderer, bounds.size());
        let center = Point::new(bounds.width / 2.0, bounds.height / 2.0);
        let pointer = cursor.position_in(bounds).unwrap_or(center);
        let pointer_angle = (pointer.y - center.y).atan2(pointer.x - center.x);

        let slot_angle = |i: usize| -> f32 {
            -std::f32::consts::FRAC_PI_2 + (i as f32) * std::f32::consts::TAU / 6.0
        };
        let mut nearest = 0usize;
        let mut best = f32::MAX;
        for i in 0..6 {
            let d = angular_distance(slot_angle(i), pointer_angle);
            if d < best {
                best = d;
                nearest = i;
            }
        }

        for (i, label) in LABELS.iter().enumerate() {
            let a = slot_angle(i);
            let pos = Point::new(center.x + RADIUS * a.cos(), center.y + RADIUS * a.sin());
            let highlighted = i == nearest;
            if highlighted {
                let glow = Path::rounded_rectangle(
                    Point::new(pos.x - SQUARE / 2.0 - 12.0, pos.y - SQUARE / 2.0 - 12.0),
                    iced::Size::new(SQUARE + 24.0, SQUARE + 24.0),
                    14.0.into(),
                );
                frame.fill(&glow, Color::from_rgba(0.47, 0.67, 1.0, 0.27));
            }
            let rect = Path::rounded_rectangle(
                Point::new(pos.x - SQUARE / 2.0, pos.y - SQUARE / 2.0),
                iced::Size::new(SQUARE, SQUARE),
                10.0.into(),
            );
            let fill = if highlighted {
                Color::from_rgb(0.35, 0.55, 0.90)
            } else {
                Color::from_rgba(0.16, 0.17, 0.22, 0.92)
            };
            frame.fill(&rect, fill);
            frame.stroke(
                &rect,
                Stroke::default()
                    .with_width(1.5)
                    .with_color(Color::from_rgba(1.0, 1.0, 1.0, 0.24)),
            );
            frame.fill_text(Text {
                content: label.to_string(),
                position: pos,
                color: Color::WHITE,
                size: iced::Pixels(14.0),
                horizontal_alignment: iced::alignment::Horizontal::Center,
                vertical_alignment: iced::alignment::Vertical::Center,
                ..Text::default()
            });
        }

        let dot = Path::circle(center, 4.0);
        frame.fill(&dot, Color::from_rgba(1.0, 1.0, 1.0, 0.8));

        vec![frame.into_geometry()]
    }
}

fn angular_distance(a: f32, b: f32) -> f32 {
    let two_pi = std::f32::consts::TAU;
    let mut d = (a - b).abs() % two_pi;
    if d > std::f32::consts::PI {
        d = two_pi - d;
    }
    d
}

fn run_daemon() -> iced_layershell::Result {
    application(Ring::default, update, view)
        .subscription(subscription)
        .style(style)
        .settings(Settings {
            layer_settings: LayerShellSettings {
                size: Some((1, 1)),
                anchor: Anchor::Top | Anchor::Left,
                exclusive_zone: 0,
                margin: (-10_000, -10_000, 0, 0),
                keyboard_interactivity: KeyboardInteractivity::None,
                start_mode: StartMode::Active,
                ..Default::default()
            },
            ..Default::default()
        })
        .run()
}

fn main() -> iced_layershell::Result {
    let args: Vec<String> = std::env::args().collect();
    match args.get(1).map(String::as_str) {
        Some("show") => {
            client_run(Cmd::Show);
            return Ok(());
        }
        Some("hide") => {
            client_run(Cmd::Hide);
            return Ok(());
        }
        None => {}
        Some(other) => {
            eprintln!("usage: {} [show|hide]  (bare: run as the hidden daemon)", args[0]);
            eprintln!("unknown argument: {other}");
            std::process::exit(2);
        }
    }
    run_daemon()
}
