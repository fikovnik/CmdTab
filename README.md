# CmdTab

A simple macOS window switcher. It lists windows in the order of their last
focus and shows a preview of the selected window.

| Shortcut   | Cycles through                         | Forward | Backward |
|------------|----------------------------------------|---------|----------|
| `Cmd+Tab`  | All windows on all Spaces              | `Tab`   | `` ` ``  |
| ``Cmd+` `` | The windows of the active app, on all Spaces | `` ` `` | `Tab`    |

These are the defaults. To change them, and to bind tiling, desktop switching,
shell commands or AppleScript to keys, see [Configuration](#configuration).

## Configuration

The configuration file is optional: `~/.config/cmdtab/config.json`. Menu bar ->
**Open Configuration…** makes a starter file and opens it. **Reload
Configuration** reads the file again without a relaunch. Without a file,
CmdTab uses the defaults.

```json
{
  "keys": {
    "shift-ctrl-alt-cmd-left":  "tile:left",
    "shift-ctrl-alt-cmd-right": "tile:right",
    "shift-ctrl-alt-cmd-up":    "tile:top",
    "shift-ctrl-alt-cmd-down":  "tile:bottom",

    "shift-alt-cmd-f": "toggle-fullscreen",
    "shift-alt-cmd-m": "toggle-maximize",

    "ctrl-alt-cmd-1": "switch-desktop:1",
    "shift-ctrl-alt-cmd-e": "shell:open -a Finder ~",
    "shift-ctrl-alt-cmd-s": "applescript:display notification \"hello\""
  },

  "switch-all-windows": { "trigger": "cmd-tab" },
  "switch-current-app": { "trigger": "cmd-grave" },

  "menu": { "icon": "desktop-number" }
}
```

A chord is `[modifier-]* key`. The modifiers are `cmd`, `ctrl`, `alt` and
`shift`, in any order. The usual aliases are also correct: `control`,
`option`, `opt`, `command`. These keys are available:

- `a`-`z`, `0`-`9`, `f1`-`f20`
- `tab`, `space`, `return`, `escape`, `delete`
- `left`, `right`, `up`, `down`, `pageup`, `pagedown`, `home`, `end`
- `grave`, `minus`, `equal`, and the other punctuation keys by name or by symbol

A `-` at the end is the minus key, thus `cmd--` is correct.

An error in the file stops only the binding that has the error. CmdTab adds a
line to the diagnostics and shows `⚠` in the menu bar title. The other bindings
continue to operate. If a switcher trigger is not usable, the switcher uses its
default trigger.

### Actions

| Action | Result |
|---|---|
| `tile:left`, `tile:right`, `tile:top`, `tile:bottom` | Puts the window on that side of its display |
| `tile:center` | Puts the window in the center of its display. The first press moves it. More presses change the size. |
| `toggle-fullscreen` | Native full screen, and back |
| `toggle-maximize` | Fills the visible frame, and puts the window back |
| `switch-desktop:1` … `switch-desktop:16` | Shows desktop N of the display that has focus |
| `switch-desktop:previous`, `switch-desktop:next` | Moves one Space to the left or right on the display that has focus |
| `shell:<command>` | Runs the command with `/bin/sh -c` |
| `applescript:<source>` | Runs the script with `osascript -e` |

An action is a name, or `<name>:<parameter>`. A parameter that is not correct
stops only that binding, and the error message gives the correct values. For
example, `tile:sideways` gives `expected left/right/top/bottom/center`.

**Tiling.** More presses on the same side change the size: one half, two
thirds, one third, then one half again. A press on a different side starts
with one half. CmdTab gets the current size from the window, not from a stored
state. Thus, the cycle continues after a relaunch or a manual resize. A terminal
that resizes in character cells is near a fraction, not on it. CmdTab accepts a
difference of 20 points.

`tile:center` starts the size cycle one press later. The first press moves the
window and keeps its size, for example a terminal that you sized manually.
More presses apply the fractions to the width and the height.

`toggle-maximize` fills the *visible* frame, so the menu bar and the Dock stay
available. It keeps the old frame for the next toggle. `toggle-fullscreen`
does the same as the green button: the window gets its own Space. A tile action
on a full-screen window first ends the full screen.

**Desktop switching.** "Displays have separate Spaces" is the macOS default.
Thus, `switch-desktop:2` shows the second desktop of the display that has focus.
This is the display with the active menu bar, the same display that the system
Ctrl+2 uses. The switch has no animation.

macOS has no public API to switch Spaces. CmdTab sends a Dock swipe gesture with
a very high velocity, so the Dock does the switch. The menu bar and Mission
Control stay correct. `previous` and `next` also stop on full-screen Spaces, as
Ctrl+Left and Ctrl+Right do.

**Commands.** `shell:` and `applescript:` start the command and do not wait
for it. A slow command cannot stop the event tap. AppleScript needs the
**Automation** permission for each app that it controls. macOS asks for it at
the first run.

### Switchers and the menu bar

`switch-all-windows` and `switch-current-app` have a `trigger`. Hold the
modifiers of the trigger to keep the list open. Release a modifier to switch
to the selected window. Thus, a trigger must have one or more of `cmd`, `ctrl`,
`alt` and `shift`. `shift` is not part of a trigger: it reverses the direction.
These keys in the list are fixed:

- `↑`, `↓`, `PageUp`, `PageDown`: move the selection
- `→`: show only the windows on the visible Spaces, and all windows again
- `Return`: switch now
- `esc`, `.`: close the list without a switch

`menu.icon` is `"desktop-number"` or a text. `"desktop-number"` shows the
number of the current desktop, or `⇥` on a full-screen Space. CmdTab shows a
text as it is.

## Build and install

Download `CmdTab.zip` from a [build](https://github.com/fikovnik/CmdTab/actions)
or a release, or build it:

```sh
make install     # build, sign with the self-signed certificate, copy to /Applications
open /Applications/CmdTab.app
make test        # unit tests: config parser, key table, Space layout, focus order
```

`make test` needs Xcode. The Command Line Tools have no XCTest and no
swift-testing macro plugin. If Xcode is in `/Applications`, the target sets
`DEVELOPER_DIR` to it.

macOS does not trust a self-signed app. In **System Settings -> Privacy &
Security**, let CmdTab run.

Give the **Accessibility** permission: **System Settings -> Privacy & Security
-> Accessibility -> CmdTab**. CmdTab checks the permission each second, so a
relaunch is not necessary.

Previews and the titles of windows on other Spaces also need **Screen
Recording**. Menu bar -> **Enable Titles & Previews…** asks for it. macOS
applies this permission only after a relaunch of CmdTab. Without it, the
switcher still shows all windows on all Spaces. A window that AX did not read
then shows only the app name and the Space.

## How it works

- **Windows.** The WindowServer gives each window and the Spaces that show it.
  AX gives the title, the subrole and the element, but only for windows on
  visible Spaces. The key window and the main window of each app are the
  exception: AX gives them on all Spaces.
- **Order.** Only a focus change that macOS reports changes the order: an app
  activation, or an app that reports a new focused window. If a switch does not
  occur, the order does not change.
- **Focus.** CmdTab makes the app the front process with this window in front,
  makes the window key, and raises it over AX. For a window on a Space that is
  not visible, CmdTab first switches to that Space with a Dock swipe. It does
  not use `NSRunningApplication.activate()`, because macOS can refuse it.
- **Previews.** CmdTab captures a window when it loses focus, because then the
  window is in front and drawn. A window on a visible Space gets a new capture
  when the list shows it.

## Diagnostics

Only debug builds have diagnostics. They ask every app over AX and write
window titles to a file, so the release build does not have them.

```sh
make install CONFIG=debug
```

Then use menu bar -> **Write Diagnostics**. Or, without a GUI session, write
the same report to stdout:

```sh
/Applications/CmdTab.app/Contents/MacOS/CmdTab --report
```

The report contains:

- the two switcher lists. `recent=N` is the position in the focus order, and
  `recent=-` means that the window never had focus. `server` means that AX did
  not read the window yet.
- the preview frames,
- the recent switcher events,
- the windows of each app.

`touch ~/Library/Logs/CmdTab/enable-trace` also writes a report on each Space
change. Each report does a full AX read. The file is
`~/Library/Logs/CmdTab/trace.log`.

Debug builds also write each event to the unified log:

```sh
log stream --predicate 'subsystem == "net.fikovnik.cmdtab"'
```

Each focus writes `focus took=true` or `focus took=false`, after a check of
the focused window.

## Known limitations

- **Windows without a preview.** A window that did not lose focus while CmdTab
  was running has no frame. On a visible Space, CmdTab captures it when the list
  shows it. On another Space, the capture can show only the toolbar of the
  window: Chrome does not draw windows that are covered or on another Space.
  `chrome://flags/#disable-backgrounding-occluded-windows` stops this, but then
  Chrome draws windows that are not visible.
