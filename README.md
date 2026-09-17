# CmdTab

MRU window switcher for macOS. Two shortcuts, one thumbnail at a time.

| Shortcut   | Cycles                                               | Forward | Backward |
|------------|------------------------------------------------------|---------|----------|
| `Cmd+Tab`  | Every window, on every Space                           | `Tab`   | `` ` ``  |
| ``Cmd+` `` | Windows of the frontmost app, on every Space          | `` ` `` | `Tab`    |

### How it behaves

Hold `Cmd`, press the cycle key as many times as you like, release `Cmd` to
switch. Nothing is raised until you release, so cycling never flickers.

The list spans every Space, ordered by when you last used each window, so a
second `Cmd+Tab` always goes back to where you came from, even when that means
crossing a Space. `→` narrows the list to the Space in front of you.

The list is only a hint. Release within **250 ms** and it never appears: a
quick `Cmd+Tab` switches with nothing drawn on screen. Hold longer and it fades
in so you can see where you are. Either way, releasing `Cmd` switches to the
highlighted window and dismisses it.

That threshold has to clear a deliberate tap, which runs 120-200 ms. AltTab uses
200 ms. The extra margin here is free, since the list changes nothing about what
releasing `Cmd` does. It is `revealDelay` in `Switcher.swift`.

```
┌────────────────────────────────────────────────────────────────┐
│   Ghostty  cmd-tab@pokhara.local: ✳ Claude Code    Desktop 2 ▏ │
│ ▸ Google Chrome  v8/src/codegen/arm64/assembl…     Desktop 1 ▏ │
│   Slack  #general                                  Desktop 1 ▏ │
│   Obsidian  Daily note                             Desktop 1   │
├────────────────────────────────────────────────────────────────┤
│ 3/10 windows · 10 apps  ·  All Spaces  ·  ↑↓ move · → all Spa… │
└────────────────────────────────────────────────────────────────┘
```

While `Cmd` is down:

| Key                  | Does                                              |
|----------------------|---------------------------------------------------|
| `Tab` / `` ` ``      | Move in the direction the shortcut opened with    |
| `↑` `↓`              | Move one row (wraps)                              |
| `PgUp` `PgDn`        | Move one screenful (stops at the ends)            |
| `→`                  | Narrow the list to **this** Space (`→` again undoes) |
| `Return`             | Switch now, without waiting for the key release   |
| `Esc`                | Dismiss without switching                         |
| `Shift`              | Reverses `Tab` / `` ` ``, opening the cycle too   |

The footer counts windows and apps, and a scroll bar appears once the list is
longer than fits.

The panel is light-on-dark in both system appearances, over a black scrim at
68% behind the blur. Without the scrim a bright page underneath bleeds through
far enough to wash the text out. Worst case, white text lands at 4:1 against
its own background. The scrim puts a floor under that: 7.9:1 for titles, 5.0:1
for window names, 3.9:1 for the Space badges, assuming the blur contributes
nothing at all. Highlight text picks white or black from the accent colour's
luminance, since the accent can be anything from navy to yellow.

## Build & install

```sh
make install     # builds, signs with the self-signed cert, copies to /Applications
open /Applications/CmdTab.app
```

Grant **System Settings → Privacy & Security → Accessibility → CmdTab**.
The app polls once a second, so it starts working as soon as you flip the toggle,
no relaunch needed.

Thumbnails and off-Space titles additionally need **Screen Recording**. Menu
bar → **Enable Titles & Previews…** asks for it. Unlike Accessibility, macOS
caches that decision per process, so CmdTab has to be relaunched after granting
it. Without the grant the switcher still lists every window on every Space. The
off-Space rows carry app name and Space label instead of a title, until you
visit that Space once.

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
- **MRU order**: within one Space, from the `CGWindowList` front-to-back
  z-order: macOS raises a window when it is focused, so z-order *is* MRU there,
  and it cannot go stale or leak. Across Spaces there is no z-order to read, because
  two windows on different Spaces are never on screen together. So each window
  also carries a monotonic **use stamp**, set when a cycle leaves it and when a
  cycle lands on it (`WindowRegistry.swift`). Windows never seen in use sort
  below the stamped ones, by z-order, then Space, then app name, so a freshly
  launched CmdTab shows the list it always did, and converges on true MRU as you
  use it.

  Same trade GNOME makes. Mutter keeps an explicit per-workspace MRU list updated
  on focus (`meta_window_make_most_recent`), and builds the cross-workspace list
  by sorting *every* window on `meta_window_get_user_time()`, a timestamp, not a
  stacking position. GNOME's Alt+Tab spans all workspaces by default too
  (`org.gnome.shell.app-switcher current-workspace-only` defaults to `false`).
- **Window titles**: over the Accessibility API wherever AX can see the window,
  correlated to its CGWindowID by `_AXUIElementGetWindow`, a private-but-stable
  SPI (`PrivateAX.swift`). AX cannot see another Space, so off-Space titles come
  from `kCGWindowName`, gated behind Screen Recording. Without the grant a full
  scan names 3 windows out of 296.
- **Previews**: `SLSHWCaptureWindowList`, the WindowServer's frame store
  (`WindowPreview.swift`). Not `SCScreenshotManager`: that needs an
  `SCShareableContent` enumeration of all 299 windows before it can filter to
  one, and returns nothing for some windows, Lightroom's included, which this
  captures fine. 3-18 ms per window and synchronous, so there is no request
  coalescing. Frames arrive at the window's size in points and are resampled to
  twice the panel's ceiling: 2 MB of cache per 2560pt window instead of 14 MB.
- **Warming the preview cache**: an app that releases its drawing surface while
  a window is occluded cannot be captured from another Space by any API. One
  Chrome window measured 36 distinct colours on its own Space and 6 from one
  Space over: a toolbar above flat grey. Slack, on that same unvisited Space,
  captured at 79. It keeps its surface. So every window on the active Space is
  captured off the coalesced registry refresh, one per 80 ms to keep the main
  thread free, and those frames survive leaving the Space. A frame taken on a
  window's own Space is never replaced by one taken from elsewhere.
- **Filtering**: for AX windows, subrole `AXStandardWindow` or `AXDialog` plus
  a non-zero CGWindowID. For WindowServer windows, the flags in `WindowServer.isReal`.
- **Spaces**: `CGSCopyManagedDisplaySpaces` for the layout and labels
  (`CGSSpaces.swift`). Membership comes from the per-Space scan itself,
  `CGSCopySpacesForWindows` is the fallback for a window that scan missed.
- **Off-Space windows**: `SLSWindowQueryWindows` and its window iterator
  (`WindowServer.swift`), the only source that sees a Space you are not on. Its
  raw output is noisy, so four iterator flags filter it: `attributes & 0x2`
  (drops Chrome's one compositing surface per window, 20 of them, all with
  `attributes = 0`), zero parent id (drops Lightroom's 11 attached panels,
  leaving its one real window), level 0 (drops the menu bar at 24, Control
  Center at 25, this app's HUD at 101), and non-zero alpha. Against AX as ground
  truth on the active Space the filter matches exactly: 8 of 29 raw ids on one
  Space, 28 of 59 on the other.
- **Focusing off-Space**: those rows have no `AXUIElement`. Two calls, in order
  (`WindowServer.raise`): `NSRunningApplication.activate()` switches Space but
  lands on whichever window the app last had main, then
  `_SLPSSetFrontProcessWithOptions` names the right window by id. It does *not*
  switch Space itself, and calling it first makes the app frontmost, which turns
  the activation into a no-op and leaves you on the wrong Space. Two synthetic
  event records follow, telling the app which window was activated.

### Why AX is not enough

`kAXWindowsAttribute` reports an app's windows on the **current Space only**,
plus its minimized ones. Windows on another Space are invisible to it. Measured
on a live session from Desktop 2, for all nine apps whose windows sit on
Desktop 1:

```
Slack    id=114  2560x1410  alpha=1.00  in CGWindowList  →  AX: status=success count=0
Chrome   20 real windows               in CGWindowList  →  AX: status=success count=0
```

`status=success count=0`, not an error, so there is nothing to retry. Raising the
AX messaging timeout from 100 ms to 5 s changes nothing, and neither does
`AXManualAccessibility` or `AXEnhancedUserInterface`, the attributes that make
Chromium and Adobe toolkits build an AX tree.

So the all-Spaces list comes from the WindowServer (`WindowServer.swift`).
`WindowRegistry` still exists for what the WindowServer will not say: it learns
the `AXUIElement` and the live title whenever macOS hands them over: every
Space change, app activation, launch, unhide, and holds the use stamps that
order the list. Entries are evicted once the WindowServer stops listing the
window.

### Diagnostics

Menu bar → **Write Diagnostics** appends to:

```
~/Library/Logs/CmdTab/trace.log
```

Or on stdout, with no GUI session, which is how the numbers above were measured:

```sh
/Applications/CmdTab.app/Contents/MacOS/CmdTab --report
```

To also capture one automatically on every Space change, the only way to see
what the registry learns and when, create the marker file. It costs a full
Accessibility walk per Space switch, so it is off by default:

```sh
touch ~/Library/Logs/CmdTab/enable-trace
```

Each entry records both switcher scopes with timings, and every app's window
count as seen by `CGWindowList` versus AX. Since AX only reveals a Space's
windows while that Space is active, the trace is the only way to see what the
registry learns and when.

## Known limitations

- **Previews of never-visible windows**: warming covers a window on a Space you
  visited, but not one that has been covered by another window the whole time.
  Chrome releases the drawing surface for those too: on one Space, 6 of 20
  Chrome windows sat at 5 distinct colours against 15-50 for the 14 that had
  been visible. Chrome's `chrome://flags/#disable-backgrounding-occluded-windows`
  turns the behaviour off, at the cost of rendering windows you cannot see.
  `--report` prints a colour count per cached frame, which is the only way to
  tell an empty preview from a dark one.
