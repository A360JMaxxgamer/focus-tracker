# FocusTracker

Menu bar app for macOS 14+: the camera estimates which screen (or window) you are looking at
and moves keyboard focus there before you start typing. A local re-creation of the idea behind Glance Switch.

## Build & run

```bash
./scripts/build-app.sh          # -> build/FocusTracker.app
open build/FocusTracker.app
INSTALL=1 ./scripts/build-app.sh # also copy to ~/Applications
swift test                       # model tests
```

The script signs with the first "Apple Development" identity (or `SIGN_IDENTITY=...`).
With a stable signature, the Camera and Accessibility permissions survive rebuilds; with ad-hoc signing (`-`) they don't.

On first launch: allow **Camera** and **Accessibility**, then **Calibrate** (follow the dot on each screen).

> Tip: The arrangement in System Settings → Displays should match the real physical layout (e.g. MacBook below the monitor it sits under). The shared model uses it as its coordinate system.

## Profiles

A profile = its own name, camera, and calibration (e.g. "Home", "Office").
Menu → **Profiles** or Settings: create, rename, delete, switch.

**Switch automatically** (on by default): when screens/cameras are connected, on wake, and at launch, the app picks the profile
whose calibrated screens are all connected. A matching arrangement and an available profile camera give a bonus; if
the screens are identical, the camera decides. If no profile matches, the current one stays active.

Office workflow: Menu → Profiles → "New Profile…" → enter a name → calibrate. From then on it switches by itself.

Data: `~/Library/Application Support/FocusTracker/profiles.json` + `profiles/<id>.json` (calibration per profile).
The old `calibration.json` becomes the "Default" profile on first launch.

## Install on another Mac

```bash
./scripts/package.sh   # -> dist/FocusTracker-<version>.dmg and .zip (Universal: Apple silicon + Intel)
```

Copy the DMG to the other Mac, open it, drag the app into "Applications".
The app is only signed with "Apple Development", not notarized → Gatekeeper blocks the first launch. Either:

- Double-click → dismiss the dialog → System Settings → Privacy & Security → "Open Anyway", or
- `xattr -dr com.apple.quarantine /Applications/FocusTracker.app`

Then allow Camera + Accessibility and recalibrate there (calibration is per Mac/seating position).

## How it works

| Step | File |
|---|---|
| Camera at 720p, max. 15 fps, frames kept in memory only; Vision yaw/pitch + nose relative to eye center (roll-corrected) + pupil offset + seating position | `HeadTracker.swift` |
| Shared model across all screens in the macOS arrangement (with quadratic head-pose terms) decides the screen or "looking away"; per-screen model yields the point on the screen; error via leave-one-point-out | `GazeModel.swift` |
| Median + EMA smoothing, dwell (300 ms), edge margin (5 %), lock while typing/using the mouse, window choice by probability share, focus retry | `FocusEngine.swift` |
| Focus via Accessibility (raise + frontmost, no synthetic click), move pointer along, remember last window per screen | `WindowFocus.swift` |
| 3×3 grid + extra points on shared edges | `Calibration.swift` |
| Learning from clicks (max. 60/screen), warning when hit rate drops | `FocusEngine.handleClick` |
| ⇧⌘G pause, stop on sleep/lock | `HotKey.swift`, `AppDelegate.swift` |

### Accuracy

- After calibration the app shows the estimated accuracy per screen (±% of screen width). At ±25 % or worse: check lighting/camera, recalibrate.
- During calibration, actually turn your head toward the dot and sit normally.
- Window choice: the gaze estimate is laid over the visible windows as a probability distribution (separate horizontal/vertical accuracy). A window wins at 60 % with a clear lead; otherwise the last used one stays focused.
- **Monitor…** → "Waiting for" shows why it isn't switching right now (typing, mouse in use, settling, looking away).
- **Record Diagnostics** writes features + decisions (no images) to `~/Library/Application Support/FocusTracker/diagnostics/` — for tuning.

Menu → **Monitor…** shows live values (yaw/pitch, scores per screen); **Show Gaze Dot** shows the estimated gaze point.

## Still open

- Split panes in terminals/editors (original: click into pane center or app-specific APIs)
- Window choice on the same screen is coarse with webcam accuracy → only large, clearly separated windows
