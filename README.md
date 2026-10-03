# CmdTab

CmdTab is a small macOS window switcher. It lists windows by their last focus and shows an image of the selected window.

Requires macOS 13 or later.

| Default trigger | Window list | Forward key | Backward key |
|---|---|---|---|
| Cmd+Tab | All windows on all Spaces | Tab | Grave |
| Cmd+Grave | Windows of the current app on all Spaces | Grave | Tab |

Grave is the key with the backtick character on an ANSI keyboard.
Key names refer to physical ANSI positions.

Hold the trigger modifiers to keep the list open.
Release any trigger modifier to select the window.
Shift reverses the direction.

The list appears after 250 ms. The first preview appears after another 200 ms without a selection change.
A quick switch does not show the list.

| Key while the list is open | Result |
|---|---|
| Up / Down | Move one row |
| PageUp / PageDown | Move one page, without wrap |
| Right | Change between all Spaces and the visible Spaces |
| Return | Select the window immediately |
| Escape / Period | Close the list without a switch |

Trigger keys take precedence over these navigation keys.
The list appears on the display that contains the pointer.
The visible Space filter includes the visible Space of each display.

## Build and install

Use Xcode 16 or later with Swift 6.

```sh
make test
make install
open /Applications/CmdTab.app
```

The Makefile uses Xcode from `/Applications/Xcode.app` when available.
Both the app and tests use the release configuration.
Logging does not depend on a debug build.

`make install` creates a signing certificate if necessary.
A stable signing identity helps preserve the Accessibility permission between builds.
`make app IDENTITY=-` uses an ad hoc signature for CI.
A new ad hoc build can require the permission again.

