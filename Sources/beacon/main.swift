import CoreBluetooth
import Foundation

final class BLEPresenceDetector: NSObject, CBCentralManagerDelegate {
    struct BeaconKey: Hashable {
        let uuid: String
        let major: UInt16
        let minor: UInt16
    }

    struct IBeaconPayload {
        let uuid: String
        let major: UInt16
        let minor: UInt16
        let txPower: Int8
    }

    private enum PresenceState: String {
        case searching
        case present
        case away
    }

    var central: CBCentralManager!
    private var isScanning = false
    private var reportTimer: Timer?
    private var lastSeen: Date?
    private var lastRssi: Int?
    private var rssiFiltered: Double?
    private var lastState: PresenceState?
    private var firstPresenceConfirmed = false
    private var awayLocked = false
    private let startTime: Date
    private var lastLoggedMinute: Int?
    private var weakSince: Date?

    private let target: BeaconKey
    private let minValidRssiThreshold: Int
    private let weakSeconds: TimeInterval
    private let timeout: TimeInterval
    private let awayTimeout: TimeInterval
    private let emaAlpha: Double

    init(
        target: BeaconKey,
        minValidRssiThreshold: Int,
        weakSeconds: TimeInterval,
        timeout: TimeInterval,
        awayTimeout: TimeInterval,
        emaAlpha: Double
    ) {
        self.target = target
        self.minValidRssiThreshold = minValidRssiThreshold
        self.weakSeconds = weakSeconds
        self.timeout = timeout
        self.awayTimeout = awayTimeout
        self.emaAlpha = emaAlpha
        self.startTime = Date()
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let stateDescription: String
        switch central.state {
        case .poweredOn:
            stateDescription = "poweredOn"
        case .poweredOff:
            stateDescription = "poweredOff"
        case .unauthorized:
            stateDescription = "unauthorized"
        case .unsupported:
            stateDescription = "unsupported"
        case .resetting:
            stateDescription = "resetting"
        case .unknown:
            fallthrough
        @unknown default:
            stateDescription = "unknown"
        }

        print("[BLE] central state = \(stateDescription)")

        if central.state == .unauthorized {
            print("[BLE] troubleshooting: System Settings -> Privacy & Security -> Bluetooth, allow this app.")
        } else if central.state == .poweredOff {
            print("[BLE] troubleshooting: Bluetooth is off. Turn it on in System Settings -> Bluetooth.")
        } else if central.state == .poweredOn {
            startScanningIfNeeded()
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard let payload = parseIBeacon(advertisementData: advertisementData) else { return }
        let key = BeaconKey(uuid: payload.uuid, major: payload.major, minor: payload.minor)
        guard key == target else { return }

        let rssiValue = RSSI.intValue
        guard isValidRssi(rssiValue) else { return }

        lastRssi = rssiValue
        updateRssiFiltered(with: rssiValue)

        guard rssiValue >= minValidRssiThreshold else { return }

        let now = Date()
        lastSeen = now
    }

    private func startScanningIfNeeded() {
        guard !isScanning else { return }
        isScanning = true
        central.scanForPeripherals(withServices: nil, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: true
        ])
        startReportTimerIfNeeded()
        print("[BLE] scanning started (tracking 1 beacon)")
    }

    private func startReportTimerIfNeeded() {
        guard reportTimer == nil else { return }
        reportTimer = Timer.scheduledTimer(
            timeInterval: 1.0,
            target: self,
            selector: #selector(handleReportTimer),
            userInfo: nil,
            repeats: true
        )
    }

    @objc private func handleReportTimer() {
        reportPresence()
    }