- **Previews on a Space never visited**: never warmed, so its windows preview
  from whatever the WindowServer still holds, which for some apps is nothing.
- **Secure Input**: while a password field has focus, macOS blocks all event
  taps. Shortcuts are inert until you leave the field. Nothing to do about it.
- **Hung apps**: AX messaging timeout is 100 ms per app, so a beachballing app
  can add up to that much latency to opening the switcher.
- **Titles on unvisited Spaces**: every window on every Space is listed from
  launch, but `kAXWindowsAttribute` describes a Space only while you are on it.
  Without Screen Recording those rows carry app name and Space label and no
  title until your first visit to that Space. With it, `kCGWindowName` fills
  them in immediately.
- **Stale titles off-Space**: a remembered window keeps the title it had when
  last seen, refreshed next time you visit its Space.
- **Full-screen apps**: a full-screen window is its own Space, so pressing `→`
  there narrows the list to that one window. Without it you see everything, as
  everywhere else.
- **Cost of the all-Spaces default**: a keypress pays for a live `CGWindowList`
  scan of the active Space, an Accessibility resolve of it, one WindowServer
  query per Space, and a dictionary read. The Accessibility resolve dominates,
  and both scopes pay it: on a Space holding 28 windows (20 of them Chrome's)
  `--report` measures 166-203 ms for the narrowed scope, then 23-77 ms for the
  widened one, which reuses the AX connections the first just warmed. On a Space
  holding 8 windows the first figure is 36-46 ms. The full Accessibility walk
  that populates the registry is *not* on that path. It runs coalesced off
  app-activation and Space-change notifications. Everything the switcher does
  runs off the event-tap callback, so a slow app cannot get the tap disabled.
