import AppKit
import Combine
import Darwin

struct ProcessStats {
    var cpuPercent: Double = 0
    var memBytes: UInt64 = 0
    /// nil = unavailable (nettop failed or first sample not yet complete)
    var netBytesPerSec: Double? = nil
}

/// Lightweight per-app resource poller for the Task Manager panel.
/// Runs only while the panel is open (start()/stop()), on its own 2s cadence —
/// intentionally slower than the 0.5s window poll.
@MainActor
final class ProcessMonitor: ObservableObject {
    static let shared = ProcessMonitor()

    @Published var stats: [pid_t: ProcessStats] = [:]

    private var timer: Timer?
    private var lastCPUTime: [pid_t: UInt64] = [:]   // mach ticks (user+system)
    private var lastSampleAt: Date?
    private var lastNetBytes: [pid_t: UInt64] = [:]  // total in+out from nettop
    private var timebase: mach_timebase_info_data_t = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return tb
    }()

    func start() {
        guard timer == nil else { return }
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        lastCPUTime = [:]; lastSampleAt = nil; lastNetBytes = [:]
    }

    private func sample() {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        let now = Date()
        let interval = lastSampleAt.map { now.timeIntervalSince($0) } ?? 0
        var newStats: [pid_t: ProcessStats] = [:]
        var newCPUTime: [pid_t: UInt64] = [:]

        for app in apps {
            let pid = app.processIdentifier
            var usage = rusage_info_current()
            let ok = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: (rusage_info_t?).self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0) == 0
                }
            }
            guard ok else { continue }

            var s = ProcessStats()
            s.memBytes = usage.ri_phys_footprint

            // CPU%: delta of (user+system) mach ticks over the poll interval
            let ticks = usage.ri_user_time + usage.ri_system_time
            newCPUTime[pid] = ticks
            if interval > 0, let prev = lastCPUTime[pid], ticks >= prev {
                let deltaNs = Double(ticks - prev) * Double(timebase.numer) / Double(timebase.denom)
                s.cpuPercent = deltaNs / (interval * 1_000_000_000) * 100
            }

            // Carry forward last known network rate until nettop refreshes it
            s.netBytesPerSec = stats[pid]?.netBytesPerSec
            newStats[pid] = s
        }

        lastCPUTime = newCPUTime
        lastSampleAt = now
        stats = newStats
        sampleNetwork(interval: interval)
    }

    /// Best-effort per-process network via `nettop` (no public API exists).
    /// Runs off-main; on any failure the column just stays "—".
    private func sampleNetwork(interval: TimeInterval) {
        let pids = Set(stats.keys)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
            task.arguments = ["-P", "-x", "-J", "bytes_in,bytes_out", "-l", "1"]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = Pipe()
            guard (try? task.run()) != nil else { return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            guard task.terminationStatus == 0,
                  let out = String(data: data, encoding: .utf8) else { return }

            // Lines look like: "firefox.1171,123456,7890,"
            var totals: [pid_t: UInt64] = [:]
            for line in out.split(separator: "\n") {
                let cols = line.split(separator: ",", omittingEmptySubsequences: false)
                guard cols.count >= 3,
                      let dotIdx = cols[0].lastIndex(of: "."),
                      let pid = pid_t(cols[0][cols[0].index(after: dotIdx)...]),
                      pids.contains(pid),
                      let bytesIn = UInt64(cols[1]), let bytesOut = UInt64(cols[2])
                else { continue }
                totals[pid] = bytesIn + bytesOut
            }

            Task { @MainActor [weak self] in
                guard let self else { return }
                for (pid, total) in totals {
                    guard var s = self.stats[pid] else { continue }
                    if interval > 0, let prev = self.lastNetBytes[pid], total >= prev {
                        s.netBytesPerSec = Double(total - prev) / interval
                    }
                    self.stats[pid] = s
                }
                self.lastNetBytes = totals
            }
        }
    }
}

// MARK: - Formatting helpers

extension ProcessStats {
    var cpuDisplay: String { String(format: "%.0f%%", cpuPercent) }
    var memDisplay: String {
        let mb = Double(memBytes) / 1_048_576
        return mb >= 1024 ? String(format: "%.1f GB", mb / 1024) : String(format: "%.0f MB", mb)
    }
    var netDisplay: String {
        guard let bps = netBytesPerSec else { return "—" }
        if bps >= 1_048_576 { return String(format: "%.1f MB/s", bps / 1_048_576) }
        if bps >= 1024 { return String(format: "%.0f KB/s", bps / 1024) }
        return String(format: "%.0f B/s", bps)
    }
}
