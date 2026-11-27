# Experiments

Prototypes kept for what they showed, not maintained, and not part of
`just check`. Each folder has its own `flake.nix` and notes.

| Folder | What it tried | Result |
|---|---|---|
| [rust-ui/](rust-ui/) | The ring as a native Rust app: iced, cxx-qt (QML), egui, and egui on a real layer-shell surface | iced did not build; cxx-qt worked but could only centre on the monitor; plain egui could not position itself on Wayland; egui on layer-shell worked, centred on the cursor. Numbers and notes: [rust-ui/RESULTS.md](rust-ui/RESULTS.md) |
| [macos-qt/](macos-qt/) | appring's own ring QML (unchanged) in a plain Qt window, for macOS, with stand-ins for the Quickshell pieces | Builds with Nix and draws the ring on macOS (Apple Silicon, Qt 6.12 from nixpkgs), also on the real screen with the mouse; no hotkey, menu bar or `menu.json` yet. [macos-qt/RESULTS.md](macos-qt/RESULTS.md) |

These are Linux/Wayland only, like the ring today, except `macos-qt/`.
