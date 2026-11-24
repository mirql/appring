//! egui on a *real* Wayland layer-shell overlay: starts hidden, `ring-
//! eguilayershell show`/`hide` (same Unix-socket shape as the other two
//! spikes) toggles a `zwlr_layer_shell_v1` overlay surface -- no eframe,
//! no winit, on purpose -- painted with `egui-wgpu`, six
//! rounded-square buttons on a circle, the one in the pointer's direction
//! glowing, a centre disc with a small arrow, a soft localised backdrop
//! halo. Esc or a click hides it; the daemon stays running for the next
//! `show`, same convention as `egui/` and `cxx-qt/`.
//!
//! **No maintained crate already does this** (checked crates.io,
//! 2026-10-13, not assumed): `wayapp` ("A Wayland application wrapper
//! using smithay-client-toolkit, supports currently just egui using
//! wgpu") paints egui with wgpu through SCTK too, but only onto a plain
//! `xdg_toplevel` -- no layer-shell at all, the exact gap this spike
//! exists to close. `layershellev` (the `iced_layershell`-adjacent
//! "winit-like event loop with layer-shell", README.md's own egui
//! section named this the most promising path to revisit) hands back a
//! raw `wl_shm` pool buffer per frame, not a GPU surface -- pairing it
//! with `egui-wgpu` would mean building a software-rasteriser bridge
//! first anyway, no smaller than building the layer-shell part directly.
//! So: hand-built glue, on `smithay-client-toolkit` itself, reusing its own `examples/wgpu.rs` recipe for handing a
//! `wl_surface` to `wgpu` via `raw-window-handle` -- just handed a
//! `zwlr_layer_surface_v1`'s surface (`examples/simple_layer.rs`'s setup)
//! instead of an `xdg_toplevel`'s.
//!
//! Cursor-centring -- the whole reason this spike exists, see
//! README.md's egui section on why the *first* egui spike (plain
//! `xdg_toplevel`) could not actually do this -- is real here, not
//! approximated: wlr-layer-shell grants positioning authority a plain
//! top-level window never gets. Anchored `TOP | LEFT` with
//! `set_margin(top, 0, 0, left)` places the surface's corner at an exact
//! pixel offset from the focused output's origin; **no clamping** is
//! applied here, the same rule the Quickshell ring settled on.
//! `cursor_and_focused_monitor_origin()` below is the same `hyprctl`-
//! shelling helper, byte-for-byte compatible with `tools/fake-hyprctl.sh`,
//! as the other two spikes use.

use egui_wgpu::wgpu;
use raw_window_handle::{
    RawDisplayHandle, RawWindowHandle, WaylandDisplayHandle, WaylandWindowHandle,
};
use smithay_client_toolkit::{
    compositor::{CompositorHandler, CompositorState, FrameCallbackData},
    delegate_registry,
    output::{OutputHandler, OutputState},
    registry::{ProvidesRegistryState, RegistryState},
    registry_handlers,
    seat::{
        keyboard::{KeyEvent, KeyboardHandler, Keysym, Modifiers, RawModifiers},
        pointer::{PointerEvent, PointerEventKind, PointerHandler},
        Capability, SeatHandler, SeatState,
    },
    shell::{
        wlr_layer::{
            Anchor, KeyboardInteractivity, Layer, LayerShell, LayerShellHandler, LayerSurface,
            LayerSurfaceConfigure,
        },
        WaylandSurface,
    },
};
use calloop::channel::{Channel, Event as ChannelEvent, Sender};
use calloop::EventLoop;
use calloop_wayland_source::WaylandSource;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::process::Command;
use std::ptr::NonNull;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use wayland_client::{
    globals::registry_queue_init,
    protocol::{wl_keyboard, wl_output, wl_pointer, wl_seat, wl_surface},
    Connection, Proxy, QueueHandle,
};

/// A [`raw_window_handle::HasDisplayHandle`] wrapper around the one
/// `RawDisplayHandle` this daemon ever has (the Wayland connection's own
/// `wl_display`), so `wgpu::InstanceDescriptor::display` -- which its own
/// docs say GLES needs on Wayland to be able to present at all -- has
/// something to hold. `NonNull` (inside `RawDisplayHandle`) is not
/// `Send`/`Sync` by default; this pointer is a stable, read-only FFI
/// handle for the whole daemon's life, never mutated, so sharing it
/// across threads is sound -- the same justification every other
/// raw-window-handle wrapper of its kind uses.
#[derive(Debug)]
struct WaylandDisplay(RawDisplayHandle);
unsafe impl Send for WaylandDisplay {}
unsafe impl Sync for WaylandDisplay {}
impl raw_window_handle::HasDisplayHandle for WaylandDisplay {
    fn display_handle(&self) -> Result<raw_window_handle::DisplayHandle<'_>, raw_window_handle::HandleError> {
        Ok(unsafe { raw_window_handle::DisplayHandle::borrow_raw(self.0) })
    }
}