    private func reportPresence() {
        let now = Date()
        let ageSeconds: Int? = lastSeen.map { Int(now.timeIntervalSince($0)) }
        var weakDuration: TimeInterval?
        if firstPresenceConfirmed, let filtered = rssiFiltered {
            if filtered < Double(minValidRssiThreshold) {
                if weakSince == nil {
                    weakSince = now
                }
                weakDuration = weakSince.map { now.timeIntervalSince($0) }
            } else {
                weakSince = nil
            }
        } else {
            weakSince = nil
        }
        let weakTimedOut = weakDuration.map { $0 >= weakSeconds } ?? false

        let state: PresenceState
        let reason: String

        if awayLocked {
            state = .away
            reason = "locked"
        } else if lastSeen == nil {
            state = .searching
            reason = "no-signal"
        } else if !firstPresenceConfirmed {
            firstPresenceConfirmed = true
            state = .present
            reason = "assumed"
        } else {
            if weakTimedOut {
                state = .away
                reason = "weak-rssi"
                awayLocked = true
            } else if let ageSeconds = ageSeconds, Double(ageSeconds) > awayTimeout {
                state = .away
                reason = "timeout"
                awayLocked = true
            } else if let ageSeconds = ageSeconds, Double(ageSeconds) > timeout {
                state = .present
                reason = "stale-hold"
            } else {
                state = .present
                reason = "hold"
            }
        }

        let presenceLabel = state.rawValue
        let rssiLabel = lastRssi.map { String($0) } ?? "NA"
        let rssiAvgLabel = rssiFiltered.map { String(format: "%.1f", $0) } ?? "NA"
        let ageLabel = ageSeconds.map { String($0) } ?? "NA"
        let timeoutLabel = String(format: "%.0f", timeout)
        let awayTimeoutLabel = String(format: "%.0f", awayTimeout)
        let weakAge = weakDuration.map { String(format: "%.0f", $0) } ?? "NA"
        let weakLabel = "weak=\(weakAge)s/\(Int(weakSeconds))s@\(minValidRssiThreshold)"
        let detailed = "[BLE] presence \(presenceLabel) (reason=\(reason), rssi=\(rssiLabel), rssiAvg=\(rssiAvgLabel), age=\(ageLabel)s, valid>=\(minValidRssiThreshold), \(weakLabel), timeout=\(timeoutLabel)s, awayTimeout=\(awayTimeoutLabel)s)"

        if state == .searching || lastState == nil || lastState != state {
            print(detailed)
        } else if firstPresenceConfirmed {
            let minuteIndex = Int(now.timeIntervalSince(startTime) / 60) + 1
            if lastLoggedMinute != minuteIndex {
                print("[BLE] minute \(minuteIndex): \(presenceLabel) (reason=\(reason), age=\(ageLabel)s, rssiAvg=\(rssiAvgLabel))")
                lastLoggedMinute = minuteIndex
            }
        }
        lastState = state
    }

    private func updateRssiFiltered(with value: Int) {
        let newValue = Double(value)
        if let current = rssiFiltered {
            rssiFiltered = (emaAlpha * newValue) + ((1.0 - emaAlpha) * current)
        } else {
            rssiFiltered = newValue
        }
    }

    private func isValidRssi(_ value: Int) -> Bool {
        return value >= -120 && value <= -1
    }

    private func parseIBeacon(advertisementData: [String: Any]) -> IBeaconPayload? {
        guard let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data else {
            return nil
        }

        let bytes = [UInt8](data)
        guard bytes.count >= 25 else { return nil }
        guard bytes[0] == 0x4C && bytes[1] == 0x00 && bytes[2] == 0x02 && bytes[3] == 0x15 else {
            return nil
        }

        let uuidBytes = bytes[4..<20]
        let uuid = uuidString(from: Array(uuidBytes))
        let major = UInt16(bytes[20]) << 8 | UInt16(bytes[21])
        let minor = UInt16(bytes[22]) << 8 | UInt16(bytes[23])
        let txPower = Int8(bitPattern: bytes[24])
        return IBeaconPayload(uuid: uuid, major: major, minor: minor, txPower: txPower)
    }

    private func uuidString(from bytes: [UInt8]) -> String {
        guard bytes.count == 16 else { return "unknown" }
        return String(format:
            "%02X%02X%02X%02X-%02X%02X-%02X%02X-%02X%02X-%02X%02X%02X%02X%02X%02X",
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5],
            bytes[6], bytes[7],
            bytes[8], bytes[9],
            bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        )
    }
}

struct AppConfig {
    let target: BLEPresenceDetector.BeaconKey
    let minValidRssiThreshold: Int
    let weakSeconds: TimeInterval
    let timeout: TimeInterval
    let awayTimeout: TimeInterval
    let emaAlpha: Double
}

