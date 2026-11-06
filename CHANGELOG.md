# Changelog

Each release's GitHub notes are taken from its section here by `publish.sh`.

## 0.2.0

The first public release: RDPGate is now signed, notarized by Apple, and
installable with Homebrew.

- **One-click RDP from the menu bar.** Keep a list of targets, each with its
  own host, credentials, display and redirection settings, and connect through
  FreeRDP without touching a terminal.
- **Per-target SOCKS5 proxy.** Connect directly, through a shared default
  proxy, or through a proxy of the target's own. Hostnames are resolved by the
  proxy, so internal names work.
- **A pre-flight that tells you why.** Before connecting, RDPGate makes a real
  connection through the proxy and reports what went wrong, such as
  `host unreachable from the proxy`, in seconds rather than after a two-minute
  hang.
- **Shared identities.** Many servers on one AD account? Define the username,
  domain and password once and pick it per target. Rotating the password is a
  single edit.
- **Duplicate a target.** Copy an existing target into a new, unsaved editor,
  then change only what differs. The password is never copied.
- **Passwords stay private.** They are stored in the login keychain, never in
  the config file, and are handed to FreeRDP over stdin, so they never appear
  in `ps`.
- **Your config is never overwritten.** If `config.json` can't be read,
  RDPGate starts read-only and shows the problem, instead of saving an empty
  list over your targets.

Requires an Apple Silicon Mac with macOS 14 or newer. Intel support is planned.