const RING_W: u32 = 420;
const RING_H: u32 = 420;
const RADIUS: f32 = 140.0;
const SQUARE: f32 = 72.0;
const DEAD_ZONE: f32 = 24.0;
const LABELS: [&str; 6] = ["Term", "Files", "Web", "Mail", "Notes", "Lock"];

fn now_nanos() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos() as u64
}

fn socket_path() -> PathBuf {
    let dir = std::env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| "/tmp".to_string());
    // Deliberately keeps the toolkit's own hyphen (unlike cxx-qt's
    // "cxxqt") so tools/gallery.sh's `sock_suffix_for()` needs no new
    // special case for this one: its default branch already echoes the
    // toolkit name ("egui-layershell") verbatim.
    PathBuf::from(dir).join("appring-spike-egui-layershell.sock")
}

fn hyprctl_bin() -> String {
    std::env::var("MIRQL_RING_HYPRCTL").unwrap_or_else(|_| "hyprctl".to_string())
}

/// The cursor's position and the focused monitor's origin, both in
/// Hyprland's global logical-pixel space -- identical approach (and
/// honest best-effort fallback to (0,0) on any failure) as the `egui` and
/// `cxx-qt` spikes' own copy of this helper.
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
/// `show`, with nobody listening) start it ourselves and retry -- same
/// "a second invocation" allowance, same wire format, as the other two
/// spikes.
fn client_run(cmd: Cmd) {
    let path = socket_path();
    let stream = match UnixStream::connect(&path) {
        Ok(s) => s,
        Err(_) if matches!(cmd, Cmd::Hide) => {
            eprintln!("ring-eguilayershell: not running ({})", path.display());
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
                    eprintln!("ring-eguilayershell: daemon did not start in time");
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

/// Shared between the socket-accepting threads and the calloop/Wayland
/// main thread. Same roles as the `egui` spike's own `Shared` struct;
/// only the "wake the idle loop up" mechanism differs (a `calloop::channel`
/// message here, `egui::Context::request_repaint()` there) because there
/// is no egui/winit event loop to nudge -- `State::on_wake()` is the
/// equivalent of that spike's `App::ui()` noticing a new `generation`.
struct Shared {
    want_visible: AtomicBool,
    generation: AtomicU64,
    /// (left, top) in pixels, relative to the focused monitor's own
    /// origin -- i.e. exactly what `set_margin(top, 0, 0, left)` wants.
    pending_origin: Mutex<Option<(i32, i32)>>,
    show_received_nanos: AtomicU64,
    ack_generation: AtomicU64,
    ack_nanos: AtomicU64,
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
        }
    }
}

fn accept_loop(listener: UnixListener, shared: Arc<Shared>, wake_tx: Sender<()>) {
    for conn in listener.incoming().flatten() {
        let shared = Arc::clone(&shared);
        let wake_tx = wake_tx.clone();
        std::thread::spawn(move || handle_conn(conn, shared, wake_tx));
    }
}

fn handle_conn(mut conn: UnixStream, shared: Arc<Shared>, wake_tx: Sender<()>) {
    let mut reader = BufReader::new(conn.try_clone().expect("clone stream"));
    let mut line = String::new();
    if reader.read_line(&mut line).unwrap_or(0) == 0 {
        return;
    }
    match line.trim() {
        "show" => {
            let t_recv = now_nanos();
            let (cursor, mon_origin) = cursor_and_focused_monitor_origin();
            let left = cursor.0 - mon_origin.0 - (RING_W as i32) / 2;
            let top = cursor.1 - mon_origin.1 - (RING_H as i32) / 2;
            *shared.pending_origin.lock().unwrap() = Some((left, top));
            shared.show_received_nanos.store(t_recv, Ordering::SeqCst);
            shared.want_visible.store(true, Ordering::SeqCst);
            let my_gen = shared.generation.fetch_add(1, Ordering::SeqCst) + 1;
            let _ = wake_tx.send(());
            // Wait (bounded) for the Wayland thread to stamp the ack for
            // this request -- same handshake as the other two spikes.
            let deadline = Instant::now() + Duration::from_secs(2);
            loop {
                if shared.ack_generation.load(Ordering::SeqCst) == my_gen {
                    let ack = shared.ack_nanos.load(Ordering::SeqCst);
                    let ms = (ack.saturating_sub(t_recv)) as f64 / 1_000_000.0;
                    let _ = writeln!(conn, "shown {ms:.1}");
                    return;
                }
                if Instant::now() > deadline {
                    let _ = writeln!(conn, "shown timeout");
                    return;
                }
                std::thread::sleep(Duration::from_millis(1));
            }
        }
        "hide" => {
            shared.want_visible.store(false, Ordering::SeqCst);
            shared.generation.fetch_add(1, Ordering::SeqCst);
            let _ = wake_tx.send(());
            let _ = writeln!(conn, "hidden");
        }
        other => {
            let _ = writeln!(conn, "unknown command {other:?}");
        }
    }
}

/// Wayland + wgpu state that exists only while the ring is actually shown
/// (created fresh on `show`, fully torn down on `hide` -- unlike `egui/`'s
/// always-alive-but-invisible window, a layer-shell surface that does not
/// exist is *really* not there, not just hidden by a toggled property).
struct Shown {
    layer: LayerSurface,
    wgpu_surface: wgpu::Surface<'static>,
    /// True once the compositor's first `configure` for this surface has
    /// been handled and we are allowed to attach a real buffer.
    configured: bool,
    /// True until the first frame after this `show` has been presented;
    /// stamps `Shared::ack_*` the moment it flips, for the "show-to-
    /// first-frame" measurement.
    awaiting_first_frame: bool,
    first_frame_generation: u64,
}

struct State {
    registry_state: RegistryState,
    seat_state: SeatState,
    output_state: OutputState,
    qh: QueueHandle<State>,
    compositor: CompositorState,
    layer_shell: LayerShell,
    raw_display_handle: RawDisplayHandle,

    instance: wgpu::Instance,
    adapter: wgpu::Adapter,
    device: wgpu::Device,
    queue: wgpu::Queue,
    egui_ctx: egui::Context,
    /// Created lazily on the first `show` (needs a real surface's
    /// preferred texture format first); kept alive across every `hide`
    /// after that, like `device`/`queue`.
    renderer: Option<egui_wgpu::Renderer>,
    target_format: Option<wgpu::TextureFormat>,

    shared: Arc<Shared>,
    last_seen_generation: u64,
    start: Instant,

    shown: Option<Shown>,
    keyboard: Option<wl_keyboard::WlKeyboard>,
    pointer: Option<wl_pointer::WlPointer>,
    pointer_pos: Option<(f32, f32)>,
    pending_egui_events: Vec<egui::Event>,
    want_hide: bool,
}

impl State {
    /// Called once per `calloop::channel` wakeup (a `show`/`hide`/nothing-
    /// changed no-op) -- the equivalent of the `egui` spike's `App::ui()`
    /// noticing `generation` has moved on.
    fn on_wake(&mut self) {
        let gen = self.shared.generation.load(Ordering::SeqCst);
        if gen == self.last_seen_generation {
            return;
        }
        self.last_seen_generation = gen;
        if self.shared.want_visible.load(Ordering::SeqCst) {
            self.open_layer(gen);
        } else {
            self.close_layer();
        }
    }

    fn open_layer(&mut self, gen: u64) {
        self.close_layer();
        let (left, top) = self.shared.pending_origin.lock().unwrap().take().unwrap_or((0, 0));

        let wl_surface = self.compositor.create_surface(&self.qh);
        let layer = self.layer_shell.create_layer_surface(
            &self.qh,
            wl_surface,
            Layer::Overlay,
            Some("appring-spike-egui-layershell"),
            None,
        );
        // Real pixel positioning, not output-centring: anchoring two
        // orthogonal edges plus a margin places that corner at an exact
        // offset from the output's own origin -- the positioning
        // authority an xdg_toplevel never gets (see this file's own
        // header, and README.md's egui section on why the first spike
        // could not do this). No clamping: `left`/`top` are used as
        // computed, even if negative or past the output's edge.
        layer.set_size(RING_W, RING_H);
        layer.set_anchor(Anchor::TOP | Anchor::LEFT);
        layer.set_margin(top, 0, 0, left);
        layer.set_exclusive_zone(0);
        layer.set_keyboard_interactivity(KeyboardInteractivity::Exclusive);
        layer.commit();

        let raw_window_handle = RawWindowHandle::Wayland(WaylandWindowHandle::new(
            NonNull::new(layer.wl_surface().id().as_ptr() as *mut _).unwrap(),
        ));
        let wgpu_surface = unsafe {
            self.instance.create_surface_unsafe(wgpu::SurfaceTargetUnsafe::RawHandle {
                raw_display_handle: Some(self.raw_display_handle),
                raw_window_handle,
            })
        }
        .expect("create wgpu surface for the new layer surface");

        let caps = wgpu_surface.get_capabilities(&self.adapter);
        if caps.formats.is_empty() {
            eprintln!("ring-eguilayershell: wgpu surface has no supported formats, giving up on this show");
            return;
        }
        let format = self.target_format.unwrap_or_else(|| {
            egui_wgpu::preferred_framebuffer_format(&caps.formats).unwrap_or(caps.formats[0])
        });
        if self.renderer.is_none() {
            self.renderer =
                Some(egui_wgpu::Renderer::new(&self.device, format, egui_wgpu::RendererOptions::default()));
            self.target_format = Some(format);
        }
        let alpha_mode = if caps.alpha_modes.contains(&wgpu::CompositeAlphaMode::PreMultiplied) {
            wgpu::CompositeAlphaMode::PreMultiplied
        } else if caps.alpha_modes.contains(&wgpu::CompositeAlphaMode::PostMultiplied) {
            wgpu::CompositeAlphaMode::PostMultiplied
        } else {
            wgpu::CompositeAlphaMode::Auto
        };
        wgpu_surface.configure(
            &self.device,
            &wgpu::SurfaceConfiguration {
                usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
                format,
                color_space: wgpu::SurfaceColorSpace::Auto,
                view_formats: vec![format],
                alpha_mode,
                width: RING_W,
                height: RING_H,
                desired_maximum_frame_latency: 1,
                // Fifo is the only present mode `wgpu` guarantees every
                // backend supports (its own docs say so); checked here,
                // not assumed: a headless sway with the GL backend
                // advertised only `[Fifo]`, so `Mailbox` panicked
                // `Surface::configure` outright on the first `show`.
                present_mode: wgpu::PresentMode::Fifo,
            },
        );

        self.shown = Some(Shown {
            layer,
            wgpu_surface,
            configured: false,
            awaiting_first_frame: true,
            first_frame_generation: gen,
        });
    }

    fn close_layer(&mut self) {
        if let Some(shown) = self.shown.take() {
            // Layer-shell protocol note (and `examples/wgpu.rs`'s own
            // comment): destroy the wgpu surface before the wl_surface it
            // was built from goes away.
            let Shown { layer, wgpu_surface, .. } = shown;
            drop(wgpu_surface);
            drop(layer);
        }
        self.pointer_pos = None;
        self.pending_egui_events.clear();
    }

    fn render_frame(&mut self) {
        if self.shown.is_none() {
            return;
        }
        let pointer = self.pointer_pos.unwrap_or((RING_W as f32 / 2.0, RING_H as f32 / 2.0));

        let raw_input = egui::RawInput {
            screen_rect: Some(egui::Rect::from_min_size(
                egui::Pos2::ZERO,
                egui::vec2(RING_W as f32, RING_H as f32),
            )),
            time: Some(self.start.elapsed().as_secs_f64()),
            events: std::mem::take(&mut self.pending_egui_events),
            focused: true,
            ..Default::default()
        };

        let egui::FullOutput { shapes, mut textures_delta, pixels_per_point, .. } =
            self.egui_ctx.run_ui(raw_input, |ui| draw_ring(ui, pointer));

        // Esc or any click hides it too (as in the other two
        // spikes); acted on below, after this frame is
        // still drawn and presented once.
        if self.egui_ctx.input(|i| i.pointer.any_click() || i.key_pressed(egui::Key::Escape)) {
            self.want_hide = true;
        }

        let clipped_primitives = self.egui_ctx.tessellate(shapes, pixels_per_point);
        let screen_descriptor =
            egui_wgpu::ScreenDescriptor { size_in_pixels: [RING_W, RING_H], pixels_per_point };

        let device = &self.device;
        let queue = &self.queue;
        let renderer = self.renderer.as_mut().expect("renderer created with the first shown surface");

        for (id, image_deltas) in textures_delta.set.drain() {
            for image_delta in image_deltas {
                renderer.update_texture(device, queue, id, &image_delta);
            }
        }

        let mut encoder =
            device.create_command_encoder(&wgpu::CommandEncoderDescriptor { label: Some("egui-layershell") });
        let user_cmd_bufs =
            renderer.update_buffers(device, queue, &mut encoder, &clipped_primitives, &screen_descriptor);

        let shown = self.shown.as_mut().expect("checked at the top of this function");
        let surface_texture = match shown.wgpu_surface.get_current_texture() {
            wgpu::CurrentSurfaceTexture::Success(t) | wgpu::CurrentSurfaceTexture::Suboptimal(t) => t,
            other => {
                eprintln!("ring-eguilayershell: get_current_texture: {other:?}");
                return;
            }
        };
        let view = surface_texture.texture.create_view(&wgpu::TextureViewDescriptor::default());
        {
            let pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("egui-layershell-pass"),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: &view,
                    resolve_target: None,
                    ops: wgpu::Operations {
                        load: wgpu::LoadOp::Clear(wgpu::Color::TRANSPARENT),
                        store: wgpu::StoreOp::Store,
                    },
                    depth_slice: None,
                })],
                depth_stencil_attachment: None,
                timestamp_writes: None,
                occlusion_query_set: None,
                multiview_mask: None,
            });
            renderer.render(&mut pass.forget_lifetime(), &clipped_primitives, &screen_descriptor);
        }
        for id in textures_delta.free.drain() {
            renderer.free_texture(&id);
        }

        // Ask for the *next* frame callback before presenting, so the
        // commit `.present()` performs internally also carries this
        // request (same ordering as SCTK's own `examples/simple_layer.rs`:
        // `frame()` queued, then one commit) -- this is what paces
        // redraws to the compositor while shown, like the other two
        // spikes' own idle-repaint loop.
        let wl_surface = shown.layer.wl_surface().clone();
        wl_surface.frame(&self.qh, FrameCallbackData(wl_surface.clone()));

        queue.submit(user_cmd_bufs.into_iter().chain(std::iter::once(encoder.finish())));
        queue.present(surface_texture);

        if shown.awaiting_first_frame {
            shown.awaiting_first_frame = false;
            self.shared.ack_nanos.store(now_nanos(), Ordering::SeqCst);
            self.shared.ack_generation.store(shown.first_frame_generation, Ordering::SeqCst);
        }

        if self.want_hide {
            self.want_hide = false;
            self.shared.want_visible.store(false, Ordering::SeqCst);
            let new_gen = self.shared.generation.fetch_add(1, Ordering::SeqCst) + 1;
            self.last_seen_generation = new_gen;
            self.close_layer();
        }
    }
}