let defaultTarget = BLEPresenceDetector.BeaconKey(
    uuid: "FDA50693-A4E2-4FB1-AFCF-C6EB07647825",
    major: 10011,
    minor: 19641
)

func parseConfig(from args: [String]) -> AppConfig {
    var uuid = defaultTarget.uuid
    var major = defaultTarget.major
    var minor = defaultTarget.minor
    var minValidRssiThreshold = -75
    var weakSeconds: TimeInterval = 60.0
    var timeout: TimeInterval = 113.0
    var awayTimeout: TimeInterval = 120.0
    var emaAlpha = 0.3

    var index = 0
    while index < args.count {
        switch args[index] {
        case "--uuid":
            guard index + 1 < args.count else { usageAndExit("missing value for --uuid") }
            uuid = args[index + 1].uppercased()
            index += 2
        case "--major":
            guard index + 1 < args.count, let value = UInt16(args[index + 1]) else {
                usageAndExit("invalid value for --major")
            }
            major = value
            index += 2
        case "--minor":
            guard index + 1 < args.count, let value = UInt16(args[index + 1]) else {
                usageAndExit("invalid value for --minor")
            }
            minor = value
            index += 2
        case "--min-valid-rssi":
            guard index + 1 < args.count, let value = Int(args[index + 1]) else {
                usageAndExit("invalid value for --min-valid-rssi")
            }
            minValidRssiThreshold = value
            index += 2
        case "--weak-seconds":
            guard index + 1 < args.count, let value = Double(args[index + 1]), value >= 1 else {
                usageAndExit("invalid value for --weak-seconds")
            }
            weakSeconds = value
            index += 2
        case "--timeout":
            guard index + 1 < args.count, let value = Double(args[index + 1]) else {
                usageAndExit("invalid value for --timeout")
            }
            timeout = value
            index += 2
        case "--away-timeout":
            guard index + 1 < args.count, let value = Double(args[index + 1]) else {
                usageAndExit("invalid value for --away-timeout")
            }
            awayTimeout = value
            index += 2
        case "--ema-alpha":
            guard index + 1 < args.count, let value = Double(args[index + 1]), value > 0, value <= 1 else {
                usageAndExit("invalid value for --ema-alpha")
            }
            emaAlpha = value
            index += 2
        case "--help", "-h":
            usageAndExit()
        default:
            usageAndExit("unknown argument: \(args[index])")
        }
    }

    let target = BLEPresenceDetector.BeaconKey(uuid: uuid, major: major, minor: minor)
    return AppConfig(
        target: target,
        minValidRssiThreshold: minValidRssiThreshold,
        weakSeconds: weakSeconds,
        timeout: timeout,
        awayTimeout: awayTimeout,
        emaAlpha: emaAlpha
    )
}

func usageAndExit(_ message: String? = nil) -> Never {
    if let message = message {
        print("[BLE] error: \(message)")
    }
    print("[BLE] usage: swift run beacon -- --uuid <UUID> --major <major> --minor <minor> [--min-valid-rssi <dBm>] [--weak-seconds <seconds>] [--timeout <seconds>] [--away-timeout <seconds>] [--ema-alpha <0-1>]")
    exit(1)
}

let config = parseConfig(from: Array(CommandLine.arguments.dropFirst()))
print("[BLE] tracking uuid=\(config.target.uuid) major=\(config.target.major) minor=\(config.target.minor) rssiThreshold>=\(config.minValidRssiThreshold) weakSeconds=\(Int(config.weakSeconds)) timeout(T1)=\(Int(config.timeout))s awayTimeout(T2)=\(Int(config.awayTimeout))s emaAlpha=\(String(format: "%.2f", config.emaAlpha))")
if config.awayTimeout < config.timeout {
    print("[BLE] note: away-timeout < timeout, stale-hold stage disabled")
}

let detector = BLEPresenceDetector(
    target: config.target,
    minValidRssiThreshold: config.minValidRssiThreshold,
    weakSeconds: config.weakSeconds,
    timeout: config.timeout,
    awayTimeout: config.awayTimeout,
    emaAlpha: config.emaAlpha
)
print("[BLE] waiting for central state updates...")
_ = detector
RunLoop.main.run()
