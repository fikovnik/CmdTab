# CmdTab

Simple MRU window switcher for macOS with shortcuts and a single preview.

| Shortcut   | Cycles                                       | Forward | Backward |
|------------|----------------------------------------------|---------|----------|
| `Cmd+Tab`  | Every window from every Space                 | `Tab`   | `` ` ``  |
| ``Cmd+` `` | Windows of the active app from every Space | `` ` `` | `Tab`    |

Those two are defaults. See [Configuration](#configuration) to rebind them, to
put desktop switching and window tiling on the keys you want, and to bind shell
commands or AppleScript.

## Configuration

Optional, `~/.config/cmdtab/config.json`. Menu bar -> **Open Configuration…**
creates a starter file and opens it. **Reload Configuration** re-reads it
without a relaunch. With no file at all CmdTab behaves exactly as it did before
there was one.

```json
{
  "keys": {
    "shift-ctrl-alt-cmd-left":  "left-half",
    "shift-ctrl-alt-cmd-right": "right-half",
    "shift-ctrl-alt-cmd-up":    "top-half",
    "shift-ctrl-alt-cmd-down":  "bottom-half",

    "shift-alt-cmd-f": "toggle-fullscreen",
    "shift-alt-cmd-m": "toggle-maximize",

    "ctrl-alt-cmd-1": "desktop-1",
    "shift-ctrl-alt-cmd-e": "shell:open -a Finder ~",
    "shift-ctrl-alt-cmd-s": "applescript:display notification \"hello\""
  },

  "switch-all-windows": { "trigger": "cmd-tab" },
  "switch-current-app": { "trigger": "cmd-grave" },

  "menu": { "icon": "desktop-number" }
}
```

A chord is `[modifier-]* key`. Modifiers are `cmd`, `ctrl`, `alt` and `shift`,
in any order, with the usual aliases (`control`, `option`, `opt`, `command`).
Keys are `a`-`z`, `0`-`9`, `f1`-`f20`, `tab`, `space`, `return`, `escape`,
`delete`, `left`/`right`/`up`/`down`, `pageup`, `pagedown`, `home`, `end`,
`grave`, `minus`, `equal`, and the other punctuation by name or by symbol. A
trailing `-` names the minus key, so `cmd--` works.

Nothing in the file is fatal. A bad chord or an unknown action name costs you
that one binding, adds a line to the diagnostics and puts a `⚠` in the menu bar
title. The rest of the file still applies, and a switcher with an unusable
trigger falls back to its default rather than leaving you with no way to switch
windows.

### Actions

| Action | Does |
|---|---|
| `left-half`, `right-half`, `top-half`, `bottom-half` | Occupy that half of the current display |
| `toggle-fullscreen` | Native full screen, and back |
| `toggle-maximize` | Fill the visible frame, and back to the previous frame |
| `desktop-1` … `desktop-16` | Switch the focused display to its Nth desktop |
| `space-previous`, `space-next` | One desktop left/right on the focused display |
| `shell:<command>` | Run through `/bin/sh -c` |
| `applescript:<source>` | Run through `osascript -e` |

Pressing the same half repeatedly **cycles the size**: a half, then two thirds,
then one third, then back to a half. Pressing a *different* edge snaps to a half
of that edge instead of continuing the cycle. "Already there" is judged from
where the window actually is, not from remembered state, so it survives a
relaunch and a manual resize, with enough tolerance that a terminal snapping to
whole character cells still counts.

`toggle-maximize` fills the screen's *visible* frame, so the menu bar and Dock
stay reachable, and remembers the frame to put the window back to.
`toggle-fullscreen` is the green button: its own Space, no menu bar, restored by
toggling again. Tiling a full-screen window takes it out of full screen first.

Desktop switching is per-display, because "Displays have separate Spaces" is the
macOS default, so `desktop-2` means the second desktop of whichever display has
focus, the same thing the system's own shortcuts mean. It switches without the
sliding animation.

`shell:` and `applescript:` are fire and forget, spawned off the event tap so a
slow command cannot get the tap disabled. AppleScript needs **Automation**
permission for whatever it talks to, asked for the first time it runs.

### Switchers and the menu bar

`switch-all-windows` and `switch-current-app` take a `trigger`. The trigger's
modifiers are the ones you hold: releasing any of them commits the switch, so a
trigger needs at least one of `cmd`/`ctrl`/`alt`/`shift`. `shift` is not part of
the trigger. It reverses direction. The in-cycle keys (arrows, `PageUp`,
`PageDown`, `esc`, `.`, `Return`, `→`) are fixed.

`menu.icon` is either `"desktop-number"` (the active desktop number, falling
back to `⇥` on a full-screen Space) or any string, shown verbatim.

## Build & install

Download `CmdTab.zip` from a [build](https://github.com/fikovnik/CmdTab/actions)
or a release, or build it yourself:

```sh
make install     # builds, signs with the self-signed cert, copies to /Applications
open /Applications/CmdTab.app
make test        # unit tests for the config parser and the hotkey table
```

`make test` needs Xcode installed: the Command Line Tools toolchain ships
neither XCTest nor a loadable swift-testing macro plugin. The target points
`DEVELOPER_DIR` at `/Applications/Xcode.app` when it finds one.

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

This is an incomplete list of issues:

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
- **Another app already owns the chord**: a launcher like Raycast, or anything
holding a chord through its own event tap, can take a chord before CmdTab sees
it, and Karabiner-Elements remaps lower still, below every tap. CmdTab cannot
detect either. First thing to suspect when a binding does nothing: try it on a
chord nothing else claims.
- **Apps that resist resizing**: AX position and size are requests. A window
with a minimum size, or one that resizes in whole character cells like a
terminal, lands near the target rather than on it. Some apps ignore the write
altogether.
- **Hung apps**: the AX messaging timeout is 100 ms per app, so a beachballing
app can add that much latency to opening the switcher.
- **Full-screen apps**: a full-screen window is its own Space, so `→` there
narrows the list to that one window.

## Related projects

- [alt-tab-macos](https://github.com/lwouis/alt-tab-macos) - a feature-full
  window switcher which does way more and better than this one ever will.
- [yabai](https://github.com/koekeishiya/yabai) - a full tiling window manager for macOS.
- [ShiftIt](https://github.com/fikovnik/ShiftIt) - my previous *tiling* window manager attempt.
