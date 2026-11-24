# macOS spike: appring's ring in a plain Qt window

Question: can appring's ring run on macOS, where Quickshell does not exist?

## What it is

A small Qt 6 app (`main.cpp`, `Spike.qml`) that loads appring's own drawing files
(`RingLayer.qml`, `Ring.qml`, `Theme.qml`, `Settings.qml`, copied unchanged at build
time) in a borderless, transparent, always-on-top window. `shim/` stands in for the
few Quickshell pieces those files use: `Quickshell.env`/`iconPath`, `Singleton`,
`IconImage`, `FileView`/`JsonAdapter` (reads nothing: default settings).

```sh
nix build "path:$PWD?dir=experiments/macos-qt"   # from the repo root
./result/bin/appring-spike                       # point, click to "run", Esc to quit
# without a screen, a screenshot of what it draws:
QT_QPA_PLATFORM=offscreen SPIKE_AT=400,400 SPIKE_POINT=480,330 \
  SPIKE_SHOT=$PWD/shot.png SPIKE_QUIT_AFTER=4000 ./result/bin/appring-spike
```

## Results (2026-11-24, macOS 27.2 on Apple Silicon, Qt 6.12 from nixpkgs)

- Builds with Nix on the Mac. nixpkgs has Qt 6 (qtbase, qtdeclarative, qtsvg) for
  macOS; Quickshell is Linux only.
- The ring draws on macOS from the unchanged QML: items, icons, glow, centre ring,
  chevron, the highlight following the pointer's angle. Checked with Qt's offscreen
  platform (a window grab), since the session used had no screen recording right.
- The Papirus icon package is marked Linux only in nixpkgs; its source (plain image
  files) works on macOS.

## Not tried yet

- The window on the real screen (cocoa): needs someone at the Mac.
- A global hotkey with press and release (an event tap; needs the Accessibility
  permission), the window over the current screen and Space, apps' icons from
  `.app` bundles, running commands, reading `menu.json` and `appearance.json`.