Build downloads are available from [GitHub Actions](https://github.com/fikovnik/CmdTab/actions).

1. Open CmdTab.
2. Permit the app in **System Settings → Privacy & Security**, if macOS blocks it.
3. Give CmdTab the **Accessibility** permission.
4. For previews, select **Enable Titles & Previews…** in the CmdTab menu.
5. Give CmdTab the **Screen Recording** permission.
6. Restart CmdTab if macOS requests it.

CmdTab checks Accessibility each second until permission is available.
Screen Recording is optional. Without it, window switching still works.
Titles from other Spaces can be unavailable.
CmdTab requests Screen Recording only from the menu command.

## Configuration

The optional file is `~/.config/cmdtab/config.json`.
Without this file, only the two window switcher triggers are bound.

1. Select **Open Configuration…** to create and open an example file.
2. Edit the file.
3. Select **Reload Configuration**.

Reload replaces the configuration and ends an open window traversal.
An invalid entry produces an error. Other valid entries remain available.
The menu title shows `⚠` when the file has errors.
Reload also shows the error messages.

```json
{
  "keys": {
    "shift-ctrl-alt-cmd-left": "tile:left",
    "shift-ctrl-alt-cmd-right": "tile:right",
    "shift-ctrl-alt-cmd-up": "tile:top",
    "shift-ctrl-alt-cmd-down": "tile:bottom",
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

A chord contains modifier names and a key name, separated by hyphens.
Modifiers can appear in any order.

| Modifier | Accepted names |
|---|---|
| Command | `cmd`, `command` |
| Control | `ctrl`, `control` |
| Option | `alt`, `opt`, `option` |
| Shift | `shift` |

Keys include letters, digits, `f1`–`f20`, arrows, navigation keys, and punctuation.
Examples are `tab`, `grave`, `space`, `return`, `escape`, `delete`, `pageup`, `pagedown`, `home`, and `end`.
Punctuation names include `minus`, `equal`, `leftbracket`, `rightbracket`, `backslash`, `semicolon`, `quote`, `comma`, `period`, and `slash`.
The punctuation characters are also accepted, except backslash.
A final hyphen denotes the minus key. For example, `cmd--` and `cmd-minus` are equivalent.

A switcher trigger needs Command, Control, or Option.
Shift is reserved for reverse traversal.
The two switchers must use different physical trigger keys.
Invalid triggers use their defaults.
If trigger keys conflict, both switchers use their defaults.

Switcher triggers and their Shift variants take precedence over local bindings.
Duplicate chord aliases produce an error.
The first alias in alphabetical order takes precedence.
The `fn` modifier cannot be bound because arrow and function keys set it automatically.

`menu.icon` accepts `"desktop-number"` or literal text.
The desktop number belongs to the display with the active menu bar.
A full screen Space shows `⇥`.

### Actions

| Action | Result |
|---|---|
| `tile:left`, `tile:right`, `tile:top`, `tile:bottom` | Move the focused window to a display edge |
| `tile:center` | Move the window to the center, then change its size on subsequent presses |
| `toggle-fullscreen` | Enter or exit native full screen |
| `toggle-maximize` | Fill the visible display frame, or restore the previous frame |
| `switch-desktop:1` … `switch-desktop:16` | Show that desktop on the display with the active menu bar |
| `switch-desktop:previous`, `switch-desktop:next` | Move one Space, including full screen Spaces |
| `shell:<command>` | Run `/bin/sh -c` with the command |
| `applescript:<source>` | Run `/usr/bin/osascript -e` with the source |

Repeated edge actions use one half, two thirds, then one third of the display.
A different edge starts at one half.
The current frame determines the next size.
A 20-point tolerance permits terminal windows that resize in character cells.

The first center action keeps an unmatched window size.
An already centered window starts the fraction cycle.
Center fractions apply to both dimensions.

Maximize leaves the menu bar and Dock available.
If no previous frame is available, the restore action uses the left half.
Center and maximize have no effect on full screen windows.
An edge action requests exit from full screen and waits up to three seconds before the resize.
A newer local action cancels a pending edge action.

Desktop numbers exclude full screen Spaces.
Previous and next include them and stop at either end.
Space switching uses private Dock gesture fields.

Commands run outside the keyboard callback.
Standard output and standard error are discarded.
Launch failures and nonzero exit status produce log errors.
AppleScript can require Automation permission for each controlled app.

## Diagnostics

There is one logging model for all builds.

| Message type | Default behavior |
|---|---|
| Errors | Write to the macOS unified log and retain in the recent event list |
| Routine trace events | Record only when **Diagnostic Logging** is on |
| Manual report | Save the current state regardless of the logging setting |

The recent event list holds 300 entries.
The logging setting survives an app restart.
Routine unified log messages use the debug level and private text.
Errors use the error level and public text.

To collect a fault:

1. Turn on **Diagnostic Logging**.
2. Reproduce the fault.
3. Select **Write Diagnostics** before an app restart.
4. Turn off **Diagnostic Logging**.

CmdTab writes events and reports to `~/Library/Logs/CmdTab/trace.log`.
Before a write exceeds 512 KiB, CmdTab moves the existing file to `trace.previous.log`.
A single report can exceed this threshold. CmdTab does not split reports.

File writes use a serial worker queue.
Manual export waits for earlier writes.
Reports contain window titles, configuration details, recent errors, focus state, preview memory, permissions, display geometry, and overlay state.
Reports preserve the tracked window state without a new AX scan.
Review these files before you share them.

To view errors in Console, filter by `net.fikovnik.cmdtab`.
For a live stream that includes routine messages:

```sh
log stream --level debug --predicate 'subsystem == "net.fikovnik.cmdtab"'
```

The following command reads windows in a new process:

```sh
/Applications/CmdTab.app/Contents/MacOS/CmdTab --report
```

This command does not read the state of the running menu bar app.
It needs access to the user WindowServer session for window data.
Use the menu report to diagnose the running app.

## Implementation and tests

The app uses AppKit and has no external package dependencies.
The [application model](docs/architecture.md) defines window order, traversal, actions, previews, and logging.
The [code review](docs/code-review.md) records the corrected defects and validation limits.

`make test` checks configuration behavior, keyboard routing, traversal, focus order, Space layout, geometry, preview memory, and log rotation.
The overlay tests need a WindowServer session.
They report a skip when no session is available.
The tests do not prove that another app accepts focus or resize requests.

## Limitations

- Private WindowServer and Dock calls can change after a macOS update.
- AX requests run on the main thread. Each call has a 100 ms timeout, but a scan can contain several calls.
- Apps can refuse a resize or impose a minimum size.
- Some apps release images of covered windows. Their previews can be incomplete or show an older image.
- Windows on other Spaces keep their last known AX title until new title data is available.
- Hidden apps retain only windows that CmdTab already observed.
- Secure Input can stop keyboard events until focus leaves a password field.
- Another event tap can receive a shortcut before CmdTab.
- An empty desktop can move keyboard focus to another display. The next desktop action then uses that display.

## Related projects

- [AltTab](https://github.com/lwouis/alt-tab-macos): window focus and focus order techniques.
- [InstantSpaceSwitcher](https://github.com/jurplel/InstantSpaceSwitcher): Dock swipe fields.
- [yabai](https://github.com/koekeishiya/yabai): private WindowServer declarations and focus event records.
- [ShiftIt](https://github.com/fikovnik/ShiftIt): the previous window tiling utility.