- **Titles on other Spaces.** Without Screen Recording, a window that AX did
  not read shows the app name and the Space. A known window keeps its last
  title until AX reports a change.
- **Desktop switching** uses Dock gesture fields that Apple does not document.
  A macOS update can change them. Then `switch-desktop` does nothing.
- **An empty desktop.** After a switch to a desktop that has no window to
  focus, macOS can give focus to the other display. Then the next
  `switch-desktop` acts on that display. The system Ctrl+N does the same.
- **Secure Input.** macOS stops all event taps while a password field has
  focus. The shortcuts do not operate until the focus leaves the field.
- **Another app has the chord.** A launcher such as Raycast, or an app with its
  own event tap, can get a chord before CmdTab. Karabiner-Elements changes keys
  before all event taps. CmdTab cannot detect this. If a binding does nothing,
  try a chord that no other app uses.
- **Apps that resist a resize.** AX position and size are requests. A window
  with a minimum size, or a terminal that resizes in character cells, stops
  near the target. Some apps ignore the request.
- **Hung apps.** The AX timeout is 100 ms for each app. Thus, an app that does
  not answer can add 100 ms to a refresh or a focus.
- **Full-screen apps.** A full-screen window has its own Space. Thus, `→` there
  shows only that window.

## Related projects

- [alt-tab-macos](https://github.com/lwouis/alt-tab-macos): a window switcher
  with many more features. CmdTab uses its focus sequence and its rules for the
  focus order.
- [InstantSpaceSwitcher](https://github.com/jurplel/InstantSpaceSwitcher): the
  source of the Dock swipe that CmdTab uses to switch Spaces.
- [yabai](https://github.com/koekeishiya/yabai): a tiling window manager for macOS.
- [ShiftIt](https://github.com/fikovnik/ShiftIt): my previous tiling window manager.
