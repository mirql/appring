# Security policy

## Reporting a vulnerability

Please **do not open a public issue.** Report it privately through GitHub:
**Security → Report a vulnerability** on this repository.

Include what you can: what you ran, what happened, what should have happened, and your
appring version and system. We will acknowledge the report, keep you updated, and credit
you in the advisory unless you prefer otherwise.

## In scope

- The ring running a command other than the one in the menu file, or with
  different arguments (`run` is started as an argv list, never through a shell).
- Anything that lets another program or user change what the ring runs.

Not in scope: what the commands in your own menu file do. The menu file is
yours, and the ring runs what it says.

## Known limits

- The ring is a full-screen overlay with keyboard focus while open. Another
  program with access to your Wayland session can draw lookalike windows; the
  ring does not defend against that.
- Anyone who can call Quickshell's IPC as your user can open the ring and
  commit its highlighted item.
- On macOS, another process running as you can talk to the command socket
  `appring.sock` in your own temporary folder (mode 0600) and open, commit
  or stop the ring.
  The socket is not a privilege boundary between your own programs.

## Supported versions

Only the latest release gets security fixes.
