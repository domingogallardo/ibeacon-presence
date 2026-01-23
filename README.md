# Beacon CLI

Swift CLI for beacon presence detection on macOS using CoreBluetooth.

Behavior (current)
- First valid ad => present.
- Away if EMA stays below `--min-valid-rssi` for `--weak-seconds` OR no valid ads for `--away-timeout` after EMA has been below `--min-valid-rssi` for at least `--weak-prime-seconds`.
- On away, scanning pauses and prompts `Press enter to confirm your presence`, then restarts detection.
- If Bluetooth turns off, scanning stops and resumes automatically when it turns back on.

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
- `--weak-prime-seconds <seconds>`
- `--away-timeout <seconds>`
- `--ema-alpha <0-1>`

Defaults
- `--min-valid-rssi -70`
- `--weak-seconds 30`
- `--weak-prime-seconds 20`
- `--away-timeout 90`
- `--ema-alpha 0.30`

Notes and current defaults: `beacon_presence_notes.txt`

Interactive scan
```
swift scripts/beacon_scan.swift
```
