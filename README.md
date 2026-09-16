# CmdTab

MRU window switcher for macOS. Two shortcuts, no thumbnails.

| Shortcut  | Cycles                                              | Forward | Backward |
|-----------|-----------------------------------------------------|---------|----------|
| `Cmd+Tab` | All windows on the current Space, across all screens | `Tab`   | `` ` ``  |
| ``Cmd+` `` | Windows of the frontmost app only                   | `` ` `` | `Tab`    |

Hold `Cmd`, press the cycle key as many times as you like, release `Cmd` to switch.
A small text HUD shows app icon + window title. Nothing is raised until you let
go of `Cmd`, so there is no flicker.

While still holding `Cmd`:

- **`Esc`** widens the list to **every Space**, including minimized windows, each
  row tagged with its Space (`Desktop 2`, `Full Screen`). Press `Esc` again to
  narrow back. The current Space's windows stay at the head of the widened list,
  so the highlight never jumps. Picking a window on another Space switches to it.
- **`.`** (i.e. `Cmd+.`) cancels without switching.

## Build & install

```sh
make install     # builds, ad-hoc signs, copies to /Applications
open /Applications/CmdTab.app
```

Grant **System Settings → Privacy & Security → Accessibility → CmdTab**.
The app polls once a second, so it starts working as soon as you flip the toggle,
no relaunch needed.

Other targets: `make run` (run from `build/`), `make stop`, `make uninstall`, `make clean`.

## Signing

`make` signs with a self-signed certificate that `scripts/make-cert.sh` creates in
your login keychain on first build. This is not cosmetic: macOS keys the
Accessibility grant to the app's *designated requirement*, and an ad-hoc
signature's requirement is `cdhash H"..."`, a hash of the binary, different on
every build, so the permission silently dies each time you rebuild. A certificate
gives a requirement that does not move:

```
designated => identifier "com.krikava.cmdtab" and certificate leaf = H"ac6efd…"
```

So you grant Accessibility once and rebuilds keep it. The certificate needs no
trust settings and no admin password. `codesign` is happy with an untrusted
self-signed identity, and Gatekeeper never sees a locally built app.

`make reset-permissions` is only for clearing a grant made under a *different*
identity, i.e. the one-time migration off ad-hoc signing, or if you delete the
certificate. To start over:

```sh
security delete-certificate -c "CmdTab Self-Signed"
make reset-permissions && make install
```

## How it works

- **Hotkeys**: a `CGEventTap` at `.cgSessionEventTap` head-inserts ahead of the
  system switcher and swallows the chord (`HotkeyTap.swift`).
- **MRU order**: derived from the `CGWindowList` front-to-back z-order rather
  than from tracking focus events. macOS raises a window when it is focused, so
  z-order *is* MRU, and it cannot go stale or leak (`WindowEnumerator.swift`).
- **Window titles**: read over the Accessibility API, not `kCGWindowName`, so
  the app never needs Screen Recording permission. The two are correlated via
  `_AXUIElementGetWindow`, a private-but-stable SPI (`PrivateAX.swift`).
- **Filtering**: AX subrole `AXStandardWindow` or `AXDialog`, plus a non-zero
  CGWindowID. In the default scope, `kCGWindowListOptionOnScreenOnly` also keeps
  minimized and off-Space windows out.
- **Spaces**: `CGSCopyManagedDisplaySpaces` for the layout and labels, then
  `CGSCopySpacesForWindows` per window for membership (`CGSSpaces.swift`).

### Why there is a registry

`kAXWindowsAttribute` reports an app's windows on the **current Space only**,
plus its minimized ones. Windows on another Space are invisible to it. Measured
on a live session, from Desktop 2:

```
Slack   id=114  2560x1410 @(0,30)  alpha=1.00  in CGWindowList  →  AX reports 0 windows
Chrome  id=254  minimized                      in CGWindowList  →  AX reports it fine
```

So the widened list cannot be enumerated on demand, and `CGWindowList` is no
substitute. Off-screen it is mostly compositing surfaces, not windows. One
Chrome window showed up as nineteen entries, none of whose IDs matched the one
`_AXUIElementGetWindow` reports. Slack's four 2560x30 shims sit next to its one
real window with nothing but size to tell them apart.

`WindowRegistry` therefore learns windows whenever macOS is willing to show
them (every Space change, app activation, launch, unhide) and keeps the
`AXUIElement` afterwards. Entries are evicted once the WindowServer stops
listing the window at all. This is why every working macOS switcher is a
long-running daemon rather than a thing that enumerates on keypress.

### Diagnostics

Menu bar → **Write Diagnostics**, or automatically on every Space change:

```
~/Library/Logs/CmdTab/trace.log
```

Each entry records both switcher scopes with timings, and every app's window
count as seen by `CGWindowList` versus AX. Since AX only reveals a Space's
windows while that Space is active, the trace is the only way to see what the
registry learns and when.

## Known limitations

- **Secure Input**: while a password field has focus, macOS blocks all event
  taps. Shortcuts are inert until you leave the field. Nothing to do about it.
- **Hung apps**: AX messaging timeout is 100 ms per app, so a beachballing app
  can add up to that much latency to opening the switcher.
- **Unvisited Spaces**: a Space this app has not seen since launch contributes
  nothing to the widened list. Visit it once and its windows are remembered.
  Unavoidable: macOS will not report them from anywhere else.
- **Stale titles off-Space**: a remembered window keeps the title it had when
  last seen, refreshed next time you visit its Space.
- **Full-screen apps**: a full-screen window is its own Space, so `Cmd+Tab`
  there sees only that window. `Esc` widens the list to everything else.
- **Widening cost**: `Esc` walks every app over the Accessibility API, ~165 ms
  on a typical session against ~60 ms for the default scope. Fine for a
  deliberate keypress, too slow for every `Cmd+Tab`, which is why it is opt-in.
  It runs off the event-tap callback, so a slow app cannot get the tap disabled.
