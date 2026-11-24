<p align="center"><img alt="appring. hold. point. release." src="assets/logo/appring-banner.svg" width="640"></p>

<p align="center"><b>A radial menu for the desktop: hold a key, point, release to run.</b></p>

<p align="center">
  <a href="LICENSE"><img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-blue"></a>
  <img alt="Platform: Linux (Wayland)" src="https://img.shields.io/badge/platform-Linux%20(Wayland)-lightgrey">
</p>

**appring** is a radial menu. Hold a key: a ring of buttons appears around the pointer. Point in a direction
(the whole slice of the screen counts, never a small target), then release the
key or click to run that item. Groups open as a smaller ring around their own
button. Esc or a right click cancels; releasing in the centre does nothing. The
items are apps and commands from a JSON file you write. It is the kind of menu
OPie made popular in World of Warcraft, for your desktop.

```bash
git clone https://github.com/mirql/appring && cd appring
nix develop                          # quickshell and the test tools
just run                             # start it, hidden
just open                            # show the default menu (bind this to a key)
just commit                          # run the highlighted item (bind this to the key's release)
```

> [!NOTE]
> appring is young (0.1, unreleased). It runs on Linux with a Wayland
> compositor that has wlr-layer-shell (Hyprland, Sway, niri and others), built on
> [Quickshell](https://quickshell.org). macOS and Windows are planned, not started.
> There is no package yet: you run it from a checkout.

## Install

You need [Quickshell](https://quickshell.org) on your `PATH`. With Nix,
`nix develop` in a checkout gives you one. Then:

```bash
quickshell -p ring -d                # or: just run
```

Bind a key to open it, and its release to commit. On Hyprland:

```ini
bind  = SUPER, grave, exec, quickshell ipc -p /path/to/appring/ring call ring open ""
bindr = SUPER, grave, exec, quickshell ipc -p /path/to/appring/ring call ring commit
```

## Your menu

The ring reads `~/.config/ring-app/menu.json` each time it opens
(`$XDG_CONFIG_HOME/ring-app`, or `RING_APP_CONFIG_DIR`). Without one it shows
[`ring/default.json`](ring/default.json). `open "tools"` reads `menu-tools.json`
from the same folder.

```json
{
  "style": { "glowColor": "accent" },
  "items": [
    { "label": "Browser", "icon": "firefox", "run": ["firefox"] },
    { "label": "Terminal", "icon": "utilities-terminal", "run": ["foot"] },
    { "label": "Screenshot", "icon": "applets-screenshooter", "run": ["grim", "-g", "0,0 800x600", "/tmp/shot.png"] },
    { "label": "Tools", "icon": "applications-utilities", "items": [
      { "label": "Calculator", "icon": "accessories-calculator", "run": ["gnome-calculator"] }
    ] }
  ]
}
```

- `run` is an argv list, started directly, without a shell. For a shell
  command, say so: `["sh", "-c", "…"]`.
- `icon` is an icon name from your icon theme.
- `items` makes a group: its items open as a smaller ring. Groups go one level deep.
- `style` (top level, per group, per item): `shape` (`rounded-square` or
  `circle`), `cornerRadius`, `size`, `glowColor` (`accent`, `ok`, `warn`,
  `error`, `muted`, `dim`, `text`), `glowSize`, `ringRadius`, `captionSize`.

Settings by environment: `RING_APP_RELEASE_KEY` (`Super`, `Alt`, `Ctrl`, `Shift`),
`RING_APP_REST_MS` (resting on a group opens it, default 250),
`RING_APP_REDUCED_MOTION=1`. More in [`ring/shell.qml`](ring/shell.qml).

## Development

```bash
nix develop
just check       # the checks a PR must pass: secret scan and the off-screen tests
just test        # only the tests: a headless compositor, never your desktop
```

The tests draw the ring in a headless sway with a private bus, drive it with a
virtual pointer, check every step and save screenshots. See
[CONTRIBUTING.md](CONTRIBUTING.md). [`experiments/`](experiments/) has earlier
prototypes in Rust (iced, cxx-qt, egui) and what they showed.

Found a security problem? Please report it privately: [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE)
