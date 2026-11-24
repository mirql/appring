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
