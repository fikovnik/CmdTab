# Application model

This document describes the current implementation.
Earlier design records describe their dated versions.

| Target | Responsibility |
|---|---|
| `CmdTabModel` | Focus order, window selection, Space layout, window geometry, and preview placement |
| `CmdTabConfig` | Configuration values, action values, key chords, and keyboard state |
| `CmdTab` | AppKit lifecycle, AX access, WindowServer calls, action execution, previews, and reports |

`CmdTabConfig` depends on `CmdTabModel`.
The app depends on both targets.
The model and configuration targets do not open windows or call private APIs.

App state belongs to the main actor.
The event tap and AX observers use the main run loop.
Commands use worker queues.
`DiagnosticLog` serializes file writes on its own queue.
Swift 6 checks actor isolation.
One synchronous AX callback uses an unsafe reference to pass its C argument into the main actor.

## Window records and order

`WindowTracker` owns one record per WindowServer ID.
The WindowServer supplies process IDs, Space membership, and stack positions.
AX adds the title, element, subrole, and minimized state when available.
A missing AX description does not remove a server window.

Only regular apps contribute windows.
The server filter excludes child windows, nonzero window levels, transparent windows, and surfaces without the normal window attribute.
AX excludes known subroles other than standard windows and dialogs.
Unknown subroles retain the server classification.
AX also discovers minimized windows from every regular app, including apps with no server records.
An AX-confirmed minimized window bypasses the server filter because minimization can remove its normal window attribute.
The server still supplies its Space membership and removes it when it closes.

A server scan replaces the live records.
Known windows from hidden apps remain available because the server omits them.
The scan removes closed records from focus order, pending focus reports, and preview storage.

`RecentWindows` records observed focus, not requested focus.
Workspace activation and AX focused window notifications supply observations.
Background app changes do not change the order.
Reports from one app replace earlier pending reports.
After 60 ms, the last report moves its window to the front.

At traversal start, CmdTab reads the actual focused window and puts it first.
The list then contains:

1. Observed windows, most recent first.
2. Unseen windows on visible Spaces, in Space and stack order.
3. Other unseen windows, in Space and stack order.

Minimized windows move to the end, with the same order within each group.
Their rows show a “Minimized” label beside the Space label when present.
Minimize and restore notifications update the state before the next refresh.
The stored focus order stays unchanged.

The window ID resolves equal positions.
The current app filter uses the process that was frontmost at traversal start.
The visible Space filter includes every display.

## Window traversal

`HotkeyState` owns the held trigger modifiers and consumed key codes.
It produces commands from key events.
After the HUD appears, printable text and Backspace produce filter commands.
`HotkeyTap` reads keyboard-layout text without the held modifiers, retaining Shift.
Trigger keys and navigation take precedence over filter text.
It performs no window operations.
Consumed key releases remain consumed after commit, cancellation, or configuration reload.

`WindowTraversal` owns the list and selection offset.
A nil list means that a scan is pending.
Steps before the scan remain in the offset.
Ordinary steps wrap.
Page steps stop at the list boundaries.
A replacement list keeps the selected window by ID.
If the selected ID disappears or a completed list has no selection, the first row becomes selected.
Only the first scan retains the pending selection offset.

`Switcher` owns one session, two timers, and the list panel.
A session stores the mode, process filter, Space filter, candidates, text filter, traversal, and reveal state.
The reveal timer expires after 250 ms.
The scan runs after the event tap returns.
The list appears when both are complete.

`WindowSearch` matches a case-insensitive substring in either the app name or window title.
It returns UTF-16 ranges for every occurrence, including overlaps.
The HUD draws these ranges with black text on a yellow background.
Text edits filter the stored candidates without a new window scan.
Space changes replace the candidates and reapply the same query.
An initial list with one window is suppressed. After the HUD appears, it can show any number of rows.
An empty result keeps the HUD open, hides the preview, and has no switch target.
Backspace removes one Swift character. An empty query restores every candidate.

Commit copies the session, ends keyboard capture, and queues its focus request.
Each queued request owns its session.
A later commit cannot overwrite an earlier queued session.
Cancellation clears the session and both timers.

