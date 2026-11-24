# Changelog

## Unreleased

## 0.1.0

- A package (`nix run github:mirql/appring`, `nix profile install github:mirql/appring`):
  the `appring` command (`run`, `open`, `commit`, `cancel`, `toggle`, `settings`, `stop`,
  `restart`; `open` and `settings` start it when needed), a desktop entry and the icons.
- The code names follow the app's name: the folder `appring/` (was `ring/`), the config
  folder `~/.config/appring/`, the environment `APPRING_*`, the IPC target `appring`, the
  layer namespace `appring`. The old ones still work: `RING_APP_*`, the IPC target
  `ring`, and `~/.config/ring-app/` while there is no `~/.config/appring/` (the ring says
  once that it can be moved).
- A new look after OPie: square icon buttons with a thin border in each slice's own
  colour, taken from its icon; no backdrop and no captions by default; a centre ring
  in two halves that spins, lit in the focused slice's colour with a soft glow
  outside it, faint white when nothing is focused; a chevron that swings round to
  the cursor; the focused button grows a little; groups get a flyout arrow. New
  style keys `caption` and `backdrop`; `glowColor` takes `auto` (the default) and
  `#rrggbb`.
- Opening zooms in; running an item flashes its button (a pop, a light, a ring
  outward); closing fades out by default (or zooms, spirals, or goes at once).
- The ring's radius grows with the number of items (at least 110 px); buttons are
  48 px; the dead zone is 40 px; satellites are 0.8x.
- An appearance window (`appring settings`) with a live
  preview, saved to `appearance.json`: ring scale, dead zone, open at the cursor,
  gap between slices, instant pointer, enlarge selected slice, colours from icons,
  slice labels, animations, closing, flash on run, the animation speeds, centre
  spin, glow strength, flash pop.
- The name is now appring (repo `mirql/appring`, was `mirql/ring-app`), with a new
  logo and app icons (icon name `com.mirql.appring`).
- First version of appring: the radial menu on Quickshell (Linux, Wayland): angle-based
  selection over the whole screen, centred on the cursor, groups as satellite
  rings, a JSON menu re-read on every open, a style cascade, commit by key
  release, click or IPC.
- Off-screen tests (`just test`): a headless sway, a virtual pointer, fake apps.
- `experiments/rust-ui/`: earlier Rust prototypes (iced, cxx-qt, egui) and their results.
