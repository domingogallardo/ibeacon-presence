import CoreBluetooth
import Foundation

final class BeaconCalibration: NSObject, CBCentralManagerDelegate {
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

    struct Stats {
        let count: Int
        let min: Double
        let max: Double
        let median: Double
        let p25: Double
        let p75: Double
        let avg: Double
    }

    enum Phase {
        case waitingBluetooth
        case awaitBaseline
        case baseline
        case awaitAway
        case away
        case done
    }

    private let target = BeaconKey(
        uuid: "FDA50693-A4E2-4FB1-AFCF-C6EB07647825",
        major: 10011,
        minor: 19641
    )

    private let baselineDuration: TimeInterval = 20.0
    private let awayDuration: TimeInterval = 30.0
    private let minIntervalDelta: TimeInterval = 0.2
    private let minSamplesPerPhase = 15
    private let minValidRssi = -120
    private let maxValidRssi = -1

    private var central: CBCentralManager!
    private var phase: Phase = .waitingBluetooth
    private var phaseStart: Date?
    private var tickTimer: Timer?
    private var lastRemaining: Int?

    private var baselineSamples: [Int] = []
    private var awaySamples: [Int] = []
    private var intervals: [TimeInterval] = []
    private var lastAdvertAt: Date?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func start() {
        startInputListener()
        startTickTimer()
        print("[BLE] calibration ready for UUID \(target.uuid) major=\(target.major) minor=\(target.minor)")
        print("[BLE] waiting for Bluetooth...")
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
            return
        }
        if central.state == .poweredOff {
            print("[BLE] troubleshooting: Bluetooth is off. Turn it on in System Settings -> Bluetooth.")
            return
        }
        if central.state == .poweredOn {
            startScanIfNeeded()
            if phase == .waitingBluetooth {
                phase = .awaitBaseline
                print("[BLE] Step 1/2: place the beacon next to the computer.")
                print("[BLE] Press Enter to start baseline capture (\(Int(baselineDuration))s).")
            }
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

        let now = Date()
        if let last = lastAdvertAt {
            let delta = now.timeIntervalSince(last)
            if delta >= minIntervalDelta {
                intervals.append(delta)
            }
        }
        lastAdvertAt = now

        let rssiValue = RSSI.intValue
        guard isValidRssi(rssiValue) else { return }
        switch phase {
        case .baseline:
            baselineSamples.append(rssiValue)
        case .away:
            awaySamples.append(rssiValue)
        default:
            break
        }
    }