`Focus` shows a hidden target Space through `SpaceSwitcher`.
It continues after a matching Space notification, or after a one-second timeout.
It unhides the app, restores a minimized window, fronts the process, sends the key-window event, and raises the AX window.
An invalid AX element gets one new lookup.
A new focus request cancels an older pending request.

The focus sequence does not directly change recent order.
A subsequent observation supplies that change.
The stored front app of the previous Space is restored only if that Space is no longer visible.

## Configuration and actions

`Config` returns a complete value snapshot: a chord-to-action table, menu text, and errors.
It checks unknown sections, unknown fields, value types, action parameters, and chord conflicts.
No parsed action owns runtime state.

The `keys` object maps each chord to an action name.
The switcher actions are `switch-all-windows` and `switch-app-windows`.
A custom switcher trigger replaces the default trigger for that action.
Each switcher accepts one trigger.
`Config` checks switcher triggers before local bindings.
Shift selects reverse traversal.
Different trigger modifiers cannot distinguish two switchers that use the same physical key during a traversal.
Such a conflict restores both defaults.
Local bindings cannot replace a trigger or its Shift variant.

`HotkeyTap` installs the table directly.
`WindowActionHost` executes action values after the keyboard callback returns.
Window actions use `WindowGeometry`.
Desktop actions use `SpaceSwitcher`.
External commands use `Process` on a worker queue.

`Layout` calculates frames from the current window geometry.
Only maximize needs a stored restore frame.
The host removes obsolete restore entries before a maximize action.
Full screen exit is asynchronous.
An edge action waits for exit and reads a new frame before the resize.

All AX elements use a process-wide 100 ms timeout.
The timeout limits each call, not a complete scan.

## Preview model

`WindowPreview` owns one image per window ID and one nonactivating panel.
It captures the window before a requested switch and after an observed focus change.
For visible windows, selection requests a new image when the stored image is more than two seconds old.
An unseen window on another Space gets one capture attempt.
A failed capture keeps an existing image.
A missing image hides the preview.

Captures require Screen Recording.
Only the menu command requests permission.
A frame must match the server window size within two points.
Each stored image has at most 1800 by 1400 pixels.
The cache retains at most 48 frames and 32 MiB of image pixel data.
The oldest capture is removed first.
The byte limit excludes AppKit objects and temporary capture buffers.

`PreviewLayout` places the panel above, below, right, then left of the list.
It includes the border in the display bounds.
It preserves image proportions and does not enlarge small images.
An image smaller than 180 by 130 points is not shown.

Both panels use `OverlayPanel`.
A display change closes the old panels and recreates them when needed.
This restores Space membership after a disconnect or resolution change.

## Logging model

`Diagnostics` is the single logging entry point.

- `error` records an error in the unified log and recent event list.
- `note` records routine events only when diagnostic logging is on.
- `trace` saves a state report regardless of the logging setting.

Routine message construction is lazy.
Error messages remain available when tracing is off.
The recent event list has 300 entries.
The menu preference controls routine recording in every build.

`DiagnosticLog` owns the file queue and rotation.
`trace` waits for earlier file writes before adding the report.
App termination flushes the queue.
A write failure goes to the unified log.

A menu report reads tracked records without refreshing them.
A command-line report first scans windows in its own process.
It cannot inspect another CmdTab process.

## Technical terms

| Term | Meaning |
|---|---|
| AX | The macOS Accessibility API |
| Chord | A physical key and modifier keys |
| Event tap | A macOS callback that receives and can consume input events |
| Focus | The window that receives keyboard input |
| HUD | The nonactivating window list panel |
| Space | A desktop or full screen workspace |
| WindowServer | The macOS service that manages display windows |
| Capture | Read an image of a window |
| Trace | A recorded sequence of application events |

Comments and documents use short, active sentences and consistent technical terms.
The writing reference is [ASD-STE100, Issue 9](https://www.asd-ste100.org/assets/files/ASD-STE100_ISSUE9.pdf).
Product names, API identifiers, and the terms above are technical vocabulary.
