# Beacon CLI

Swift CLI for beacon presence detection on macOS using CoreBluetooth.

Behavior (current)
- First valid ad => present.
- Away if EMA stays below `--min-valid-rssi` for `--weak-seconds` OR no valid ads for `--away-timeout`.
- First away is final (no re-entry).

Build and run
```
swift run beacon
```

Scan for beacons (to discover UUID/major/minor before configuring the main CLI):
```
swift scripts/beacon_scan.swift
```

Flags
- `--uuid <UUID>` / `--major <major>` / `--minor <minor>`
- `--min-valid-rssi <dBm>`
- `--weak-seconds <seconds>`
- `--timeout <seconds>`
- `--away-timeout <seconds>`
- `--ema-alpha <0-1>`

Notes and current defaults: `beacon_presence_notes.txt`

Interactive scan
```
swift scripts/beacon_scan.swift
```
