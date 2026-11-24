# appring: a radial menu for the desktop. See README.md.
# (mirql conventions 2026-11-19)

default:
    @just --list

# The gate a PR must pass: offline, no secrets.
check: secret-scan test

# The ring, off-screen: a headless sway, a private bus, fake apps. Never your desktop.
test:
    env -u DISPLAY -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE -u SWAYSOCK \
      GALLERY_OUT="${GALLERY_OUT:-$(mktemp -d /tmp/appring-gallery.XXXXXX)}" \
      bash tools/gallery.sh

# Fail if a credential is in the git history or in the files as they are now
secret-scan:
    gitleaks git --no-banner --redact --log-level warn .
    gitleaks dir --no-banner --redact --log-level warn .

# Build the package: ./result (bin/appring, the app, the desktop entry, the icons)
build:
    nix build -L .#default

# Build the package and check it off-screen: the appring command, the desktop entry, the icons
test-package:
    nix build -L .#default
    tools/package-check.sh result

# Tag VERSION on origin/main (as fetched now) and publish a GitHub release with its CHANGELOG section as the notes
release version:
    #!/usr/bin/env bash
    set -euo pipefail
    git fetch -q origin
    sha=$(git rev-parse origin/main)  # one commit for every check, the prompt and the tag
    grep -q 'version = "{{version}}";' <(git show "$sha":nix/package.nix) \
        || { echo "nix/package.nix at ${sha:0:7} is not {{version}}"; exit 1; }
    notes=$(git show "$sha":CHANGELOG.md | awk '/^## {{version}}$/ {on=1; next} /^## / {on=0} on')
    [ -n "$(echo "$notes" | tr -d '[:space:]')" ] || { echo "no '## {{version}}' section in CHANGELOG.md at ${sha:0:7}"; exit 1; }
    ! git ls-remote --exit-code --tags origin "v{{version}}" >/dev/null || { echo "v{{version}} exists already"; exit 1; }
    echo "$notes"
    read -rp "Publish v{{version}} on ${sha:0:7} with these notes? [y/N] " ok
    [ "$ok" = y ] || exit 1
    gh release create "v{{version}}" --target "$sha" --title "appring {{version}}" --notes "$notes"

# ── on your own desktop ─────────────────────────────────────────────────

# Start the ring in the background (it stays hidden until opened).
run:
    quickshell -p appring -d

# Stop the running ring.
stop:
    quickshell kill -p appring

# Open a menu: "" for menu.json, a name for menu-<name>.json.
open name="":
    quickshell ipc -p appring call appring open "{{name}}"

# Run the highlighted item (bind this to the key release).
commit:
    quickshell ipc -p appring call appring commit

# Close without running anything.
cancel:
    quickshell ipc -p appring call appring cancel
