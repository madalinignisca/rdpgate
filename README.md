# RDPGate

A small macOS menu-bar app for **RDP connections**. It does not implement RDP —
it drives [FreeRDP](https://www.freerdp.com/), keeps a list of targets with
per-target settings, and optionally routes each one through a SOCKS5 proxy.

## Who it is for

Admins working in environments where the VPN and SOCKS5 proxy are managed by
themselves. The app does not force any connectivity solution and never tries to
bring one up — it works on top of whatever you already use, and optionally uses
a SOCKS5 proxy per target.

It deliberately does not touch SSH. On macOS that is already comfortable in a
terminal, and wrapping it would add nothing.

## Install

Apple Silicon, macOS 14 or newer, with [Homebrew](https://brew.sh):

```sh
brew install --cask madalinignisca/rdpgate/rdpgate
```

This installs FreeRDP as a dependency. The app is signed with a Developer ID and
notarized by Apple; you can check that yourself:

```sh
spctl -a -vv /Applications/RDPGate.app     # source=Notarized Developer ID
codesign -dvv /Applications/RDPGate.app    # flags=0x10000(runtime)
```

Menu-bar only (`LSUIElement`) — no Dock icon.

`brew upgrade` updates both RDPGate and FreeRDP. `brew uninstall --cask rdpgate`
removes the app and keeps your configuration; add `--zap` to delete
`~/Library/Application Support/RDPGate` as well. Saved passwords stay in the
login keychain either way (services `local.rdpgate` and
`local.rdpgate.identity`); remove them with Keychain Access if you want them gone.

Intel Macs are not supported yet.

### FreeRDP from elsewhere

The app looks for `sdl-freerdp` in the usual Homebrew locations
(`/opt/homebrew/bin`, `/usr/local/bin`), or uses the binary set in Settings.

## Build from source

```sh
./build.sh            # produces RDPGate.app, ad-hoc signed, for this Mac
open RDPGate.app
```

Needs Xcode (Swift 6). Local builds run on the Mac that built them; for anyone
else, use a release.

## Per-target settings

Each target carries its own configuration, so a mixed estate works without
compromise:

- **Host, port, name**
- **Network path** — direct, the shared default proxy, or its own proxy
- **Credentials** — its own username, domain and optional keychain-stored
  password, or a **shared identity** (see Credentials)
- **Display** — dynamic resize or a fixed size, and the `/gfx` toggle
- **Redirection** — audio, clipboard, drives, each off or on per target
- **Extra FreeRDP flags**, with a live preview of the exact command line

The default proxy in Settings is optional. Leave it blank and targets set to
"Default proxy" simply connect directly.

## Reachability

There is no background monitoring — you know your own environment. What the app
does is check the path **at the moment you use it**:

- **Test** on any target, on demand
- An automatic pre-flight before connecting (switchable in Settings)

This exists because a proxy that is listening tells you nothing about whether
the far side can *route*. A tunnel is often up while the VPN behind it is down,
and FreeRDP's failure mode there is a window that hangs for two minutes and then
vanishes. The pre-flight performs a real SOCKS5 CONNECT and reports what came
back — `host unreachable from the proxy`, `proxy closed the connection without
replying` — in a couple of seconds.

Hostnames are sent as domain names (ATYP `0x03`) so the **proxy** resolves them.
Internal names that do not resolve on your Mac work correctly.

## Credentials

Passwords go in the **login keychain**, never in `config.json`. Items are stored
per target UUID with `kSecAttrAccessibleWhenUnlocked` — readable only while the
Mac is unlocked, and not synced to iCloud.

They are handed to FreeRDP over **stdin** using `/from-stdin`, not as
`/p:<password>`. That matters: command-line arguments are visible in `ps` output
to every process on the machine, so a saved password passed that way would leak
to any local process that cared to look.

Leave "Save password" off and FreeRDP prompts each time.

**Shared identities.** Many servers often share one AD account. Define it once in
Settings → Shared identities (username, domain, password) and pick it in each
target's editor. The password is stored once in the keychain, under a separate
service (`local.rdpgate.identity`), so rotating it is a single edit. An identity
cannot be deleted while targets still use it.

## The `/gfx` toggle

If a session opens small and refuses to resize when you go fullscreen, turn on
**RDP8 graphics pipeline (`/gfx`)** for that target.

Dynamic resizing rides the Display Control dynamic virtual channel. Windows 11
and newer builds generally negotiate it only when the graphics pipeline is also
enabled, while Server 2019 and older still honour the legacy path. The FreeRDP
command line does not enable `/gfx` by default — which is why the same host can
resize fine in Remmina (which does enable it) and not from a plain command line.

## Configuration

`~/Library/Application Support/RDPGate/config.json` — plain JSON, no secrets,
safe to keep in version control.

If the file exists but cannot be read (broken JSON, wrong permissions), RDPGate
starts read-only: it shows the error in the menu and never saves over the file.
Fix or restore it, then reopen the app.

## Releasing

Two scripts, kept separate so that nothing public happens by accident:

| Script | Does | Public? |
|---|---|---|
| `release.sh X.Y.Z` | build, Developer ID sign (hardened runtime, no entitlements), notarize, staple, zip, sha256 | no — Apple receives the build for notarization |
| `publish.sh X.Y.Z` | tag, GitHub release, verify the uploaded asset, update the tap | yes |

Environment:

- `RDPGATE_SIGN_ID` — the "Developer ID Application: …" identity in the login keychain
- `RDPGATE_NOTARY_PROFILE` — a profile created once with `xcrun notarytool store-credentials`
- `RDPGATE_TAP_DIR` — a clone of `madalinignisca/homebrew-rdpgate`

Released versions are immutable: never rebuild or re-upload an existing version,
bump the patch number instead.

### Architectures

Each release asset holds one architecture: `RDPGate-X.Y.Z-arm64.zip`. Releases are
currently built on Apple Silicon only.

Intel builds are meant to come from a separate Intel Mac running the same
`release.sh` (it builds for the Mac it runs on) and producing
`RDPGate-X.Y.Z-x86_64.zip` for the same version. When that exists:

- upload the second zip to the same GitHub release;
- in the cask, drop `depends_on arch: :arm64` and switch to per-architecture
  values — `arch arm: "arm64", intel: "x86_64"`, a `url` using `#{arch}`, and
  `sha256 arm: "…", intel: "…"`;
- teach `publish.sh` to update both sha256 values (it currently rewrites a single one);
- check the Xcode toolchain on that Mac still builds x86_64 (Xcode 27 marks it deprecated).

