# Repository Guidelines

## Project Structure & Module Organization
- `Sources/beacon/main.swift` contains the CLI entry point and CoreBluetooth presence logic.
- `scripts/` holds ad‑hoc Swift utilities (e.g., `beacon_scan.swift`, `beacon_calibrate.swift`) for scanning or calibrating.
- `beacon_presence_notes.txt` documents runtime behavior and default thresholds.
- `presence_timeout_gaps.csv` is sample data used for tuning/analysis.

## Build, Test, and Development Commands
- `swift run beacon` builds and runs the CLI with default config.
- `swift run beacon -- --uuid <UUID> --major <major> --minor <minor>` runs with explicit target filters.
- `swift scripts/beacon_scan.swift` performs an interactive scan to discover beacon identifiers.
- `swift build` builds the executable without running it.

## Coding Style & Naming Conventions
- Swift code uses 4‑space indentation and standard Swift API Guidelines.
- Types use `UpperCamelCase`; functions/vars use `lowerCamelCase`.
- Script filenames in `scripts/` use `snake_case` to mirror current naming.
- Keep logging consistent with existing `[BLE] ...` prefixes.

## Testing Guidelines
- No automated test target exists yet; validation is manual.
- For changes to detection logic, verify with `swift run beacon` and check logs for state transitions.
- For scanning changes, verify output with `swift scripts/beacon_scan.swift`.
- If adding tests, prefer XCTest under `Tests/` with names like `BeaconPresenceTests`.

## Commit & Pull Request Guidelines
- Use short, imperative commit subjects (e.g., “Add iBeacon scanning script”).
- Keep commits focused; avoid mixing behavior changes with formatting.
- PRs should describe intent, list key commands run, and note any behavior changes to CLI flags.
- Update `README.md` and `beacon_presence_notes.txt` when defaults or CLI flags change.

## Configuration & Runtime Notes
- Bluetooth permission is required on macOS (System Settings → Privacy & Security → Bluetooth).
- Default thresholds and EMA behavior are documented in `beacon_presence_notes.txt`.
- The CLI stops re‑entry after the first “away” state; note this if modifying state handling.