fn daemon_run() {
    let path = socket_path();
    if path.exists() {
        if UnixStream::connect(&path).is_err() {
            let _ = std::fs::remove_file(&path);
        } else {
            eprintln!("ring-eguilayershell: already running ({})", path.display());
            std::process::exit(1);
        }
    }
    let listener = UnixListener::bind(&path).expect("bind socket");
    let shared = Arc::new(Shared::new());

    let conn = Connection::connect_to_env().expect("connect to the Wayland display");
    let (globals, event_queue) = registry_queue_init::<State>(&conn).expect("registry_queue_init");
    let qh = event_queue.handle();

    let compositor = CompositorState::bind(&globals, &qh).expect("wl_compositor not available");
    let layer_shell = LayerShell::bind(&globals, &qh).expect("zwlr_layer_shell_v1 not available");
    let seat_state = SeatState::new(&globals, &qh);
    let output_state = OutputState::new(&globals, &qh);
    let registry_state = RegistryState::new(&globals);

    let mut event_loop: EventLoop<State> = EventLoop::try_new().expect("calloop event loop");
    let loop_handle = event_loop.handle();
    WaylandSource::new(conn.clone(), event_queue)
        .insert(loop_handle.clone())
        .expect("insert the Wayland event source into calloop");

    let (wake_tx, wake_rx): (Sender<()>, Channel<()>) = calloop::channel::channel();
    loop_handle
        .insert_source(wake_rx, |event, _, state: &mut State| {
            if let ChannelEvent::Msg(()) = event {
                state.on_wake();
            }
        })
        .expect("insert the wake channel into calloop");

    {
        let shared = Arc::clone(&shared);
        let wake_tx = wake_tx.clone();
        std::thread::spawn(move || accept_loop(listener, shared, wake_tx));
    }

    // Eager wgpu init at startup (adapter/device/queue, *not* yet a
    // surface -- none exists until the first `show`), matching the other
    // two spikes' own precedent of fully loading their toolkit before any
    // `show` so "idle RSS (hidden)" means the same thing across all
    // three: the whole renderer loaded, nothing on screen. Only the GL
    // backend is requested (`Backends::GL`, not `all()`/Vulkan): this
    // host's headless sway proved GL-only already works for the `egui`
    // (eframe/glow) and `cxx-qt` (Qt's own GL-backed QtQuick) spikes, and
    // a software Vulkan ICD (lavapipe) is not known to be registered in
    // this nix dev shell, while `libGL`/`vulkan-loader` are already on
    // `flake.nix`'s own `buildInputs` for exactly this reason.
    let raw_display_handle = RawDisplayHandle::Wayland(WaylandDisplayHandle::new(
        NonNull::new(conn.backend().display_ptr() as *mut _).unwrap(),
    ));
    // `InstanceDescriptor` has no `Default` (its `display` field is a
    // `Box<dyn ..>`); `GLES ... is required [to present] especially for
    // Wayland` per its own field doc, so `display` is set here, not left
    // `None` -- `WaylandDisplay` (above) is this spike's own thin
    // `HasDisplayHandle` wrapper around the connection's `wl_display`.
    let instance = wgpu::Instance::new(wgpu::InstanceDescriptor {
        backends: wgpu::Backends::GL,
        ..wgpu::InstanceDescriptor::new_with_display_handle(Box::new(WaylandDisplay(raw_display_handle)))
    });
    let adapter = pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions {
        compatible_surface: None,
        ..Default::default()
    }))
    .expect("no wgpu adapter found on the GL backend");
    let (device, queue) = pollster::block_on(adapter.request_device(&wgpu::DeviceDescriptor::default()))
        .expect("wgpu request_device failed");

    let mut state = State {
        registry_state,
        seat_state,
        output_state,
        qh,
        compositor,
        layer_shell,
        raw_display_handle,
        instance,
        adapter,
        device,
        queue,
        egui_ctx: egui::Context::default(),
        renderer: None,
        target_format: None,
        shared,
        last_seen_generation: 0,
        start: Instant::now(),
        shown: None,
        keyboard: None,
        pointer: None,
        pointer_pos: None,
        pending_egui_events: Vec::new(),
        want_hide: false,
    };

    eprintln!("ring-eguilayershell: listening on {}", path.display());
    loop {
        event_loop.dispatch(None, &mut state).expect("calloop dispatch");
    }
}

