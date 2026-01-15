import CoreBluetooth
import Foundation

final class PresenceTimeoutCalibrator: NSObject, CBCentralManagerDelegate {

    // MARK: - Tuneables
    private let summaryEverySeconds: TimeInterval = 30
    private let histogramBinWidth: TimeInterval = 0.25
    private let histogramMaxSeconds: TimeInterval = 10.0
    private let minGapSeconds: TimeInterval = 0.2
    private let logLongGapSeconds: TimeInterval = 10.0
    private let logEverySamples: Int = 200
    private let csvFilename = "presence_timeout_gaps.csv"
    private let falseThresholds: [TimeInterval] = [10, 20, 30, 45, 60, 90, 120, 150, 180]

    // Objective: false "away" per day (empirical in a present-only session).
    private let targetFalsePerDay: Double = 0.1
    private let safetyMarginSeconds: TimeInterval = 3.0
    private let maxSuggestedSeconds: TimeInterval = 120

    private let minValidRssi = -120
    private let maxValidRssi = -1

    // MARK: - Beacon target
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

    private let target = BeaconKey(
        uuid: "FDA50693-A4E2-4FB1-AFCF-C6EB07647825",
        major: 10011,
        minor: 19641
    )

    // MARK: - BLE + concurrency
    private let bleQueue = DispatchQueue(label: "cliptimer.ble.scan.queue")
    private var central: CBCentralManager!

    // Monotonic timestamps (ns)
    private var firstSeenNs: UInt64?
    private var lastIntervalNs: UInt64?

    // Observations
    private var gaps: [TimeInterval] = []
    private var observedDurationSeconds: TimeInterval = 0
    private var gapCount = 0
    private var falseCounts: [Int]

    // Timers / signals must be strongly held
    private var summaryTimer: DispatchSourceTimer?
    private var sigintSource: DispatchSourceSignal?
    private var sigtermSource: DispatchSourceSignal?
    private var csvHandle: FileHandle?
    private var csvUrl: URL?

    // Shutdown gate
    private var isShuttingDown = false

    override init() {
        falseCounts = Array(repeating: 0, count: falseThresholds.count)
        super.init()
        installSignalHandlers()
        central = CBCentralManager(delegate: self, queue: bleQueue)
    }

    // MARK: - Signals (Ctrl+C)
    private func installSignalHandlers() {
        signal(SIGINT, SIG_IGN)
        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigint.setEventHandler { [weak self] in
            if let self, self.isShuttingDown {
                self.forceExit(reason: "SIGINT (Ctrl+C)")
            } else {
                self?.shutdown(reason: "SIGINT (Ctrl+C)")
            }
        }
        sigint.resume()
        sigintSource = sigint

        signal(SIGTERM, SIG_IGN)
        let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigterm.setEventHandler { [weak self] in
            if let self, self.isShuttingDown {
                self.forceExit(reason: "SIGTERM")
            } else {
                self?.shutdown(reason: "SIGTERM")
            }
        }
        sigterm.resume()
        sigtermSource = sigterm
    }

    private func shutdown(reason: String) {
        guard !isShuttingDown else { return }
        isShuttingDown = true

        print("[BLE] shutdown requested: \(reason)")
        signal(SIGINT, SIG_DFL)
        signal(SIGTERM, SIG_DFL)

        bleQueue.async { [weak self] in
            guard let self else { return }

            self.central.stopScan()
            self.summaryTimer?.cancel()
            self.summaryTimer = nil

            self.emitSummary(isFinal: true)
            self.closeCsv()

            DispatchQueue.main.async {
                CFRunLoopStop(CFRunLoopGetMain())
            }
        }
    }

    private func forceExit(reason: String) {
        print("[BLE] force exit: \(reason)")
        closeCsv()
        fflush(stdout)
        _exit(130)
    }

    // MARK: - CBCentralManagerDelegate
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let stateDescription: String
        switch central.state {
        case .poweredOn:     stateDescription = "poweredOn"
        case .poweredOff:    stateDescription = "poweredOff"
        case .unauthorized:  stateDescription = "unauthorized"
        case .unsupported:   stateDescription = "unsupported"
        case .resetting:     stateDescription = "resetting"
        case .unknown:
            fallthrough
        @unknown default:    stateDescription = "unknown"
        }

