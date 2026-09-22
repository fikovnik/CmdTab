# CmdTab

Simple MRU window switcher for macOS with shortcuts and a single preview.

| Shortcut   | Cycles                                       | Forward | Backward |
|------------|----------------------------------------------|---------|----------|
| `Cmd+Tab`  | Every window from every Space                 | `Tab`   | `` ` ``  |
| ``Cmd+` `` | Windows of the active app from every Space | `` ` `` | `Tab`    |

## Build & install

Download `CmdTab.zip` from a [build](https://github.com/fikovnik/CmdTab/actions)
or a release, or build it yourself:

```sh
make install     # builds, signs with the self-signed cert, copies to /Applications
open /Applications/CmdTab.app
```

Self-signed apps are not welcomed on macos so you have to let it explicitly run in privacy settings.

Grant **System Settings -> Privacy & Security -> Accessibility -> CmdTab**. The app
polls once a second, so no relaunch is needed.

Thumbnails and off-Space titles also need **Screen Recording**. Menu bar ->
**Enable Titles & Previews…** asks for it. macOS caches that decision per
process, so CmdTab must be relaunched after granting it. Without it the
switcher still lists every window on every Space - off-Space rows just carry
app name and Space label instead of a title.

## Diagnostics

Debug builds only: this walks every app over the Accessibility API and prints
window titles, so the release build has none of it.

```sh
make install CONFIG=debug
```

Then menu bar -> **Write Diagnostics**, or on stdout with no GUI session:

```sh
/Applications/CmdTab.app/Contents/MacOS/CmdTab --report
```

Each entry lists both switcher scopes with timings, every app's window count as
`CGWindowList` versus AX sees it, and the preview cache with a colour count per
frame, the only way to tell an empty preview from a legitimately dark one.
`touch ~/Library/Logs/CmdTab/enable-trace` also appends one on every Space
change, at the cost of a full Accessibility walk each time. The log is
`~/Library/Logs/CmdTab/trace.log`.

## Known limitations

There are bunch of issues:

- **Never-visible windows have no preview**: a frame can only be kept if the
window was drawn at least once while CmdTab was running. Chrome's
`chrome://flags/#disable-backgrounding-occluded-windows` turns its side of this
off, at the cost of rendering windows you cannot see.
- **A Space never visited**: never warmed, so its windows preview from
whatever the WindowServer still holds, which for some apps is nothing.
- **Titles on unvisited Spaces**: listed from launch, but without Screen
Recording those rows carry app name and Space label until your first visit.
- **Stale off-Space titles**: without Screen Recording a remembered window
keeps the title it had when last seen, refreshed next time you visit its Space.
With it, `CGWindowList` supplies the current one.
- **Secure Input**: macOS blocks all event taps while a password field has
focus. Shortcuts are inert until you leave it.
- **Hung apps**: the AX messaging timeout is 100 ms per app, so a beachballing
app can add that much latency to opening the switcher.
- **Full-screen apps**: a full-screen window is its own Space, so `→` there
narrows the list to that one window.
- **Cost**: the Accessibility resolve of the active Space dominates, and both
scopes pay it. On a Space holding 28 windows, `--report` measures 166-203 ms
for the narrowed scope, then 23-77 ms for the widened one, which reuses the AX
connections the first just warmed. On a Space of 8, the first figure is 36-46
ms. The registry's full Accessibility walk runs coalesced off notifications,
never on a keypress.

## Related projects

- [alt-tab-macos](https://github.com/lwouis/alt-tab-macos) - a feature-full
  window switcher which does way more than this one ever will.
