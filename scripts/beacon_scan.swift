import CoreBluetooth
import Foundation

final class IBeaconScanner: NSObject, CBCentralManagerDelegate {
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

    private enum Phase {
        case discovery
        case away
        case done
    }

    private struct BeaconStats {
        var baseline: [Int] = []
        var away: [Int] = []
        var lastRssi: Int = 0
        var lastSeen: Date = Date()
    }

    private var central: CBCentralManager!
    private var isScanning = false
    private let minRssi: Int
    private var phase: Phase = .discovery
    private var statsByBeacon: [BeaconKey: BeaconStats] = [:]
    private var order: [BeaconKey] = []

    private let awayDuration: TimeInterval = 60.0
    private var awayEnd: Date?
    private var countdownTimer: Timer?
    private var finishTimer: Timer?
    private var awaitingStart = false

    init(minRssi: Int) {
        self.minRssi = minRssi
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func start() {
        print("[SCAN] Step 1/2: scanning for iBeacons. Keep the beacon near the computer.")
        print("[SCAN] Found beacons will be listed as they appear.")
        print("[SCAN] Press Enter to start the 1-minute away test.")
        waitForEnter()
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

        print("[SCAN] central state = \(stateDescription)")

        if central.state == .unauthorized {
            print("[SCAN] troubleshooting: System Settings -> Privacy & Security -> Bluetooth, allow this app.")
        } else if central.state == .poweredOff {
            print("[SCAN] troubleshooting: Bluetooth is off. Turn it on in System Settings -> Bluetooth.")
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
        let rssiValue = RSSI.intValue
        guard isValidRssi(rssiValue) else { return }
        guard rssiValue >= minRssi else { return }

        let now = Date()
        let key = BeaconKey(uuid: payload.uuid, major: payload.major, minor: payload.minor)
        if statsByBeacon[key] == nil {
            guard phase == .discovery else { return }
            statsByBeacon[key] = BeaconStats(lastRssi: rssiValue, lastSeen: now)
            order.append(key)
            print("[SCAN] found #\(order.count) uuid=\(payload.uuid) major=\(payload.major) minor=\(payload.minor) rssi=\(rssiValue) tx=\(payload.txPower)")
        }

        var stats = statsByBeacon[key] ?? BeaconStats()
        stats.lastRssi = rssiValue
        stats.lastSeen = now
        if phase == .discovery {
            stats.baseline.append(rssiValue)
        } else if phase == .away {
            stats.away.append(rssiValue)
        }
        statsByBeacon[key] = stats
    }

    private func startScanningIfNeeded() {
        guard !isScanning else { return }
        isScanning = true
        central.scanForPeripherals(withServices: nil, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: true
        ])
        print("[SCAN] scanning for iBeacon advertisements (minRssi=\(minRssi))...")
    }

    private func waitForEnter() {
        guard !awaitingStart else { return }
        awaitingStart = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = readLine()
            DispatchQueue.main.async {
                self?.awaitingStart = false
                self?.startAwayCapture()
            }
        }
    }

    private func startAwayCapture() {
        guard phase == .discovery else { return }
        if order.isEmpty {
            print("[SCAN] no beacons detected yet. Wait a bit and press Enter again.")
            waitForEnter()
            return
        }

        print("[SCAN] discovered beacons:")
        for (index, key) in order.enumerated() {
            print("[SCAN]   #\(index + 1) uuid=\(key.uuid) major=\(key.major) minor=\(key.minor)")
        }

        phase = .away
        awayEnd = Date().addingTimeInterval(awayDuration)
        print("[SCAN] Step 2/2: move away with the beacon now for \(Int(awayDuration))s.")
        print("[SCAN] capturing away window...")

        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.printAwayCountdown()
        }