/// The ring itself: six rounded-square buttons on a circle, captions
/// always shown beneath each (the Quickshell ring's look, `appring/
/// RingLayer.qml`), the one nearest the pointer's angle scaled up with a
/// soft glow, a centre disc with a small arrow pointing at the pointer's
/// direction (hidden inside a small dead zone around the centre), and a
/// soft dark halo sized only to the ring's own footprint -- never a
/// full-screen dim. The halo is this spike's own stand-in for
/// `RingLayer.qml`'s real `QtQuick.Shapes` radial gradient (egui has no
/// built-in radial-gradient fill): a handful of concentric,
/// decreasing-opacity circles, which looks close but is not the same
/// technique, said here rather than silently ported as if it were.
fn draw_ring(ui: &mut egui::Ui, pointer: (f32, f32)) {
    let screen = ui.max_rect();
    let center = screen.center();
    let painter = ui.painter();
    let pointer = egui::pos2(pointer.0, pointer.1);

    let delta = pointer - center;
    let dist = delta.length();
    let dead_zone = dist < DEAD_ZONE;
    let pointer_angle = delta.y.atan2(delta.x);

    let halo_r = RADIUS + SQUARE / 2.0 + 60.0;
    for &(frac, alpha) in &[(1.0_f32, 10u8), (0.75, 22), (0.5, 38), (0.3, 55)] {
        painter.circle_filled(center, halo_r * frac, egui::Color32::from_rgba_unmultiplied(8, 8, 14, alpha));
    }

    let slot_angle = |i: usize| -> f32 { -std::f32::consts::FRAC_PI_2 + (i as f32) * std::f32::consts::TAU / 6.0 };
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
        let pos = egui::pos2(center.x + RADIUS * a.cos(), center.y + RADIUS * a.sin());
        let highlighted = !dead_zone && i == nearest;
        let size = if highlighted { SQUARE * 1.3 } else { SQUARE };
        let corner = size * 0.18;
        let r = egui::Rect::from_center_size(pos, egui::vec2(size, size));

        if highlighted {
            for &(pad, alpha) in &[(size + 44.0, 34u8), (size + 20.0, 70)] {
                let glow = egui::Rect::from_center_size(pos, egui::vec2(pad, pad));
                painter.rect_filled(glow, pad * 0.18, egui::Color32::from_rgba_unmultiplied(120, 170, 255, alpha));
            }
        }
        let fill = if highlighted {
            egui::Color32::from_rgb(90, 140, 230)
        } else {
            egui::Color32::from_rgba_unmultiplied(40, 44, 56, 235)
        };
        painter.rect_filled(r, corner, fill);
        painter.rect_stroke(
            r,
            corner,
            egui::Stroke::new(
                if highlighted { 2.0 } else { 1.5 },
                egui::Color32::from_rgba_unmultiplied(255, 255, 255, if highlighted { 120 } else { 60 }),
            ),
            egui::StrokeKind::Inside,
        );

        // Every button's own caption, always shown, below it -- not just
        // the highlighted one (RingLayer.qml's own rule).
        painter.text(
            egui::pos2(pos.x, pos.y + size / 2.0 + 4.0),
            egui::Align2::CENTER_TOP,
            label,
            egui::FontId::proportional(if highlighted { 13.0 } else { 11.0 }),
            if highlighted {
                egui::Color32::WHITE
            } else {
                egui::Color32::from_rgba_unmultiplied(205, 214, 244, 220)
            },
        );
    }

    // Centre: a plain disc, unchanged by state, plus a separate small
    // arrow just past its edge pointing at the pointer's current
    // direction -- hidden in the dead zone, not drawn as a wedge inside
    // the disc itself.
    let disc_r = 15.0;
    painter.circle_filled(center, disc_r, egui::Color32::from_rgba_unmultiplied(30, 30, 46, 235));
    painter.circle_stroke(center, disc_r, egui::Stroke::new(2.0, egui::Color32::from_rgba_unmultiplied(69, 71, 90, 255)));
    if !dead_zone {
        let dir = egui::vec2(pointer_angle.cos(), pointer_angle.sin());
        let side = egui::vec2(-dir.y, dir.x) * 5.0;
        let base = center + dir * (disc_r + 9.0);
        let tip = center + dir * (disc_r + 15.0);
        painter.add(egui::Shape::convex_polygon(
            vec![tip, base + side, base - side],
            egui::Color32::from_rgb(180, 161, 219),
            egui::Stroke::NONE,
        ));
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

impl CompositorHandler for State {
    fn scale_factor_changed(
        &mut self,
        _conn: &Connection,
        _qh: &QueueHandle<Self>,
        _surface: &wl_surface::WlSurface,
        _new_factor: i32,
    ) {
    }

    fn transform_changed(
        &mut self,
        _conn: &Connection,
        _qh: &QueueHandle<Self>,
        _surface: &wl_surface::WlSurface,
        _new_transform: wl_output::Transform,
    ) {
    }

    fn frame(&mut self, _conn: &Connection, _qh: &QueueHandle<Self>, surface: &wl_surface::WlSurface, _time: u32) {
        if let Some(shown) = &self.shown {
            if shown.layer.wl_surface() == surface {
                self.render_frame();
            }
        }
    }

    fn surface_enter(
        &mut self,
        _conn: &Connection,
        _qh: &QueueHandle<Self>,
        _surface: &wl_surface::WlSurface,
        _output: &wl_output::WlOutput,
    ) {
    }

    fn surface_leave(
        &mut self,
        _conn: &Connection,
        _qh: &QueueHandle<Self>,
        _surface: &wl_surface::WlSurface,
        _output: &wl_output::WlOutput,
    ) {
    }
}

impl OutputHandler for State {
    fn output_state(&mut self) -> &mut OutputState {
        &mut self.output_state
    }
    fn new_output(&mut self, _conn: &Connection, _qh: &QueueHandle<Self>, _output: wl_output::WlOutput) {}
    fn update_output(&mut self, _conn: &Connection, _qh: &QueueHandle<Self>, _output: wl_output::WlOutput) {}
    fn output_destroyed(&mut self, _conn: &Connection, _qh: &QueueHandle<Self>, _output: wl_output::WlOutput) {}
}

impl LayerShellHandler for State {
    fn closed(&mut self, _conn: &Connection, _qh: &QueueHandle<Self>, layer: &LayerSurface) {
        if let Some(shown) = &self.shown {
            if shown.layer == *layer {
                self.shown = None;
            }
        }
    }

    fn configure(
        &mut self,
        _conn: &Connection,
        _qh: &QueueHandle<Self>,
        layer: &LayerSurface,
        _configure: LayerSurfaceConfigure,
        _serial: u32,
    ) {
        let first = matches!(&self.shown, Some(s) if s.layer == *layer && !s.configured);
        if first {
            if let Some(shown) = &mut self.shown {
                shown.configured = true;
            }
            self.render_frame();
        }
    }
}

impl SeatHandler for State {
    fn seat_state(&mut self) -> &mut SeatState {
        &mut self.seat_state
    }
    fn new_seat(&mut self, _: &Connection, _: &QueueHandle<Self>, _: wl_seat::WlSeat) {}

    fn new_capability(
        &mut self,
        _conn: &Connection,
        qh: &QueueHandle<Self>,
        seat: wl_seat::WlSeat,
        capability: Capability,
    ) {
        if capability == Capability::Keyboard && self.keyboard.is_none() {
            self.keyboard = self.seat_state.get_keyboard(qh, &seat, None).ok();
        }
        if capability == Capability::Pointer && self.pointer.is_none() {
            self.pointer = self.seat_state.get_pointer(qh, &seat).ok();
        }
    }

    fn remove_capability(
        &mut self,
        _conn: &Connection,
        _: &QueueHandle<Self>,
        _: wl_seat::WlSeat,
        capability: Capability,
    ) {
        if capability == Capability::Keyboard {
            if let Some(k) = self.keyboard.take() {
                k.release();
            }
        }
        if capability == Capability::Pointer {
            if let Some(p) = self.pointer.take() {
                p.release();
            }
        }
    }

    fn remove_seat(&mut self, _: &Connection, _: &QueueHandle<Self>, _: wl_seat::WlSeat) {}
}

impl KeyboardHandler for State {
    fn enter(
        &mut self,
        _: &Connection,
        _: &QueueHandle<Self>,
        _: &wl_keyboard::WlKeyboard,
        _surface: &wl_surface::WlSurface,
        _: u32,
        _: &[u32],
        _keysyms: &[Keysym],
    ) {
    }

    fn leave(
        &mut self,
        _: &Connection,
        _: &QueueHandle<Self>,
        _: &wl_keyboard::WlKeyboard,
        _surface: &wl_surface::WlSurface,
        _: u32,
    ) {
    }

    fn press_key(&mut self, _conn: &Connection, _qh: &QueueHandle<Self>, _: &wl_keyboard::WlKeyboard, _: u32, event: KeyEvent) {
        if event.keysym == Keysym::Escape {
            self.want_hide = true;
        }
    }

    fn repeat_key(&mut self, _conn: &Connection, _qh: &QueueHandle<Self>, _: &wl_keyboard::WlKeyboard, _serial: u32, _event: KeyEvent) {}

    fn release_key(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_keyboard::WlKeyboard, _: u32, _event: KeyEvent) {}

    fn update_modifiers(
        &mut self,
        _: &Connection,
        _: &QueueHandle<Self>,
        _: &wl_keyboard::WlKeyboard,
        _serial: u32,
        _modifiers: Modifiers,
        _raw_modifiers: RawModifiers,
        _layout: u32,
    ) {
    }
}

fn egui_pointer_button(code: u32) -> Option<egui::PointerButton> {
    // Linux evdev button codes (linux/input-event-codes.h) -- the same
    // ones `wl_pointer.button` reports.
    match code {
        0x110 => Some(egui::PointerButton::Primary),
        0x111 => Some(egui::PointerButton::Secondary),
        0x112 => Some(egui::PointerButton::Middle),
        _ => None,
    }
}

impl PointerHandler for State {
    fn pointer_frame(&mut self, _conn: &Connection, _qh: &QueueHandle<Self>, _pointer: &wl_pointer::WlPointer, events: &[PointerEvent]) {
        let Some(shown) = &self.shown else { return };
        let surface = shown.layer.wl_surface().clone();
        for event in events {
            if event.surface != surface {
                continue;
            }
            let (x, y) = (event.position.0 as f32, event.position.1 as f32);
            match event.kind {
                PointerEventKind::Enter { .. } | PointerEventKind::Motion { .. } => {
                    self.pointer_pos = Some((x, y));
                    self.pending_egui_events.push(egui::Event::PointerMoved(egui::pos2(x, y)));
                }
                PointerEventKind::Leave { .. } => {
                    self.pointer_pos = None;
                    self.pending_egui_events.push(egui::Event::PointerGone);
                }
                PointerEventKind::Press { button, .. } => {
                    self.pointer_pos = Some((x, y));
                    if let Some(b) = egui_pointer_button(button) {
                        self.pending_egui_events.push(egui::Event::PointerButton {
                            pos: egui::pos2(x, y),
                            button: b,
                            pressed: true,
                            modifiers: egui::Modifiers::default(),
                        });
                    }
                    // Any click hides the ring too (as in the other two
                    // spikes) -- acted on at the
                    // top of `render_frame()`'s tail, so this click is
                    // still fed to egui for one last frame first.
                    self.want_hide = true;
                }
                PointerEventKind::Release { .. } | PointerEventKind::Axis { .. } => {}
            }
        }
    }
}

delegate_registry!(State);

impl ProvidesRegistryState for State {
    fn registry(&mut self) -> &mut RegistryState {
        &mut self.registry_state
    }
    registry_handlers![OutputState, SeatState];
}

smithay_client_toolkit::delegate_dispatch2!(State);
