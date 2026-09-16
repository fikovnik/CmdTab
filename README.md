# CmdTab

MRU window switcher for macOS. Two shortcuts, no thumbnails.

| Shortcut  | Cycles                                              | Forward | Backward |
|-----------|-----------------------------------------------------|---------|----------|
| `Cmd+Tab` | All windows on the current Space, across all screens | `Tab`   | `` ` ``  |
| ``Cmd+` `` | Windows of the frontmost app only                   | `` ` `` | `Tab`    |

Hold `Cmd`, press the cycle key as many times as you like, release `Cmd` to switch.
`Esc` cancels. A small text HUD shows app icon + window title. Nothing is raised
until you let go of `Cmd`, so there is no flicker.

## Build & install

```sh
make install     # builds, ad-hoc signs, copies to /Applications
open /Applications/CmdTab.app
```

Grant **System Settings → Privacy & Security → Accessibility → CmdTab**.
The app polls once a second, so it starts working as soon as you flip the toggle,
no relaunch needed.

Other targets: `make run` (run from `build/`), `make stop`, `make uninstall`, `make clean`.

## After a rebuild

Ad-hoc signatures change with every build, so macOS sees a different program and
drops the Accessibility grant. If shortcuts stop responding after `make install`:

```sh
make reset-permissions
```

then re-add the app in Accessibility. (To avoid this entirely, sign with a stable
self-signed certificate and swap `--sign -` in the Makefile for its identity.)

## How it works

- **Hotkeys**: a `CGEventTap` at `.cgSessionEventTap` head-inserts ahead of the
  system switcher and swallows the chord (`HotkeyTap.swift`).
- **MRU order**: derived from the `CGWindowList` front-to-back z-order rather
  than from tracking focus events. macOS raises a window when it is focused, so
  z-order *is* MRU, and it cannot go stale or leak (`WindowEnumerator.swift`).
- **Window titles**: read over the Accessibility API, not `kCGWindowName`, so
  the app never needs Screen Recording permission. The two are correlated via
  `_AXUIElementGetWindow`, a private-but-stable SPI (`PrivateAX.swift`).
- **Filtering**: layer-0 windows at least 80×80 with AX subrole
  `AXStandardWindow` or `AXDialog`. Minimized windows and windows on other
  Spaces are excluded, because `kCGWindowListOptionOnScreenOnly` omits them.

## Known limitations

- **Secure Input**: while a password field has focus, macOS blocks all event
  taps. Shortcuts are inert until you leave the field. Nothing to do about it.
- **Hung apps**: AX messaging timeout is 100 ms per app, so a beachballing app
  can add up to that much latency to opening the switcher.
- **Full-screen apps**: a full-screen window is its own Space, so `Cmd+Tab`
  there sees only that window.
