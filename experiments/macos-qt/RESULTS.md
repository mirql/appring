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

## Results (2026-11-24 and 2026-11-27, macOS 27.2 on Apple Silicon, Qt 6.12 from nixpkgs)

What works:

- Builds with Nix on the Mac. nixpkgs has Qt 6 (qtbase, qtdeclarative, qtsvg) for
  macOS; Quickshell is Linux only.
- The ring draws on macOS from the unchanged QML: items, icons, glow, centre ring,
  chevron, the highlight following the pointer's angle. Checked with Qt's offscreen
  platform (a window grab, the commands above), which needs no screen recording right.
- On the real screen, tried by hand with the mouse: the ring opens at the cursor, the
  highlight follows the pointer, a click picks an item (it prints what it would run)
  and closes the ring.
- The Papirus icon package is marked Linux only in nixpkgs; its source (plain image
  files) works on macOS.

What it does not do:

- No global hotkey: it opens when started, not on a held key (that needs an event
  tap and the Accessibility permission), and nothing happens on release.
- No menu bar item and no app bundle: it is a command started from a terminal.
- No `menu.json` or `appearance.json`: a fixed sample menu, appring's default look.
- Icons by name from Papirus (a Linux theme), not apps' icons from their `.app` bundles.
- Runs nothing: a click only prints the item's label.
- The window is not moved to the current screen or Space.
