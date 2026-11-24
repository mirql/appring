//! Tiny cxx-qt + QML POC of the "ring": starts hidden, `ring-cxxqt
//! show`/`hide` toggles a transparent wlr-layer-shell overlay (via
//! LayerShellQt's QML plugin, `import org.kde.layershell`) with six
//! rounded-square buttons on a circle, the one in the pointer's direction
//! glowing, a centre dot.
//!
//! Honest limitation: the overlay is centred on the **focused output**
//! (`LayerShellQt.Window.anchors: AnchorNone`, `screenConfiguration:
//! ScreenFromCompositor` -- wlr-layer-shell centres an unanchored surface
//! on its output), not on the exact cursor position a radial menu needs.
//! True cursor-centring needs `LayerShellQt::Window::setMargins()`, a
//! plain C++ call with no QML-exposed equivalent (`margins` is a QMargins
//! property, not one of Qt's QML-auto-converted value types); that in turn
//! needs LayerShellQt's C++ headers, which this nixpkgs packaging does not
//! install (`kdePackages.layer-shell-qt.dev` ships no `include/` at all --
//! checked, not assumed) -- building them from source was out of this
//! spike's time budget. See `spikes/rust-ui/README.md`.

mod bridge;

use cxx_qt::casting::Upcast;
use cxx_qt::CxxQtThread;
use cxx_qt_lib::{QGuiApplication, QQmlApplicationEngine, QString, QUrl};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, OnceLock};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

pub fn now_nanos() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos() as u64
}

fn socket_path() -> PathBuf {
    let dir = std::env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| "/tmp".to_string());
    PathBuf::from(dir).join("appring-spike-cxxqt.sock")
}

pub struct Shared {
    pub generation: AtomicU64,
    pub ack_generation: AtomicU64,
    pub ack_nanos: AtomicU64,
}

static SHARED: OnceLock<Arc<Shared>> = OnceLock::new();

pub fn shared() -> &'static Arc<Shared> {
    SHARED.get_or_init(|| {
        Arc::new(Shared {
            generation: AtomicU64::new(0),
            ack_generation: AtomicU64::new(0),
            ack_nanos: AtomicU64::new(0),
        })
    })
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
            eprintln!("ring-cxxqt: not running ({})", path.display());
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
                    eprintln!("ring-cxxqt: daemon did not start in time");
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

pub fn accept_loop(qt_thread: CxxQtThread<bridge::qobject::RingBridge>) {
    let path = socket_path();
    if path.exists() {
        if UnixStream::connect(&path).is_err() {
            let _ = std::fs::remove_file(&path);
        } else {
            eprintln!("ring-cxxqt: already running ({})", path.display());
            std::process::exit(1);
        }
    }
    let listener = match UnixListener::bind(&path) {
        Ok(l) => l,
        Err(e) => {
            eprintln!("ring-cxxqt: bind {}: {e}", path.display());
            std::process::exit(1);
        }
    };
    eprintln!("ring-cxxqt: listening on {}", path.display());
    for conn in listener.incoming().flatten() {
        let qt_thread = qt_thread.clone();
        std::thread::spawn(move || handle_conn(conn, qt_thread));
    }
}

fn handle_conn(mut conn: UnixStream, qt_thread: CxxQtThread<bridge::qobject::RingBridge>) {
    let mut reader = BufReader::new(conn.try_clone().expect("clone stream"));
    let mut line = String::new();
    if reader.read_line(&mut line).unwrap_or(0) == 0 {
        return;
    }
    match line.trim() {
        "show" => {
            let t_recv = now_nanos();
            let shared = shared();
            let my_gen = shared.generation.fetch_add(1, Ordering::SeqCst) + 1;
            let _ = qt_thread.queue(|mut bridge| {
                bridge.as_mut().set_visible(true);
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
            shared().generation.fetch_add(1, Ordering::SeqCst);
            let _ = qt_thread.queue(|mut bridge| {
                bridge.as_mut().set_visible(false);
            });
            let _ = writeln!(conn, "hidden");
        }
        other => {
            let _ = writeln!(conn, "unknown command {other:?}");
        }
    }
}

// --------------------------------------------------------------- main ----

fn main() {
    let args: Vec<String> = std::env::args().collect();
    match args.get(1).map(String::as_str) {
        Some("show") => {
            client_run(Cmd::Show);
            return;
        }
        Some("hide") => {
            client_run(Cmd::Hide);
            return;
        }
        None => {}
        Some(other) => {
            eprintln!("usage: {} [show|hide]  (bare: run as the hidden daemon)", args[0]);
            eprintln!("unknown argument: {other}");
            std::process::exit(2);
        }
    }

    // Without this, nothing in src/bridge.rs is ever *referenced* from
    // main.rs (only named as a type parameter), so rustc/the linker can
    // (and did, silently -- drop its QML-module registration code as
    // dead code. This macro forces it to stay linked in.
    cxx_qt::init_qml_module!("com.mirql.ring");

    let mut app = QGuiApplication::new();
    let mut engine = QQmlApplicationEngine::new();

    eprintln!("ring-cxxqt: created QGuiApplication + QQmlApplicationEngine");
    Upcast::<cxx_qt_lib::QQmlEngine>::upcast_pin(engine.as_mut().unwrap())
        .set_output_warnings_to_standard_error(true);
    // NB: `let _ = …` drops a QMetaObjectConnectionGuard immediately
    // (disconnecting it on the spot, before `load()` is even called) --
    // it must be bound to keep the connection alive. Caught by testing,
    // not assumed.
    let _creation_failed_guard = engine
        .as_mut()
        .unwrap()
        .on_object_creation_failed(|_engine, _url| {
            eprintln!("ring-cxxqt: QML object creation FAILED");
        });
    let _created_guard = engine.as_mut().unwrap().on_object_created(|_engine, obj, _url| {
        eprintln!("ring-cxxqt: QML object CREATED, ptr null={}", obj.is_null());
    });

    // load_data(), not load(url) against the qrc path cxx-qt-build's
    // QmlModule is documented to embed resources under: that path did not
    // resolve here (QML object creation failed, no RingBridge::initialize(),
    // no warning text even with output_warnings_to_standard_error(true) --
    // and a trivial inline load_data() of plain QtQuick QML worked fine in
    // the same binary/environment, isolating the problem to the resource
    // path rather than Qt/Wayland/QGuiApplication setup). Reading the real
    // QML from disk at compile time and loading it as data sidesteps the
    // qrc path question entirely; the module registration + LayerShellQt
    // import still go through the normal (working) mechanism.
    let qml_src = include_str!("../qml/Ring.qml");
    let data = cxx_qt_lib::QByteArray::from(qml_src.as_bytes());
    let base = QUrl::from(&QString::from(concat!(
        "file://",
        env!("CARGO_MANIFEST_DIR"),
        "/qml/Ring.qml"
    )));
    eprintln!("ring-cxxqt: loading qml/Ring.qml via load_data()");
    engine.as_mut().unwrap().load_data(&data, &base);
    eprintln!("ring-cxxqt: load() returned, entering exec()");

    app.as_mut().unwrap().exec();
}