        print("[BLE] central state = \(stateDescription)")

        if central.state == .poweredOn {
            startScan()
        } else if central.state == .unauthorized {
            print("[BLE] troubleshooting: System Settings -> Privacy & Security -> Bluetooth, allow this app.")
            lastIntervalNs = nil
        } else if central.state == .poweredOff {
            print("[BLE] troubleshooting: Bluetooth is off. Turn it on in System Settings -> Bluetooth.")
            lastIntervalNs = nil
        } else {
            lastIntervalNs = nil
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String : Any],
                        rssi RSSI: NSNumber) {

        guard let payload = parseIBeacon(advertisementData: advertisementData) else { return }
        let key = BeaconKey(uuid: payload.uuid, major: payload.major, minor: payload.minor)
        guard key == target else { return }

        let nowNs = DispatchTime.now().uptimeNanoseconds
        if firstSeenNs == nil { firstSeenNs = nowNs }

        let rssiValue = RSSI.intValue
        let validRssi = isValidRssi(rssiValue)

        if let last = lastIntervalNs {
            let delta = Double(nowNs - last) / 1_000_000_000.0
            if delta >= minGapSeconds {
                recordGap(delta, nowNs: nowNs, rssi: validRssi ? rssiValue : nil)
                lastIntervalNs = nowNs
            }
        } else {
            lastIntervalNs = nowNs
        }
    }

    // MARK: - Scan control
    private func startScan() {
        openCsvIfNeeded()
        central.scanForPeripherals(withServices: nil, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: true
        ])
        startSummaryTimerIfNeeded()
        print("[BLE] scanning started (presence timeout calibrator)")
    }

    private func startSummaryTimerIfNeeded() {
        guard summaryTimer == nil else { return }

        let timer = DispatchSource.makeTimerSource(queue: bleQueue)
        timer.schedule(deadline: .now() + summaryEverySeconds,
                       repeating: summaryEverySeconds,
                       leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in
            self?.emitSummary(isFinal: false)
        }
        timer.resume()
        summaryTimer = timer
    }

    private func recordGap(_ delta: TimeInterval, nowNs: UInt64, rssi: Int?) {
        gaps.append(delta)
        observedDurationSeconds += delta
        gapCount += 1
        for (index, threshold) in falseThresholds.enumerated() where delta >= threshold {
            falseCounts[index] += 1
        }

        if let firstNs = firstSeenNs {
            let wallSeconds = Double(nowNs - firstNs) / 1_000_000_000.0
            writeCsvLine(wallSeconds: wallSeconds, gapSeconds: delta, rssi: rssi)
        }

        if delta >= logLongGapSeconds {
            print("[BLE] long gap: \(formatSeconds(delta))s")
        } else if gapCount % logEverySamples == 0 {
            print("[BLE] gaps recorded: \(gapCount) last=\(formatSeconds(delta))s")
        }
    }

    // MARK: - Summary & suggestion logic
    private func emitSummary(isFinal: Bool) {
        guard let firstNs = firstSeenNs else {
            print("[BLE] \(isFinal ? "final" : "summary"): waiting for first beacon...")
            return
        }

        let nowNs = DispatchTime.now().uptimeNanoseconds
        let wallDuration = Double(nowNs - firstNs) / 1_000_000_000.0
        let activeDuration = max(observedDurationSeconds, 0.0)

        guard !gaps.isEmpty else {
            print("[BLE] \(isFinal ? "final" : "summary"): no gaps yet (wall=\(formatSeconds(wallDuration))s)")
            return
        }

        let s = summarize(gaps)
        let hist = histogram(gaps, binWidth: histogramBinWidth, maxSeconds: histogramMaxSeconds)

        let suggestion = suggestTimeouts(
            gaps: gaps,
            durationSeconds: activeDuration,
            targetFalsePerDay: targetFalsePerDay,
            safetyMargin: safetyMarginSeconds,
            maxSuggested: maxSuggestedSeconds
        )

        let exceed10 = gaps.filter { $0 >= 10 }.count
        let exceed20 = gaps.filter { $0 >= 20 }.count
        let exceed30 = gaps.filter { $0 >= 30 }.count

        let prefix = isFinal ? "[BLE] FINAL" : "[BLE] summary"

        print("\(prefix) wall=\(formatSeconds(wallDuration))s active=\(formatSeconds(activeDuration))s samples=\(s.count) min=\(formatSeconds(s.min))s avg=\(formatSeconds(s.avg))s p50=\(formatSeconds(s.p50))s p90=\(formatSeconds(s.p90))s p95=\(formatSeconds(s.p95))s p99=\(formatSeconds(s.p99))s max=\(formatSeconds(s.max))s exceed>=10s:\(exceed10) >=20s:\(exceed20) >=30s:\(exceed30)")

        print("\(prefix) histogram (bin=\(formatSeconds(histogramBinWidth))s, up to \(formatSeconds(histogramMaxSeconds))s): \(hist)")

        print("\(prefix) false/hour table: \(falsePerHourTable(durationSeconds: activeDuration))")

        if let suggestion = suggestion {
            print("\(prefix) suggested presence timeouts (empirical, target false/day <= \(String(format: "%.3f", targetFalsePerDay))): T1=\(formatSeconds(suggestion.t1))s (est false/day ≈ \(String(format: "%.3f", suggestion.falsePerDayAtT1))) T2=\(formatSeconds(suggestion.t2))s")
        } else {
            print("\(prefix) suggested timeouts: insufficient data to estimate reliably yet.")
        }
        csvHandle?.synchronizeFile()
    }

    private struct GapStats {
        let count: Int
        let min: TimeInterval
        let max: TimeInterval
        let avg: TimeInterval
        let p50: TimeInterval
        let p90: TimeInterval
        let p95: TimeInterval
        let p99: TimeInterval
    }

    private func summarize(_ values: [TimeInterval]) -> GapStats {
        let sorted = values.sorted()
        let n = sorted.count
        let minV = sorted.first ?? 0
        let maxV = sorted.last ?? 0
        let avgV = sorted.reduce(0, +) / Double(n)

        func quantile(_ q: Double) -> TimeInterval {
            guard n > 1 else { return sorted[0] }
            let pos = Double(n - 1) * q
            let i = Int(floor(pos))
            let frac = pos - Double(i)
            if i >= n - 1 { return sorted[n - 1] }
            return sorted[i] * (1 - frac) + sorted[i + 1] * frac
        }

        return GapStats(
            count: n,
            min: minV,
            max: maxV,
            avg: avgV,
            p50: quantile(0.50),
            p90: quantile(0.90),
            p95: quantile(0.95),
            p99: quantile(0.99)
        )
    }

    private func histogram(_ values: [TimeInterval], binWidth: TimeInterval, maxSeconds: TimeInterval) -> String {
        let bins = Int(ceil(maxSeconds / binWidth))
        var counts = Array(repeating: 0, count: bins + 1)

        for v in values {
            if v < 0 { continue }
            if v >= maxSeconds {
                counts[bins] += 1
            } else {
                let idx = Int(floor(v / binWidth))
                counts[min(max(idx, 0), bins - 1)] += 1
            }
        }

        var entries: [(String, Int)] = []
        for i in 0..<bins {
            if counts[i] == 0 { continue }
            let a = Double(i) * binWidth
            let b = a + binWidth
            entries.append(("[\(formatSeconds(a))–\(formatSeconds(b)))", counts[i]))
        }
        if counts[bins] > 0 {
            entries.append(("[>=\(formatSeconds(maxSeconds))]", counts[bins]))
        }

        entries.sort { $0.1 > $1.1 }
        let top = entries.prefix(5)
        if top.isEmpty { return "(no bins yet)" }
        return top.map { "\($0.0)=\($0.1)" }.joined(separator: " ")
    }

    private struct TimeoutSuggestion {
        let t1: TimeInterval
        let t2: TimeInterval
        let falsePerDayAtT1: Double
    }

    private func suggestTimeouts(gaps: [TimeInterval],
                                 durationSeconds: TimeInterval,
                                 targetFalsePerDay: Double,
                                 safetyMargin: TimeInterval,
                                 maxSuggested: TimeInterval) -> TimeoutSuggestion? {
        guard durationSeconds > 60, gaps.count >= 50 else { return nil }

        func falsePerDay(threshold: TimeInterval) -> Double {
            let exceed = gaps.reduce(0) { $0 + ($1 >= threshold ? 1 : 0) }
            return (Double(exceed) / durationSeconds) * 86400.0
        }

        let step: TimeInterval = 0.5
        var candidate: TimeInterval = step
        var chosen: TimeInterval?

        while candidate <= maxSuggested {
            if falsePerDay(threshold: candidate) <= targetFalsePerDay {
                chosen = candidate
                break
            }
            candidate += step
        }

        let baseT1: TimeInterval
        if let chosen = chosen {
            baseT1 = chosen
        } else {
            baseT1 = min((gaps.max() ?? maxSuggested) + safetyMargin, maxSuggested)
        }

        let t1 = min(baseT1 + safetyMargin, maxSuggested)
        let t2 = min(max(t1 * 2.0, t1 + 10.0), maxSuggested)

        return TimeoutSuggestion(
            t1: t1,
            t2: t2,
            falsePerDayAtT1: falsePerDay(threshold: baseT1)
        )
    }

    private func falsePerHourTable(durationSeconds: TimeInterval) -> String {
        let values = falsePerHourValues(durationSeconds: durationSeconds)
        return zip(falseThresholds, values).map { threshold, value in
            "\(Int(threshold))s=\(String(format: "%.2f", value))"
        }.joined(separator: " ")
    }

    // MARK: - iBeacon parsing
    private func parseIBeacon(advertisementData: [String: Any]) -> IBeaconPayload? {
        guard let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data else { return nil }
        let bytes = [UInt8](data)
        guard bytes.count >= 25 else { return nil }
        guard bytes[0] == 0x4C && bytes[1] == 0x00 && bytes[2] == 0x02 && bytes[3] == 0x15 else { return nil }

        let uuidBytes = Array(bytes[4..<20])
        let uuid = uuidString(from: uuidBytes)
        let major = (UInt16(bytes[20]) << 8) | UInt16(bytes[21])
        let minor = (UInt16(bytes[22]) << 8) | UInt16(bytes[23])
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

    private func isValidRssi(_ value: Int) -> Bool {
        return value >= minValidRssi && value <= maxValidRssi
    }

    private func openCsvIfNeeded() {
        guard csvHandle == nil else { return }
        let cwd = FileManager.default.currentDirectoryPath
        let url = URL(fileURLWithPath: cwd).appendingPathComponent(csvFilename)
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: nil)
        do {
            let handle = try FileHandle(forWritingTo: url)
            handle.truncateFile(atOffset: 0)
            let thresholdColumns = falseThresholds.map { "false_per_hour_\(Int($0))" }.joined(separator: ",")
            let header = "wall_seconds,gap_seconds,rssi,\(thresholdColumns)\n"
            if let data = header.data(using: .utf8) {
                handle.write(data)
            }
            csvHandle = handle
            csvUrl = url
            print("[BLE] csv output: \(url.path)")
        } catch {
            print("[BLE] csv error: \(error)")
        }
    }

    private func writeCsvLine(wallSeconds: TimeInterval, gapSeconds: TimeInterval, rssi: Int?) {
        guard let handle = csvHandle else { return }
        let rssiValue = rssi.map(String.init) ?? ""
        let values = falsePerHourValues(durationSeconds: observedDurationSeconds).map { String(format: "%.2f", $0) }.joined(separator: ",")
        let line = String(format: "%.2f,%.2f,%@,%@\n", wallSeconds, gapSeconds, rssiValue, values)
        if let data = line.data(using: .utf8) {
            handle.write(data)
        }
    }

    private func closeCsv() {
        guard let handle = csvHandle else { return }
        handle.synchronizeFile()
        handle.closeFile()
        if let url = csvUrl {
            print("[BLE] csv saved: \(url.path)")
        }
        csvHandle = nil
        csvUrl = nil
    }

    private func falsePerHourValues(durationSeconds: TimeInterval) -> [Double] {
        let hours = max(durationSeconds / 3600.0, 0.0001)
        return falseCounts.map { Double($0) / hours }
    }

    private func formatSeconds(_ value: TimeInterval) -> String {
        String(format: "%.2f", value)
    }
}

let calibrator = PresenceTimeoutCalibrator()
print("[BLE] presence timeout calibrator started. Press Ctrl+C to stop and print FINAL report.")
_ = calibrator
RunLoop.main.run()
print("[BLE] exited.")
