# Code review

Date: 2026-10-02.
Scope: all application sources, package targets, tests, build scripts, CI, comments, and current documentation.

The review produced a smaller implementation with explicit ownership of keyboard state, window traversal, actions, preview storage, and logging.

## Corrected findings

P1 denotes a failure of normal operation.
P2 denotes incorrect behavior, resource use, or diagnostic data.

| Priority | Finding | Correction | Evidence |
|---|---|---|---|
| P1 | The AX timeout covered only the app element. Window and notification elements could use the default timeout. | Set the process-wide timeout before AX operations. | Apple AX header and timeout documentation |
| P1 | Window actions and some preview captures ran inside the event tap callback. | Queue actions and visible preview updates after the callback. | Call path review |
| P1 | A local binding could remove a default switcher trigger. | Install switcher triggers before local bindings. Reserve reverse trigger variants. | Configuration regression tests |
| P2 | Shift triggers disagreed with reverse traversal. Triggers with the same key had ambiguous direction. | Reject Shift triggers. Restore defaults for equal trigger keys. | Configuration and keyboard tests |
| P2 | Consumed key down events could have unconsumed key up events. | Track consumed keys through commit, cancellation, and reload. | Keyboard tests |
| P2 | A pending focus report could restore a closed window to recent order. | Remove closed IDs from pending reports as well as settled order. | Focus order regression test |
| P2 | One shared pending session could overwrite a queued commit. | Capture each committed session in its queued operation. | State ownership review |
| P2 | Missing AX windows or subroles discarded otherwise valid window descriptions. | Read focused and main windows independently. Keep classification when a subrole is unavailable. | AX read path review |
| P2 | AX observers could be installed before permission. Removed observers had no explicit source removal. | Delay observer creation until permission. Remove run loop sources when apps stop. | Observer lifecycle review |
| P2 | Preview scaling limited width but not height. Frame count did not bound memory. | Limit both dimensions, frame count, and pixel bytes. Remove closed frames. | Preview cache tests |
| P2 | Preview placement omitted the panel border from available space. | Include the border before calculating placement. | Placement tests on negative display coordinates |
| P2 | Diagnostic export refreshed window records before reporting the failure state. | Read tracked state without a refresh. | Report call path review |
| P2 | The configuration target used a mutable unsafe global logging callback. | Keep configuration as values. Route runtime failures through one main actor logger. | Swift 6 release build |
| P2 | Event latency calculations mixed Mach ticks and nanoseconds. | Convert the current clock to nanoseconds before subtraction. | Apple timestamp documentation |
| P2 | The focus wrapper reported success without checking private API results. | Check front process and key-window event results. | Private declaration review |
| P2 | Tiling resized a full screen window before exit completed. | Wait for AX to report exit and read a new frame before tiling. | Transition call path review |
| P2 | External command exit failures were discarded. | Record launch errors and nonzero exit status. | Process lifecycle review |
| P2 | Debug and release logging had different behavior. CI did not run unit tests. | Remove conditional logging code and the separate debug job. Run release tests in CI. | Build and CI review |

The AX timeout is per call.
A process-wide setting is necessary for all elements.
See [Apple AX timeout documentation](https://developer.apple.com/documentation/applicationservices/1459345-axuielementsetmessagingtimeout).

CGEvent timestamps are nanoseconds from system startup.
See [Apple CGEventTimestamp documentation](https://developer.apple.com/documentation/coregraphics/cgeventtimestamp).

Private focus result types agree with [yabai declarations](https://github.com/asmvik/yabai/blob/master/src/misc/extern.h).
These declarations are implementation references, not public Apple API contracts.

## Simplification

Action classes, binding protocols, the binding installer, and the configuration logging callback were removed.
The configuration now returns a chord-to-action value table.
One app executor handles the action cases.
Window geometry belongs to the model target.

Source line count decreased from 3,783 to 3,159.
The count includes comments and blank lines.
Nonblank source lines, excluding whole-line comments, decreased from 2,648 to 2,517.

Tests that required particular action classes, object identity, or forwarding layers were removed.
The remaining tests check results, state transitions, geometric constraints, cache limits, and file behavior.

The unused HUD rendering command was removed.
One overlay owner supplies panels for the window list and preview.

## Validation

- `make test`: 100 release tests passed, with no failures or skips.
- The four AppKit panel tests passed with WindowServer access.
- `make app IDENTITY=-`: release app bundle built and signed.
- Strict code signature verification passed.
- CI YAML passed parsing. The release test step is present.
- Source and bundle property lists passed validation.
- The release report command completed with all report sections.
- The certificate script passed shell syntax validation.
- `git diff --check` passed.
- The README configuration passed JSON validation and application parsing.
- The release build and test build produced no compiler warnings.

The sandbox test run skipped the four panel tests.
A subsequent test run with WindowServer access passed all tests.

## Remaining limits

Private APIs can change or disappear.
The executable links these symbols directly, so a missing symbol can prevent startup.
Unit tests cannot establish compatibility with every macOS version.

AX operations still run on the main actor.
Several timeout-limited calls can delay the interface.
The latency trace identifies this condition.
A worker for AX reads would require another ownership model for AX elements and window snapshots.

Preview limits cover stored pixel data.
AppKit objects, app icons, and temporary capture images add memory.
Covered windows can still supply incomplete images.

Live focus, hidden app restoration, Dock gestures, Automation permission, and full screen transitions need manual checks.
These checks were not performed on user windows.

## Manual acceptance checks

1. Switch between two windows of one app.
2. Switch to a window on another Space.
3. Confirm the focused window and menu bar belong to the same app.
4. Hide an app that has known windows.
5. Select one of those windows.
6. Tile a full screen window after exit.
7. Disconnect a display while the list is open.
8. Confirm the list and preview remain on the available display.
9. Record a fault with Diagnostic Logging.
10. Export the report before an app restart.
11. Confirm that the report includes the earlier events and current state.

The [application model](architecture.md) is the current design reference.
The pre-existing dated design record remains unchanged.
