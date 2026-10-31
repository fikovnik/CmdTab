# CmdTab

CmdTab is a simple window manager for macOS.
It can switch windows in MRU fashion with previews, move windows around and switch desktops.

From whatever reason macOS does not have most-recent window selection which
IMHO makes it really hard to work with IMHO.

## Install

Build from source with Xcode 16 or later and Swift 6:

```sh
make test
make install
open /Applications/CmdTab.app
```

The build uses `/Applications/Xcode.app` when available.
`make install` creates a certificate for a stable app signature.
This signature helps preserve the Accessibility permission between builds.
For an ad hoc signature, use `make app IDENTITY=-`.

You can also download a build from [GitHub Actions](https://github.com/fikovnik/CmdTab/actions).

1. Open CmdTab.
2. If macOS blocks the app, permit it in **System Settings → Privacy & Security**.
3. Give CmdTab the **Accessibility** permission.
4. For window titles and previews, select **Enable Titles & Previews…** from the CmdTab menu.
5. Give CmdTab the **Screen Recording** permission.
6. If macOS requests a restart, restart CmdTab.

The Screen Recording permission is optional.
Without it, you can still select windows, but titles from other Spaces can be unavailable.

## Select a window

CmdTab lists windows in order of their last focus, with the most recent window first.
Minimized windows appear at the end.

| Default shortcut | Window list                              | Next window | Previous window |
| ---------------- | ---------------------------------------- | ----------- | --------------- |
| Cmd+Tab          | All windows on all Spaces                | Tab         | `` ` ``         |
| `` Cmd+` ``      | Windows of the current app on all Spaces | `` ` ``     | Tab             |

Use `grave` in the configuration for the backtick key.
Key names refer to physical ANSI keyboard positions.

To use the default Cmd+Tab shortcut:

1. Hold Cmd.
2. Press Tab to select the window that had focus before the current window.
3. To select an older window, press Tab again.
4. To move toward newer windows, hold Shift and press Tab.
5. Release Cmd to activate the selected window.

For the current app shortcut, use the backtick key instead of Tab.
If you release Shift, the list stays open and the trigger key moves in its normal direction.

For a quick switch, press Cmd+Tab and release Cmd within 250 ms.
CmdTab activates the previous window without a list.
If you keep Cmd down, the list appears after 250 ms on the display with the pointer.
The list can take longer if CmdTab must wait for window data.
See [Window previews](#window-previews) for the image delay and capture behavior.

| Key while the list is open | Result                                                           |
| -------------------------- | ---------------------------------------------------------------- |
| Up / Down                  | Select the previous or next row                                  |
| PageUp / PageDown          | Move one page and stop at the list limits                        |
| Right                      | Change between all Spaces and the visible Spaces on all displays |
| Text                       | Filter by app name or window title                               |
| Backspace                  | Remove the last filter character                                 |
| Return                     | Activate the selected window                                     |
| Escape                     | Close the list without a window change                           |

The filter ignores case and matches text anywhere in the app name or window title.
Spaces, accents, and punctuation are literal.
With no matches, release the shortcut modifiers to close the list without a window change.
Shortcut trigger keys take precedence over navigation keys and filter text.

## Configure shortcuts

The configuration file is **`~/.config/cmdtab/config.json`**.

1. Select **Open Configuration…** from the CmdTab menu to create and open an example file.
2. Edit the file.
3. Select **Reload Configuration** to apply the changes.

Each entry in `keys` maps a shortcut to an action.
Without a configuration file, CmdTab uses only the two default window shortcuts.
A custom shortcut for a switcher action replaces its default.
If you omit a switcher action, CmdTab keeps its default shortcut.

```json
{
  "keys": {
    "cmd-tab": "switch-all-windows",
    "cmd-grave": "switch-app-windows",
    "shift-ctrl-alt-cmd-left": "tile:left",
    "shift-ctrl-alt-cmd-right": "tile:right",
    "shift-ctrl-alt-cmd-up": "tile:top",
    "shift-ctrl-alt-cmd-down": "tile:bottom",
    "shift-ctrl-alt-cmd-c": "tile:center",
    "shift-ctrl-alt-cmd-[": "move-to-display:previous",
    "shift-ctrl-alt-cmd-]": "move-to-display:next",
    "shift-alt-cmd-f": "toggle-fullscreen",
    "shift-alt-cmd-m": "toggle-maximize",
    "ctrl-alt-cmd-1": "switch-desktop:1",
    "ctrl-alt-cmd-left": "switch-desktop:previous",
    "ctrl-alt-cmd-right": "switch-desktop:next",
    "shift-ctrl-alt-cmd-e": "shell:open -a Finder ~",
    "shift-ctrl-alt-cmd-s": "applescript:display notification \"hello\""
  },
  "menu": { "icon": "desktop-number" }
}
```

For an existing file, move the switcher shortcuts into `keys` as above.
Remove the old switcher sections.
Use `switch-app-windows` for the current app.

### Shortcut syntax

Separate modifier names and the key name with hyphens, for example `ctrl-alt-cmd-h`.
Modifiers can appear in any order.

| Modifier | Accepted names         |
| -------- | ---------------------- |
| Command  | `cmd`, `command`       |
| Control  | `ctrl`, `control`      |
| Option   | `alt`, `opt`, `option` |
| Shift    | `shift`                |

Keys include letters, digits, `f1`–`f20`, arrows, and punctuation.
Other names include `tab`, `grave`, `space`, `return`, `escape`, `delete`, `pageup`, `pagedown`, `home`, and `end`.
Punctuation names include `minus`, `equal`, `leftbracket`, `rightbracket`, `backslash`, `semicolon`, `quote`, `comma`, `period`, and `slash`.
You can also use punctuation characters, except backslash.
`cmd--` and `cmd-minus` are equivalent.
The `fn` modifier is unavailable because arrow and function keys set it automatically.

Each switcher action accepts one shortcut with Command, Control, or Option.
Shift reverses the direction and cannot be part of a switcher shortcut.
The two switchers must use different physical trigger keys.
If a shortcut is invalid, that switcher uses its default.
If the trigger keys conflict, both switchers use their defaults.
Switcher shortcuts and their Shift variants take precedence over other actions.
For duplicate aliases or switcher shortcuts, the first valid entry in alphabetical order takes precedence.

Reload closes the window list.
CmdTab reports invalid entries and keeps valid entries.
The menu bar shows `⚠` when the configuration has errors.

`menu.icon` accepts `"desktop-number"` or literal text.
The desktop number refers to the display with the active menu bar.
A full screen Space shows `⇥`.

### Actions

Window actions use the focused window.
Desktop actions use the display with the active menu bar.
Press the shortcut once to run the action.

An action value uses `name:argument`, for example `tile:left` or `switch-desktop:3`.
For actions without an argument, use only the name, for example `toggle-maximize`.

| Action               | Argument after `:`                            | Result                                                                                         |
| -------------------- | --------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| `switch-all-windows` | None                                          | Open the window list for all apps                                                              |
| `switch-app-windows` | None                                          | Open the window list for the app that has focus                                                |
| `tile`               | `left`, `right`, `top`, `bottom`, or `center` | Move and resize the window at an edge, or center it                                            |
| `toggle-fullscreen`  | None                                          | Enter or exit native full screen                                                               |
| `toggle-maximize`    | None                                          | Fill the display area outside the menu bar and Dock, or restore the previous position and size |
| `move-to-display`    | `previous` or `next`                          | Move the focused window to the previous or next display                                        |
| `switch-desktop`     | A desktop number from `1` to `16`             | Show the desktop with that number                                                              |
| `switch-desktop`     | `previous` or `next`                          | Show the previous or next Space, with full screen Spaces in the sequence                       |
| `shell`              | A nonempty shell command                      | Run the command with `/bin/sh -c`                                                              |
| `applescript`        | Nonempty AppleScript source                   | Run the source with `/usr/bin/osascript -e`                                                    |

For `shell` and `applescript`, the argument is all text after the first colon.
Escape double quotes as `\"` inside a JSON string.

Repeated edge actions cycle through one half, two thirds, and one third of the display area.
A different edge starts at one half.
Left and right use full height.
Top and bottom use full width.

The center action keeps the size when it moves a window to the center.
If the window is already at the center, the action starts the fraction cycle for both dimensions.
If its frame matches a centered fraction, the action uses the next fraction.

Maximize keeps the menu bar and Dock available.
If CmdTab has no previous position and size, restore uses the left half.
Center and maximize have no effect on full screen windows.
Edge actions and display moves exit full screen before they change the window.

Display moves cycle from left to right and wrap at both ends.
If displays have the same horizontal position, the order is top to bottom.
A move keeps the window size and its relative position within the available area.
If the destination is too small, the move reduces the window size to fit.
With one display, these actions have no effect.

Desktop numbers exclude full screen Spaces.
Previous and next stop at the first or last Space.

Commands run in the background.
CmdTab discards their output and records launch errors and nonzero exit status.
AppleScript can require Automation permission for each app that it controls.

## Window previews

CmdTab shows a still image of the selected window beside the list.
After the list appears, CmdTab waits another 200 ms before it shows the first preview.
Each selection change restarts this delay until a preview appears.
After a preview appears, selection changes update it immediately.

CmdTab captures an image:

- Before a window switch, for the window that has focus.
- After an observed focus change, for the window that lost focus.
- When you select a window with no cached image.
- When you select a window on a visible Space whose cached image is more than two seconds old.

If a cached image is less than 0.5 seconds old, CmdTab reuses it.
A cached image from another Space stays unchanged while you select it in the list.
CmdTab has no continuous capture loop.

The cache holds up to 48 images with at most 32 MiB of image pixel data.
Each cached image is at most 1800 × 1400 pixels.
The memory limit excludes other app memory and temporary capture buffers.

Previews require the macOS screen capture permission.
CmdTab has no separate preview setting.
This permission also permits CmdTab to read window titles from other Spaces.

## Diagnose a fault

1. Select **Diagnostic Logging** from the CmdTab menu.
2. Reproduce the fault.
3. Select **Write Diagnostics** before you restart the app.
4. Turn off **Diagnostic Logging**.

Reports and events go to `~/Library/Logs/CmdTab/trace.log`.
CmdTab keeps the previous log as `trace.previous.log`.
Reports include window titles and configuration details.
Review these files before you share them.

Errors remain available in Console when diagnostic logging is off.
Filter Console by `net.fikovnik.cmdtab`.
To view live events, use:

```sh
log stream --level debug --predicate 'subsystem == "net.fikovnik.cmdtab"'
```

## Development and limits

CmdTab uses AppKit and has no external package dependencies.
Run `make test` to check the configuration, keyboard controls, window order, layout, previews, and logs.
Panel tests require a WindowServer session.

See the [application model](docs/architecture.md) for implementation details and the [code review](docs/code-review.md) for validation limits.

- Private WindowServer and Dock calls can change after a macOS update.
- Apps can refuse focus or size changes.
- Covered windows can have incomplete or old previews.
- Windows on other Spaces can retain old titles.
- Hidden apps retain only windows that CmdTab already observed.
- Secure Input and other keyboard tools can prevent CmdTab shortcuts.

## Related projects

- [AltTab](https://github.com/lwouis/alt-tab-macos): window focus and focus order.
- [InstantSpaceSwitcher](https://github.com/jurplel/InstantSpaceSwitcher): Dock swipe fields.
- [OmniWM](https://github.com/OmniNull/OmniWM): macOS window manager with Niri and Hyprland layouts.
- [Rift](https://github.com/acsandmann/rift): another window manager inspired by Niri, support native desktops somehow and in Rust.
- [yabai](https://github.com/koekeishiya/yabai): private WindowServer declarations and focus event records.
- [ShiftIt](https://github.com/fikovnik/ShiftIt): my previous attempt at window management.