    private func startScanIfNeeded() {
        central.scanForPeripherals(withServices: nil, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: true
        ])
        print("[BLE] scanning started")
    }

    private func startInputListener() {
        FileHandle.standardInput.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if let input = String(data: data, encoding: .utf8), input.contains("\n") {
                DispatchQueue.main.async {
                    self?.handleInput()
                }
            }
        }
    }

    private func handleInput() {
        switch phase {
        case .awaitBaseline:
            startBaseline()
        case .awaitAway:
            startAway()
        default:
            break
        }
    }

    private func startBaseline() {
        baselineSamples.removeAll(keepingCapacity: true)
        phase = .baseline
        phaseStart = Date()
        lastRemaining = nil
        print("[BLE] baseline started: stay close for \(Int(baselineDuration))s")
    }

    private func startAway() {
        awaySamples.removeAll(keepingCapacity: true)
        phase = .away
        phaseStart = Date()
        lastRemaining = nil
        print("[BLE] away started: move away for \(Int(awayDuration))s")
    }

    private func startTickTimer() {
        tickTimer = Timer.scheduledTimer(
            timeInterval: 1.0,
            target: self,
            selector: #selector(handleTick),
            userInfo: nil,
            repeats: true
        )
    }

    @objc private func handleTick() {
        switch phase {
        case .baseline:
            updateCountdown(total: baselineDuration, label: "baseline")
        case .away:
            updateCountdown(total: awayDuration, label: "away")
        default:
            break
        }
    }

    private func updateCountdown(total: TimeInterval, label: String) {
        guard let start = phaseStart else { return }
        let elapsed = Date().timeIntervalSince(start)
        let remaining = max(0, Int(ceil(total - elapsed)))
        if remaining != lastRemaining {
            if remaining % 5 == 0 || remaining <= 5 {
                let sampleCount = (label == "baseline") ? baselineSamples.count : awaySamples.count
                print("[BLE] \(label) remaining: \(remaining)s (samples=\(sampleCount))")
            }
            lastRemaining = remaining
        }

        if elapsed >= total {
            if label == "baseline" {
                if baselineSamples.count >= minSamplesPerPhase {
                    finishBaseline()
                } else {
                    print("[BLE] baseline extended: need \(minSamplesPerPhase) samples (have \(baselineSamples.count))")
                    extendPhase()
                }
            } else {
                if awaySamples.count >= minSamplesPerPhase {
                    finishAway()
                } else {
                    print("[BLE] away extended: need \(minSamplesPerPhase) samples (have \(awaySamples.count))")
                    extendPhase()
                }
            }
        }
    }

    private func extendPhase() {
        phaseStart = Date()
        lastRemaining = nil
    }

    private func finishBaseline() {
        phase = .awaitAway
        phaseStart = nil
        print("[BLE] baseline complete: \(baselineSamples.count) samples")
        print("[BLE] Step 2/2: move to another room or further away.")
        print("[BLE] Press Enter to start away capture (\(Int(awayDuration))s).")
    }

    private func finishAway() {
        phase = .done
        phaseStart = nil
        print("[BLE] away complete: \(awaySamples.count) samples")
        central.stopScan()
        summarize()
        print("[BLE] calibration done")
    }

    private func summarize() {
        guard baselineSamples.count >= minSamplesPerPhase, awaySamples.count >= minSamplesPerPhase else {
            print("[BLE] summary: insufficient samples (baseline=\(baselineSamples.count), away=\(awaySamples.count), min=\(minSamplesPerPhase))")
            print("[BLE] retry: keep the beacon steady and closer for baseline, then farther for away")
            return
        }

        let baselineStats = computeStats(from: baselineSamples)
        let awayStats = computeStats(from: awaySamples)
        print("[BLE] baseline stats: count=\(baselineStats.count) median=\(format(baselineStats.median)) p25=\(format(baselineStats.p25)) p75=\(format(baselineStats.p75)) min=\(format(baselineStats.min)) max=\(format(baselineStats.max))")
        print("[BLE] away stats:     count=\(awayStats.count) median=\(format(awayStats.median)) p25=\(format(awayStats.p25)) p75=\(format(awayStats.p75)) min=\(format(awayStats.min)) max=\(format(awayStats.max))")

        let dropMedian = baselineStats.median - awayStats.median
        let dropConservative = baselineStats.p25 - awayStats.p75
        print("[BLE] drop median=\(format(dropMedian)) dB, conservative=\(format(dropConservative)) dB")

        let intervalStats = computeIntervalStats()
        if let intervalStats = intervalStats {
            print("[BLE] adv interval p50=\(format(intervalStats.p50))s p90=\(format(intervalStats.p90))s p95=\(format(intervalStats.p95))s max=\(format(intervalStats.max))s")
        }

        let minValidRssiRaw = Int(round((baselineStats.p25 + awayStats.p75) / 2.0))
        let minValidRssi = clampRssi(minValidRssiRaw)
        print("[BLE] min-valid-rssi range: [\(Int(round(awayStats.p75))), \(Int(round(baselineStats.p25)))] -> suggested \(minValidRssi)")
        let baselineBelow = baselineSamples.filter { $0 < minValidRssi }.count
        let awayAbove = awaySamples.filter { $0 >= minValidRssi }.count
        let baselineBelowPct = (Double(baselineBelow) / Double(max(baselineSamples.count, 1))) * 100.0
        let awayAbovePct = (Double(awayAbove) / Double(max(awaySamples.count, 1))) * 100.0
        print("[BLE] min-valid-rssi check: baseline< \(baselineBelow)/\(baselineSamples.count) (\(formatPercent(baselineBelowPct))) away>= \(awayAbove)/\(awaySamples.count) (\(formatPercent(awayAbovePct)))")

        let p95Interval = intervalStats?.p95 ?? 20.0
        let baseTimeout = max(60, Int(ceil(p95Interval * 3.0)))
        let recommendedAwayTimeout = baseTimeout + Int(ceil(p95Interval))
        let recommendedWeakSeconds = max(20, Int(ceil(p95Interval * 2.0)))
        let recommendedWeakPrimeSeconds = max(10, Int(ceil(p95Interval * 4.0)))
        let recommendedEmaAlpha = 0.30

        let emaLabel = String(format: "%.2f", recommendedEmaAlpha)
        print("[BLE] weak-prime-seconds hint: p95 interval \(format(p95Interval))s -> ~4 ads = \(recommendedWeakPrimeSeconds)s")
        let suggested = "[BLE] swift run beacon -- --min-valid-rssi \(minValidRssi) --weak-seconds \(recommendedWeakSeconds) --weak-prime-seconds \(recommendedWeakPrimeSeconds) --away-timeout \(recommendedAwayTimeout) --ema-alpha \(emaLabel)"
        print("[BLE] suggested flags:")
        print(suggested)

        if dropMedian < 6 || baselineStats.p25 <= awayStats.p75 {
            print("[BLE] warning: baseline/away separation is small; try moving farther during away phase.")
        }
    }

    private func computeStats(from values: [Int]) -> Stats {
        let sorted = values.sorted()
        let count = sorted.count
        let minValue = Double(sorted.first ?? 0)
        let maxValue = Double(sorted.last ?? 0)
        let avgValue = Double(sorted.reduce(0, +)) / Double(count)

        func percentile(_ p: Double) -> Double {
            guard count > 1 else { return Double(sorted[0]) }
            let index = Int(Double(count - 1) * p)
            return Double(sorted[index])
        }

        let medianValue: Double
        if count % 2 == 0 {
            medianValue = (Double(sorted[count / 2 - 1]) + Double(sorted[count / 2])) / 2.0
        } else {
            medianValue = Double(sorted[count / 2])
        }

        return Stats(
            count: count,
            min: minValue,
            max: maxValue,
            median: medianValue,
            p25: percentile(0.25),
            p75: percentile(0.75),
            avg: avgValue
        )
    }

    private func computeIntervalStats() -> (p50: Double, p90: Double, p95: Double, max: Double)? {
        guard !intervals.isEmpty else { return nil }
        let sorted = intervals.sorted()
        let count = sorted.count
        func percentile(_ p: Double) -> Double {
            guard count > 1 else { return sorted[0] }
            let index = Int(Double(count - 1) * p)
            return sorted[index]
        }
        return (p50: percentile(0.50), p90: percentile(0.90), p95: percentile(0.95), max: sorted.last ?? 0)
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

    private func format(_ value: Double) -> String {
        return String(format: "%.1f", value)
    }

    private func formatPercent(_ value: Double) -> String {
        return String(format: "%.1f%%", value)
    }

    private func isValidRssi(_ value: Int) -> Bool {
        return value >= minValidRssi && value <= maxValidRssi
    }

    private func clampRssi(_ value: Int) -> Int {
        return min(max(value, minValidRssi), maxValidRssi)
    }
}

let calibrator = BeaconCalibration()
calibrator.start()
RunLoop.main.run()
