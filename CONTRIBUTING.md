# Contributing to appring

Thanks for helping. Changes to appring are judged first by one question: does it make
picking an action faster and calmer, without making the ring harder to
understand?

We try to be kind, humble and curious here, and ask the same of everyone who joins in.

## Before you start

- **Bugs:** open an issue with the bug template.
- **Features:** open an issue first, so we can agree on the shape before you write code.
- **New here?** The [good first issues](https://github.com/mirql/appring/labels/good%20first%20issue)
  are small and stand alone: each says where to start and what done looks like.
- **Security problems:** do not open an issue. See [SECURITY.md](SECURITY.md).

## Development

```bash
nix develop
just check       # the checks a PR must pass
just test        # the off-screen tests only
```

The tests never touch your desktop: a headless sway in a private runtime dir,
a private D-Bus, a fake Hyprland IPC and fake apps. They take about two
minutes. Screenshots land in the folder `just test` prints.

To try the ring on your own Wayland desktop: `just run`, then `just open`.

## Layout

| path | what |
|---|---|
| `nix/` | The package: `package.nix` (the version), the `appring` command (`appring.sh`), the desktop entry |
| `appring/` | The app, a Quickshell root: `shell.qml` (entry, settings), `Radial.qml` (behaviour), `Ring.qml` and `RingLayer.qml` (drawing), `Theme.qml`, `default.json` |
| `tools/gallery.sh` | The off-screen test scene: every step, with screenshots |
| `tools/check-radial.py` | What each step of the scene must show |
| `tools/package-check.sh` | Checks a built package off-screen (`just test-package`) |
| `tools/` (the rest) | Test helpers: a virtual pointer, a fake Hyprland IPC, a fake app, a process reaper |
| `experiments/` | Earlier prototypes, not maintained, not in `just check` |
| `assets/` | The logo set and app icons for Linux, Windows and macOS ([assets/README.md](assets/README.md)) |

## Pull requests

- One change per PR. The PR description starts with `Closes #N.`
- `just check` passes; a behaviour change comes with its step in
  `tools/gallery.sh` and its expectation in `tools/check-radial.py`.
- A line under "Unreleased" in `CHANGELOG.md` for anything a user would notice.
- We merge with squash: the PR title becomes the commit title, so make it say what changes.