        finishTimer?.invalidate()
        finishTimer = Timer.scheduledTimer(withTimeInterval: awayDuration, repeats: false) { [weak self] _ in
            self?.finishAwayCapture()
        }
    }

    private func printAwayCountdown() {
        guard phase == .away, let awayEnd else { return }
        let remaining = max(0, Int(awayEnd.timeIntervalSinceNow.rounded(.up)))
        print("[SCAN] away remaining: \(remaining)s")
    }

    private func finishAwayCapture() {
        guard phase == .away else { return }
        phase = .done
        countdownTimer?.invalidate()
        finishTimer?.invalidate()
        central.stopScan()
        print("[SCAN] away capture complete. Analyzing...")
        reportMovedBeacon()
        DispatchQueue.main.async {
            CFRunLoopStop(CFRunLoopGetMain())
        }
    }

    private func reportMovedBeacon() {
        guard !order.isEmpty else {
            print("[SCAN] no beacons captured.")
            return
        }

        print("[SCAN] results:")
        var bestKey: BeaconKey?
        var bestScore = -Double.infinity
        var bestReason = ""

        for (index, key) in order.enumerated() {
            guard let stats = statsByBeacon[key] else { continue }
            guard let baseMedian = median(stats.baseline) else {
                print("[SCAN]   #\(index + 1) uuid=\(key.uuid) major=\(key.major) minor=\(key.minor) baseline=NA away=NA")
                continue
            }
            let awayMedian = median(stats.away)

            let score: Double
            let reason: String
            if stats.away.isEmpty {
                score = 999
                reason = "missing"
            } else {
                score = baseMedian - (awayMedian ?? baseMedian)
                reason = "drop"
            }

            let baseLabel = format(baseMedian)
            let awayLabel = awayMedian.map(format) ?? "NA"
            print("[SCAN]   #\(index + 1) uuid=\(key.uuid) major=\(key.major) minor=\(key.minor) base=\(baseLabel) (n=\(stats.baseline.count)) away=\(awayLabel) (n=\(stats.away.count)) score=\(format(score))")

            if score > bestScore {
                bestScore = score
                bestKey = key
                bestReason = reason
            }
        }

        guard let bestKey else {
            print("[SCAN] could not determine which beacon moved.")
            return
        }

        let reasonLabel = bestReason == "missing" ? "no away samples" : "largest RSSI drop"
        print("[SCAN] moved beacon -> uuid=\(bestKey.uuid) major=\(bestKey.major) minor=\(bestKey.minor) (\(reasonLabel))")
    }

    private func median(_ values: [Int]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let count = sorted.count
        if count % 2 == 1 {
            return Double(sorted[count / 2])
        }
        let left = Double(sorted[count / 2 - 1])
        let right = Double(sorted[count / 2])
        return (left + right) / 2.0
    }

    private func format(_ value: Double) -> String {
        String(format: "%.1f", value)
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

struct ScanConfig {
    let minRssi: Int
}

func parseConfig(from args: [String]) -> ScanConfig {
    var minRssi = -95

    var index = 0
    while index < args.count {
        switch args[index] {
        case "--min-rssi":
            guard index + 1 < args.count, let value = Int(args[index + 1]) else {
                usageAndExit("invalid value for --min-rssi")
            }
            minRssi = value
            index += 2
        case "--help", "-h":
            usageAndExit()
        default:
            usageAndExit("unknown argument: \(args[index])")
        }
    }

    return ScanConfig(minRssi: minRssi)
}

func usageAndExit(_ message: String? = nil) -> Never {
    if let message = message {
        print("[SCAN] error: \(message)")
    }
    print("[SCAN] usage: swift scripts/beacon_scan.swift [--min-rssi <dBm>]")
    exit(1)
}

let config = parseConfig(from: Array(CommandLine.arguments.dropFirst()))
print("[SCAN] starting with minRssi=\(config.minRssi)")

let scanner = IBeaconScanner(minRssi: config.minRssi)
scanner.start()
print("[SCAN] waiting for central state updates...")
_ = scanner
RunLoop.main.run()
