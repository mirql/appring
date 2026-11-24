<p align="center"><img alt="appring. hold. point. release." src="assets/logo/appring-banner.svg" width="640"></p>

<p align="center"><b>A radial menu for the desktop: hold a key, point, release to run.</b></p>

<p align="center">
  <a href="LICENSE"><img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-blue"></a>
  <img alt="Platform: Linux (Wayland)" src="https://img.shields.io/badge/platform-Linux%20(Wayland)-lightgrey">
  <a href="https://quickshell.org"><img alt="Built on Quickshell" src="https://img.shields.io/badge/built%20on-Quickshell-8A2BE2"></a>
  <a href="#install"><img alt="Tested on Hyprland" src="https://img.shields.io/badge/tested%20on-Hyprland-58E1FF?logo=hyprland&logoColor=white"></a>
  <br>
  <a href="https://github.com/mirql/appring/stargazers"><img alt="GitHub stars" src="https://img.shields.io/github/stars/mirql/appring"></a>
  <a href="https://github.com/mirql/appring/commits/main"><img alt="Last commit" src="https://img.shields.io/github/last-commit/mirql/appring"></a>
  <a href="https://github.com/mirql/appring/graphs/commit-activity"><img alt="Commit activity" src="https://img.shields.io/github/commit-activity/m/mirql/appring"></a>
  <!-- ALL-CONTRIBUTORS-BADGE:START - Do not remove or modify this section -->
<a href="#contributors"><img alt="All contributors" src="https://img.shields.io/badge/all_contributors-1-orange"></a>
<!-- ALL-CONTRIBUTORS-BADGE:END -->
</p>

> *Once you've cast spells with **OPie**, opening Firefox the normal way just feels **slow**.*
>
> — **Askar**, author of appring

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
> appring is young (0.1, unreleased). It runs on Linux under Wayland, built on
> [Quickshell](https://quickshell.org). For now we build and test it under Hyprland;
> other compositors have not been tried yet. macOS and Windows are planned, not started.
> There is no package yet: you run it from a checkout.

## Why

Launchers make you type, docks and menus make you aim. A radial menu asks for
neither: your hand learns the directions, and after a few days you pick an item
without looking.

- **Directions, not targets.** The whole slice of the screen counts, so a quick
  flick is enough.
- **Your menu, your way.** Apps and commands from a JSON file, groups for the rest,
  a style per item if you want one.
- **Out of the way.** Nothing on screen until you hold the key, gone when you
  release it.

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

## Limits

> [!WARNING]
> appring runs what your menu file says, as you: treat `menu.json` like a shell
> script. While open it is a full-screen overlay with keyboard focus; another program
> in your Wayland session can draw a lookalike, and anything that can call
> Quickshell's IPC as your user can open it and run the highlighted item. Linux and
> Wayland only for now. More in [SECURITY.md](SECURITY.md).

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

## Contributing

Issues, ideas and PRs are welcome. Good places to start:

- **[Good first issues](https://github.com/mirql/appring/labels/good%20first%20issue).**
  Small, self-contained tasks, each saying where to start and what done looks like.
- **Other compositors.** Try it on Sway, niri or another wlr-layer-shell compositor
  and tell us what happens, or add a test for it.
- **Menus and styles.** A menu you like, or a style that looks good, makes a fine
  example for others.

Questions go to [Discussions](https://github.com/mirql/appring/discussions).

## Contributors

Thanks to everyone who makes appring what it is
([emoji key](https://allcontributors.org/docs/en/emoji-key)):

<!-- ALL-CONTRIBUTORS-LIST:START - Do not remove or modify this section -->
<!-- prettier-ignore-start -->
<!-- markdownlint-disable -->
<table>
  <tbody>
    <tr>
      <td align="center" valign="top" width="14.28%"><a href="https://github.com/askaramirov"><img src="https://avatars.githubusercontent.com/u/59274133?size=80" width="80px" height="80px" alt="Askar Amirov"/><br /><sub><b>Askar Amirov</b></sub></a><br /><a href="https://github.com/mirql/appring/commits?author=askaramirov" title="Code">💻</a> <a href="https://github.com/mirql/appring/commits?author=askaramirov" title="Documentation">📖</a> <a href="#design-askaramirov" title="Design">🎨</a> <a href="https://github.com/mirql/appring/commits?author=askaramirov" title="Tests">⚠️</a> <a href="#ideas-askaramirov" title="Ideas, Planning, & Feedback">🤔</a> <a href="#maintenance-askaramirov" title="Maintenance">🚧</a></td>
    </tr>
  </tbody>
</table>

<!-- markdownlint-restore -->
<!-- prettier-ignore-end -->

<!-- ALL-CONTRIBUTORS-LIST:END -->

Helped in a way that isn't a commit? Comment on any issue or PR:
`@all-contributors please add @name for ideas, review` (and so on).

## License

[MIT](LICENSE)
