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

    private var central: CBCentralManager!
    private var isScanning = false
    private let minRssi: Int
    private let printInterval: TimeInterval
    private var lastPrintByBeacon: [BeaconKey: Date] = [:]

    init(minRssi: Int, printInterval: TimeInterval) {
        self.minRssi = minRssi
        self.printInterval = printInterval
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
        if let lastPrint = lastPrintByBeacon[key], now.timeIntervalSince(lastPrint) < printInterval {
            return
        }
        lastPrintByBeacon[key] = now

        let timestamp = iso8601Formatter.string(from: now)
        print("[SCAN] \(timestamp) uuid=\(payload.uuid) major=\(payload.major) minor=\(payload.minor) rssi=\(rssiValue) tx=\(payload.txPower)")
    }

    private func startScanningIfNeeded() {
        guard !isScanning else { return }
        isScanning = true
        central.scanForPeripherals(withServices: nil, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: true
        ])
        print("[SCAN] scanning for iBeacon advertisements...")
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

    private lazy var iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

struct ScanConfig {
    let minRssi: Int
    let printInterval: TimeInterval
}

func parseConfig(from args: [String]) -> ScanConfig {
    var minRssi = -95
    var printInterval: TimeInterval = 2.0

    var index = 0
    while index < args.count {
        switch args[index] {
        case "--min-rssi":
            guard index + 1 < args.count, let value = Int(args[index + 1]) else {
                usageAndExit("invalid value for --min-rssi")
            }
            minRssi = value
            index += 2
        case "--print-interval":
            guard index + 1 < args.count, let value = Double(args[index + 1]), value >= 0 else {
                usageAndExit("invalid value for --print-interval")
            }
            printInterval = value
            index += 2
        case "--help", "-h":
            usageAndExit()
        default:
            usageAndExit("unknown argument: \(args[index])")
        }
    }

    return ScanConfig(minRssi: minRssi, printInterval: printInterval)
}

func usageAndExit(_ message: String? = nil) -> Never {
    if let message = message {
        print("[SCAN] error: \(message)")
    }
    print("[SCAN] usage: swift scripts/beacon_scan.swift [--min-rssi <dBm>] [--print-interval <seconds>]")
    exit(1)
}

let config = parseConfig(from: Array(CommandLine.arguments.dropFirst()))
print("[SCAN] starting scan with minRssi=\(config.minRssi) printInterval=\(String(format: "%.1f", config.printInterval))s")

let scanner = IBeaconScanner(minRssi: config.minRssi, printInterval: config.printInterval)
print("[SCAN] waiting for central state updates...")
_ = scanner
RunLoop.main.run()
