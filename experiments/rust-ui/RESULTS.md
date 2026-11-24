# Rust UI experiments for the ring: results

Could the ring be a native Rust app instead of a Quickshell one? Four tiny
prototypes, written in October 2026, each doing the same small thing: start
hidden, `show`/`hide` over a Unix socket, six rounded-square buttons on a
circle, the one in the pointer's direction glowing, a centre dot,
Esc/click/`hide` hides again, the process stays, show-to-first-frame
printed on `show`. They are not the ring and are not maintained: they are
kept for what they showed. Linux/Wayland only.

Measured off-screen only: a private headless sway (`tools/gallery.sh`), a
stand-in `hyprctl` (`tools/fake-hyprctl.sh`, cursor at a fixed point, one
fake monitor at origin), `grim` screenshots.

## The table

| | iced (iced_layershell) | cxx-qt (QML + LayerShellQt) | egui (eframe, no layer-shell) |
|---|---|---|---|
| Builds | **no**, today | yes | yes |
| Layer-shell | n/a (doesn't build) | **yes**, real wlr-layer-shell, screenshotted | **no** (see Limitation) |
| Binary size (release) | — | 2.52 MB (1.70 MB stripped) | 13.13 MB (9.67 MB stripped) |
| Idle RSS (hidden) | — | 112.6 MB | 90.5 MB |
| Shown RSS | — | 150.5 MB | 90.5 MB |
| Show-to-first-frame | — | not measured (see note) | **median 10.1 ms** over 10 runs (7.9–37.8 ms) |
| Lines of code | 441 (Rust, doesn't build) | 307 Rust + 120 QML = 427 | 416 (Rust) |
| Build time (release, cold) | n/a | 3m 31s | 3m 17s |
| Build time (incremental) | n/a | ~9–14 s | ~7 s |
| Screenshot | — | [`docs/gallery/cxx-qt.png`](docs/gallery/cxx-qt.png) | [`docs/gallery/egui.png`](docs/gallery/egui.png) |

All measured on one machine (nixpkgs' Qt 6.11.2 / rustc 1.98.1), one
run each; show-to-first-frame is the median of 10 consecutive `show`/`hide`
cycles against an already-running daemon (cold-start/daemon-spawn latency
excluded, reported separately below).

## iced (`iced_layershell` 0.19.1) — does not build today

The code (`iced/src/main.rs`) is a real attempt: `iced_layershell::application`,
a single persistent layer surface started shrunk to 1×1px off-screen with
no keyboard interactivity ("hidden"), `AnchorSizeChange`/`MarginChange`/
`KeyboardInteractivityChange` actions (from its `to_layer_message` macro) to
resize/reposition/arm it on `show`, an `iced::widget::canvas::Program` for
the ring itself (cursor position comes straight from the canvas `draw()`
call's `mouse::Cursor`, no manual pointer tracking needed). It does not
compile:

- `iced_layershell` 0.19.1 pulls `window_clipboard`, which pulls
  `softbuffer` 0.4.8 without its `wayland`/`x11` Cargo features enabled
  anywhere in the dependency graph; `softbuffer`'s own `make_dispatch!`
  macro then generates an enum with **zero** variants for this target
  (both are `#[cfg(target_os = "android"/"redox")]`-only without those
  features), and matching a reference to that enum is a hard error under
  this rustc (1.98.1) — "non-exhaustive patterns … references are always
  considered inhabited". **Fixed** by adding `softbuffer = { version =
  "0.4", features = ["wayland", "x11"] }` as a direct (otherwise-unused)
  dependency of our own `iced/Cargo.toml`, forcing Cargo's feature
  unification to turn them on everywhere (see the comment there).
- Past that, `iced_layershell` also pulls (unconditionally, not
  feature-gated) `iced_exdevtools` ^0.19.1, which fails on its own: a
  `match` over `winit-core::NativeKeyCode` (`#[non_exhaustive]`) in its
  `keymap.rs` is missing a wildcard arm for a variant `winit-core` gained
  since. `iced_exdevtools` 0.20.1 already fixes this — but `iced_layershell`
  0.19.1's own manifest pins `^0.19.1`, and Cargo's `[patch.crates-io]`
  (tried, see the comment in `iced/Cargo.toml`) explicitly refuses to
  repoint a dependency at another version **of the same registry**; a
  `[patch]` must name a different source (a git fork, a local path), which
  would mean vendoring/patching `iced_exdevtools` ourselves — past this
  spike's time budget.

Both are upstream breakage in a fast-moving, pre-1.0 ecosystem (`iced`,
`iced_layershell` and their `waycrate/exwlshelleventloop` siblings churn
versions in days), not anything in this repo's code; retrying in a week or
two, once `iced_layershell` bumps its `iced_exdevtools` pin, is plausibly
all it takes. **How hard it was otherwise:** the layer-shell binding
itself (the part actually in question) looked the most ergonomic of the
three — real actions for resize/margin/keyboard state with no C++ at all,
`Canvas` giving the cursor position for free. If this is worth another
look, start from here.

If you run `cargo build` in `iced/`, expect a noisy build ending in a
`compile_error!` from `winit`/`softbuffer`'s own platform-support macro
("platform not supported") — the same `softbuffer` feature-unification
gap above, not a new, third failure.

## cxx-qt (0.10, QML + LayerShellQt) — builds, real layer-shell, screenshot

`cxx-qt/`: a `RingBridge` QObject (`src/bridge.rs`, `#[qml_element]`, one
`visible: bool` property) instantiated by QML itself
(`qml/Ring.qml`: `RingBridge { id: bridge }`); `cxx_qt::Initialize` spawns
the Unix-socket accept thread in its constructor, handed a `CxxQtThread`
(`cxx_qt::Threading`) so it can flip `bridge.visible` from another thread
via `qt_thread.queue(...)`. The ring itself is a QML `Canvas` (JS 2D
context), same angle math as the other two. Layer-shell is **pure QML**:
`import org.kde.layershell 1.0 as LayerShellQt`, `LayerShellQt.Window.layer:
LayerOverlay`, `.keyboardInteractivity` toggled with `visible`, zero C++
glue — the KDE QML plugin calls `LayerShellQt::Shell::useLayerShell()`
itself. The screenshot
([`docs/gallery/cxx-qt.png`](docs/gallery/cxx-qt.png)) is the real
wlr-layer-shell surface, composited by (headless) sway and grabbed with
`grim` — this is not a plain window, the protocol path genuinely works.

**How hard it was**, honestly — most of this spike's time went here, for
three separate, each-individually-small things that happened to stack:

1. **nixpkgs' split Qt 6 outputs**: `qt-build-utils` (cxx-qt-build's Qt
   discovery) finds Qt's modules via `qmake`, which only knows about its
   own package's (`qt6.qtbase`) lib dir — "Could not find a prl path for
   Qt module: Qml", since `qt6.qtdeclarative` is a separate nix store path.
   Fixed with `qt6.env "name" [ qt6.qtbase qt6.qtdeclarative qt6.qtwayland
   ]`, nixpkgs' own merge-the-split-outputs helper for exactly this
   (`flake.nix`).
2. **Two silent-failure traps, back to back**, that between them made the
   whole app look completely inert (no crash, no window, no error) for a
   long stretch of debugging:
   - `JOURNAL_STREAM` (inherited from a systemd user session) makes
     Qt's default message handler send `qWarning`/`qDebug` to journald
     instead of stderr — any QML load error would have been invisible in a
     captured log. `tools/gallery.sh` now unsets it, like the session
     variables it already unset.
   - `QQmlApplicationEngine::load(url)` against the qrc path
     `cxx-qt-build`'s `QmlModule` is **documented** to embed resources
     under (`qrc:/qt/qml/<uri>/<file>.qml`) did not resolve here — no
     crash, no warning (even with `set_output_warnings_to_standard_error
     (true)` explicitly on), QML component creation simply never started.
     A trivial inline `load_data()` of plain `QtQuick` QML in the same
     binary worked immediately, isolating it to the resource path rather
     than Qt/Wayland setup. The fix kept in `main.rs`: read the real
     `qml/Ring.qml` at compile time (`include_str!`) and `load_data()` it
     directly, sidestepping the qrc path question (and the real file,
     including its `org.kde.layershell`/`com.mirql.ring` imports, loads
     and resolves fine this way — so it really was only the resource path,
     not the module registration).
3. One real Rust bug along the way, not a tooling trap:
   `let _ = engine.on_object_created(...)` **drops the returned
   `QMetaObjectConnectionGuard` immediately** (disconnecting the signal on
   the spot, before `load()` was even called) — `let _ =` does not extend a
   temporary's lifetime the way `let _name =` does. Bound to a kept-alive
   variable, as it now is.

**Limitation — cursor-centring, not output-centring.** The overlay is
centred on the **focused output** (`LayerShellQt.Window.anchors:
AnchorNone`, `screenConfiguration: ScreenFromCompositor` — wlr-layer-shell
centres an unanchored surface on its output, and an output-less
`get_layer_surface` request is given the focused one), not on the exact
cursor a radial menu needs. True cursor-centring needs
`LayerShellQt::Window::setMargins()`, a plain C++ call with no QML-exposed
equivalent (`margins` is a `QMargins` property, not one of Qt's
QML-auto-converted value types — `QRect`/`QPoint`/`QSize`/… are, `QMargins`
is not). That needs LayerShellQt's C++ headers, which this nixpkgs
packaging does not install at all: `kdePackages.layer-shell-qt.dev`
produces an **empty** output (checked: `nix build
nixpkgs#kdePackages.layer-shell-qt.dev` then `find` on it finds nothing
past the directory itself) — building them from source, or hand-rolling a
cxx bridge to the already-built `.so` without headers, was out of this
spike's time budget. Noted rather than silently shipped as "centred on the
cursor."

**Show-to-first-frame: not measured**, honestly, rather than reported
wrong. The plan was `QQuickWindow.onFrameSwapped` (genuinely the most
accurate of the three methodologies, a real presented-frame signal, not an
approximation) calling back into Rust; it never fired within the 2 s
budget in this headless/software-rendered sway, every one of the 10 runs
timed out. The screenshot proves a frame *is* presented eventually (grim
caught it), so this is a measurement gap in the harness/signal wiring, not
evidence the toolkit is slow — just not something to report a number for
without more time to chase it down.

## egui (eframe, no layer-shell) — honest fallback

`egui/`: `eframe::run_native` with a plain, undecorated, transparent,
initially-hidden (`with_visible(false)`) window; `show`/`hide` drive
`egui::ViewportCommand::Visible`/`OuterPosition`/`Focus` from the IPC
thread via a shared generation counter + `egui::Context::request_repaint()`
to wake the idle event loop. The ring is drawn with `egui::Painter`
directly (rounded rects, a glow rect behind the highlighted one, text,
a centre dot) — the simplest of the three to write and by far the
fastest to build and iterate (one fix needed: eframe 0.36 replaced
`App::update(&self, ctx, frame)` with `App::ui(&mut self, ui: &mut Ui,
frame)`, caught immediately by the compiler).

**This is not on layer-shell**, by design: egui/eframe has no built-in layer-shell support (unlike
`iced_layershell` or Qt+LayerShellQt), and hand-rolling one with
`smithay-client-toolkit` (a raw Wayland client: EGL context, feeding
`egui::RawInput` by hand from SCTK events) was out of this spike's time
budget — `layershellev` (same project as `iced_layershell`, "winit-like
event loop with layer-shell") looked like the most promising path if this
is ever revisited, pairing it with `egui_glow`'s painter. Two things that
follow from "no layer-shell" are also genuinely broken here, not just
less polished, and worth saying plainly since they're the actual reason
the ring wants layer-shell:

- **No real always-on-top.** `ViewportCommand::WindowLevel(AlwaysOnTop)`
  is sent, but a plain `xdg-toplevel` has no compositor-enforced stacking
  hint on Wayland; Hyprland would need a window rule
  (`windowrulev2 = pin`/`stayfocused`) to approximate it.
- **No real cursor-centring either.** `ViewportCommand::OuterPosition` is
  sent with the computed cursor position, but Wayland gives clients no
  positioning authority over `xdg-toplevel` windows at all, by protocol
  design; wlroots compositors ignore it. (In the screenshot, it landed
  where sway's own placement policy — centred on the output, coincidentally
  close to the cursor position used in this run — put it, not where we
  asked.)

So: fast, small, easy — and the fallback itself can't actually deliver
what the ring needs on Wayland without the extra work above. The numbers
above (93 MB idle RSS, 10 ms median show-to-first-frame) are real and
measured the same way as cxx-qt's, for comparison, but they describe a
POC that is further from "the ring" than the other two.

## Build and run one yourself

```sh
cd experiments/rust-ui
nix develop                 # rustc/cargo, Qt 6 + LayerShellQt, wayland libs

# egui (works; see "honest fallback" above)
cd egui && cargo build --release
./target/release/ring-egui show   # prints show-to-first-frame; starts the daemon itself if not running
./target/release/ring-egui hide

# cxx-qt (works; real layer-shell overlay)
cd ../cxx-qt && cargo build --release
./target/release/ring-cxxqt show
./target/release/ring-cxxqt hide

# iced: does not build (see above); `cargo build` in iced/ shows the error.
```

To try one on Hyprland for this session only (gone on the next restart):

```sh
hyprctl keyword bind "SUPER,grave,exec,$PWD/target/release/ring-cxxqt show"
```

Esc, a click anywhere on the ring, or `… hide` from another terminal hides
it again; the process stays running for the next `show`. Each binary's
own `show`/`hide` client starts the daemon itself on the first `show` if
nothing is listening yet.

## Reproduce the off-screen measurements

```sh
cd experiments/rust-ui
nix develop -c bash tools/gallery.sh            # every toolkit that builds
nix develop -c bash tools/gallery.sh egui       # one at a time
cat /tmp/appring-experiments-gallery/summary.txt
```

Never touches your desktop: a private headless sway
(`WLR_BACKENDS=headless`), a stand-in `hyprctl` (`tools/fake-hyprctl.sh`),
a private `XDG_RUNTIME_DIR`.

## egui-layershell (smithay-client-toolkit + egui-wgpu, real wlr-layer-shell)

A second round: can **egui** draw into a real Wayland layer-shell overlay
at the cursor and get close to the ring's look, unlike the first egui
prototype above (plain `eframe`/`winit`, no layer-shell, could not centre
on the cursor or stay on top)?

**Yes.** `egui-layershell/`: no eframe, no winit -- a hand-built
`smithay-client-toolkit` (SCTK) layer-shell surface (`zwlr_layer_shell_v1`,
overlay layer, keyboard-exclusive only while shown), painted with
`egui-wgpu`'s `Renderer` directly (the GL backend, the path the `egui`/`cxx-qt`
prototypes above showed works in a headless sway), input fed to egui by hand from SCTK's own pointer/keyboard
handlers. `show`/`hide` over the same Unix-socket shape as the other two.
Full source commentary is in `egui-layershell/src/main.rs`'s own module
doc -- this section is the measured results and the comparison.

**No maintained crate already does this**, checked against crates.io
2026-10-13, not assumed: `wayapp` 0.3.2 ("A Wayland application wrapper
using smithay-client-toolkit, supports currently just egui using wgpu")
is the closest-sounding hit, but its own README confirms a plain
`xdg_toplevel` window, not layer-shell -- exactly the gap this spike
exists to close, and it carries a `non-standard` crates.io license besides.
`layershellev` (the `iced_layershell`-adjacent "winit-like event loop with
layer-shell" the egui section above names as the most promising path to
revisit) hands back a raw `wl_shm` pool buffer per frame, not a GPU
surface -- pairing it with `egui-wgpu` would still mean building this
exact bridge, just starting one layer further down. So: hand-built glue,
on SCTK itself, combining two of its own
upstream examples (`examples/simple_layer.rs`'s layer-surface-plus-input
setup, `examples/wgpu.rs`'s raw-window-handle-to-`wgpu` recipe) rather
than porting either whole.

**Cursor-centring is real here**, not approximated -- the whole point of
this spike, and the thing the first-round toolkits above could not do
(iced: doesn't build; cxx-qt: output-centred, not cursor-centred, for a
documented reason; egui: `xdg_toplevel` has no positioning authority at
all). wlr-layer-shell grants that authority: anchoring `TOP | LEFT` with
`set_margin(top, 0, 0, left)` places the surface's corner at an *exact*
pixel offset from the focused output's own origin. No clamping is applied
-- `left`/`top` are used exactly as `cursor - half_size` computes them,
the same rule the Quickshell ring uses.

### The numbers

Measured the same way, same machine, same private headless sway +
`tools/fake-hyprctl.sh` + `grim`, via `nix develop -c bash
tools/gallery.sh egui-layershell`:

| | egui-layershell (this spike) | egui (eframe, no layer-shell) | cxx-qt (QML + LayerShellQt) |
|---|---|---|---|
| Layer-shell | **yes**, real wlr-layer-shell, screenshotted | no | yes (output-centred only) |
| Cursor-centring | **yes**, exact pixel offset, no clamping | no (xdg_toplevel has no positioning authority) | no (output-centred; see cxx-qt's own Limitation above) |
| Binary size (release) | 14.35 MB (11.15 MB stripped) | 13.13 MB (9.67 MB stripped) | 2.52 MB (1.70 MB stripped) |
| Idle RSS (hidden) | 72.9 MB | 90.5 MB | 112.6 MB |
| Shown RSS | 90.5 MB | 90.5 MB | 150.5 MB |
| Show-to-first-frame | **median 22.1 ms** over 10 runs (17.0-108.3 ms, first run an outlier -- see below) | median 10.1 ms over 10 runs | not measured (see cxx-qt's own note above) |
| Lines of code | 1038 (Rust; no QML/bridge split, it's all hand-rolled Wayland + wgpu glue) | 416 (Rust) | 307 Rust + 120 QML = 427 |
| Build time (release, cold) | 5m 03s | 3m 17s | 3m 31s |
| Build time (incremental) | ~9 s | ~7 s | ~9-14 s |
| Screenshot | [`docs/gallery/egui-layershell.png`](docs/gallery/egui-layershell.png) | [`docs/gallery/egui.png`](docs/gallery/egui.png) | [`docs/gallery/cxx-qt.png`](docs/gallery/cxx-qt.png) |

Idle RSS is *lower* than both first-round toolkits despite doing real GPU
rendering -- a plain SCTK + `wgpu` process has no Qt/QML engine or
eframe/winit's own window-and-event-loop scaffolding sitting idle behind
it, just a Wayland connection and an already-initialized `wgpu` device
(deliberately eager at startup, see the module doc, so "idle" means the
same thing here as it does for the other two: the whole renderer loaded,
nothing on screen yet). Show-to-first-frame's first-run outlier (108.3 ms
vs. a steady 17-34 ms after) is GPU/shader-pipeline warm-up on the very
first `show` -- `egui_wgpu::Renderer::new()` (shader module + render
pipeline compile) happens lazily on that first surface, not at daemon
startup, unlike `device`/`queue`; moving it earlier would flatten this at
the cost of not knowing the real surface format until a surface exists.
Not fixed here, said plainly instead.

### How hard it was, honestly

Three real things, in the order they bit:

1. **`wgpu::PresentMode::Mailbox` is not universally supported, and wgpu
   30 panics rather than falling back.** `Surface::configure()` with
   `Mailbox` crashed the daemon on its very first `show` --
   `wgpu error: Validation Error ... Requested present mode Mailbox is
   not in the list of supported present modes: [Fifo]` -- against this
   headless sway's GL backend. Fixed by using `Fifo`, the only mode
   `wgpu`'s own docs guarantee every backend supports; `Mailbox`/
   `Immediate` are documented to "crash if unsupported" rather than
   silently fall back, unlike `AutoVsync`/`AutoNoVsync`. Worth knowing
   for any wgpu-on-Wayland work.
2. **GLES needs an explicit display handle on Wayland, or presentation
   never works at all.** `wgpu::InstanceDescriptor`'s own `display` field
   doc says so directly ("required when intending to present on the
   platform, especially for Wayland") -- and the struct has no `Default`
   impl at all (that field is a `Box<dyn ..>`), forcing the question
   rather than letting it be silently skipped. `WaylandDisplay` in
   `main.rs` is a five-line `HasDisplayHandle` wrapper around the
   connection's own `wl_display` pointer for exactly this.
3. **This egui version's `Context` has `run_ui(&mut Ui)`, not the
   `run(&Context)`/`run_pass(&Context)` shown in egui's own upstream
   (ahead-of-release) docs.** Cost one wasted edit assuming the newer
   signature from reading egui's `main` branch instead of the pinned
   0.36.2 actually in `Cargo.lock`; fixed by reading the cargo registry's source
   for the *exact* version instead of upstream
   docs for the latest one -- the lesson being to check the pinned
   version's own source when a signature looks off, not a general
   "egui changed" assumption.

Past those three, the SCTK side (layer-shell surface creation, pointer/
keyboard handler wiring, the anchor+margin cursor math) came together in
one pass from SCTK's own `examples/simple_layer.rs` and `examples/wgpu.rs`
with no real surprises -- the crate's own examples really do cover "layer
surface" and "wgpu surface" as two separate, combinable pieces, which is
what made skipping a maintained all-in-one crate a reasonable choice
rather than a detour.

**Not verified, said plainly:** the highlighted-button/glow/arrow state
is implemented (`draw_ring()`'s own dead-zone + nearest-angle logic, the
same math as the `egui`/`cxx-qt` spikes above) but **not exercised by a
real pointer motion in this harness** -- tried, not just skipped:
`swaymsg seat - cursor set X Y` against this private headless sway
(`WLR_LIBINPUT_NO_DEVICES=1`, no real input device) warps the
compositor's own idea of the pointer position but does not emit a
`wl_pointer` enter/motion event to clients, checked with an added debug
print that never fired, not assumed. The committed screenshot therefore
shows the resting/dead-zone state only, same honest gap as cxx-qt's own
unmeasured show-to-first-frame above -- a harness limitation, not a code
path left untested by design.

### How close the look got to the reference

Closer than either first-round egui/cxx-qt screenshot, on the things that
were in scope: six rounded-square buttons (not circles, as the Quickshell
ring's `RingLayer.qml` `radiusFor()`), a caption
under *every* button always shown (not just the highlighted one, the
first egui prototype's gap), a centre disc with a separate small arrow
(not drawn here pointing anywhere useful in the committed screenshot,
since -- see above -- no pointer motion reached it; the arrow-drawing code
itself mirrors `RingLayer.qml`'s "separate shape, hidden in the dead
zone" rule), and a soft dark halo sized only to the ring's own footprint,
never full-screen.

Two honest gaps against the Quickshell ring (appring),
neither hidden:

- **The halo is not a real radial gradient.** `RingLayer.qml` uses
  `QtQuick.Shapes`' `RadialGradient`, a true one. egui has no built-in
  radial-gradient fill; this spike approximates one with four concentric,
  decreasing-opacity circles (`draw_ring()`'s own comment says so). Close
  at this size, but a deliberate stand-in, not a port.
- **The highlighted button's glow is two flat translucent squares behind
  it**, not `RingLayer.qml`'s own two-layer glow *plus* a border-colour
  change and a `Behavior`-animated scale/opacity transition -- this spike
  draws one static frame's worth of "highlighted", with no
  animation/easing at all (no `Theme.fast`/`Theme.easing` equivalent).
  Reasonable for a spike measuring show-to-first-frame and RSS, not a
  claim that the *feel* (the goal, not just the static
  look) matches.

Icons are text captions for every item here, as in the first-round
prototypes.

### Build and run it yourself

```sh
cd experiments/rust-ui
nix develop
cd egui-layershell && cargo build --release
./target/release/ring-eguilayershell show   # prints show-to-first-frame
./target/release/ring-eguilayershell hide
```
