import Foundation
import Darwin
import Combine

@MainActor
final class SystemStatsManager: ObservableObject {
    static let shared = SystemStatsManager()

    @Published private(set) var cpuUsage: Double = 0.0
    @Published private(set) var ramPercent: Double = 0.0
    @Published private(set) var ramUsedGB: Double = 0.0
    @Published private(set) var ramTotalGB: Double = 0.0
    @Published private(set) var downloadSpeed: Double = 0.0
    @Published private(set) var uploadSpeed: Double = 0.0
    @Published private(set) var downloadSpeedFormatted: String = "0 B/s"
    @Published private(set) var uploadSpeedFormatted: String = "0 B/s"
    @Published private(set) var downloadSpeedCompact: String = "0B"
    @Published private(set) var uploadSpeedCompact: String = "0B"
    @Published private(set) var cpuHistory: [Double] = []
    @Published private(set) var netHistory: [Double] = []

    private var prevCpuInfo: processor_info_array_t?
    private var prevNumCpuInfo: mach_msg_type_number_t = 0
    private var lastNetSampleTime: Date?
    private var lastBytesIn: UInt64 = 0
    private var lastBytesOut: UInt64 = 0
    private var refreshToken: ModuleRefreshToken?
    private let maxHistorySamples = 16

    private init() {
        initRamTotal()
        registerRefreshJob()
        updateStats()
    }

    private func registerRefreshJob() {
        refreshToken = ModuleRefreshScheduler.shared.register(
            id: "systemStats.monitor",
            name: "System stats refresh",
            module: .builtIn(.systemStats),
            policy: .interval(2.0, tolerance: 0.5),
            enabled: { AppState.shared.systemStatsEnabled }
        ) { [weak self] in
            self?.updateStats()
        }
    }

    func updateStats() {
        updateCPU()
        updateRAM()
        updateNetwork()
    }

    // MARK: - CPU Usage

    private func updateCPU() {
        var cpuInfo: processor_info_array_t?
        var numCpuInfo: mach_msg_type_number_t = 0
        var numCPUsU: natural_t = 0

        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &numCPUsU,
            &cpuInfo,
            &numCpuInfo
        )

        guard result == KERN_SUCCESS, let cpuInfo else { return }

        defer {
            if let prev = prevCpuInfo {
                let prevSize = vm_size_t(prevNumCpuInfo) * vm_size_t(MemoryLayout<integer_t>.size)
                vm_deallocate(mach_task_self_, vm_address_t(bitPattern: prev), prevSize)
            }
            prevCpuInfo = cpuInfo
            prevNumCpuInfo = numCpuInfo
        }

        guard let prevCpuInfo else { return }

        var totalInUse: Int64 = 0
        var totalTotal: Int64 = 0

        for i in 0..<Int32(numCPUsU) {
            let base = Int(CPU_STATE_MAX * i)
            let user = Int64(cpuInfo[base + Int(CPU_STATE_USER)] - prevCpuInfo[base + Int(CPU_STATE_USER)])
            let sys  = Int64(cpuInfo[base + Int(CPU_STATE_SYSTEM)] - prevCpuInfo[base + Int(CPU_STATE_SYSTEM)])
            let nice = Int64(cpuInfo[base + Int(CPU_STATE_NICE)] - prevCpuInfo[base + Int(CPU_STATE_NICE)])
            let idle = Int64(cpuInfo[base + Int(CPU_STATE_IDLE)] - prevCpuInfo[base + Int(CPU_STATE_IDLE)])

            let inUse = user + sys + nice
            let total = inUse + idle
            totalInUse += inUse
            totalTotal += total
        }

        if totalTotal > 0 {
            let usage = max(0.0, min(100.0, Double(totalInUse) / Double(totalTotal) * 100.0))
            self.cpuUsage = usage
            appendHistory(usage, to: &cpuHistory)
        }
    }

    // MARK: - RAM Usage

    private func initRamTotal() {
        var memSize: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        if sysctlbyname("hw.memsize", &memSize, &size, nil, 0) == 0 {
            self.ramTotalGB = Double(memSize) / (1024.0 * 1024.0 * 1024.0)
        } else {
            self.ramTotalGB = 16.0
        }
    }

    private func updateRAM() {
        var vmStats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kerr = withUnsafeMutablePointer(to: &vmStats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        guard kerr == KERN_SUCCESS else { return }

        let pageSize = Double(vm_kernel_page_size)
        let active = Double(vmStats.active_count) * pageSize
        let wired = Double(vmStats.wire_count) * pageSize
        let compressed = Double(vmStats.compressor_page_count) * pageSize
        let usedBytes = active + wired + compressed
        let usedGB = usedBytes / (1024.0 * 1024.0 * 1024.0)

        self.ramUsedGB = usedGB
        if ramTotalGB > 0 {
            self.ramPercent = max(0.0, min(100.0, (usedGB / ramTotalGB) * 100.0))
        }
    }

    // MARK: - Network Traffic

    private func updateNetwork() {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return }
        defer { freeifaddrs(ifaddr) }

        var currentBytesIn: UInt64 = 0
        var currentBytesOut: UInt64 = 0
        var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr

        while let cur = ptr {
            let name = String(cString: cur.pointee.ifa_name)
            if cur.pointee.ifa_addr.pointee.sa_family == UInt8(AF_LINK) {
                // Ignore loopback
                if !name.hasPrefix("lo") {
                    if let data = cur.pointee.ifa_data {
                        let ifData = data.assumingMemoryBound(to: if_data.self)
                        currentBytesIn += UInt64(ifData.pointee.ifi_ibytes)
                        currentBytesOut += UInt64(ifData.pointee.ifi_obytes)
                    }
                }
            }
            ptr = cur.pointee.ifa_next
        }

        let now = Date()
        if let lastTime = lastNetSampleTime {
            let timeDelta = now.timeIntervalSince(lastTime)
            if timeDelta > 0.4 {
                let bytesInDelta = currentBytesIn >= lastBytesIn ? currentBytesIn - lastBytesIn : 0
                let bytesOutDelta = currentBytesOut >= lastBytesOut ? currentBytesOut - lastBytesOut : 0

                let downRate = Double(bytesInDelta) / timeDelta
                let upRate = Double(bytesOutDelta) / timeDelta

                self.downloadSpeed = downRate
                self.uploadSpeed = upRate
                self.downloadSpeedFormatted = Self.formatBytes(downRate, compact: false)
                self.uploadSpeedFormatted = Self.formatBytes(upRate, compact: false)
                self.downloadSpeedCompact = Self.formatBytes(downRate, compact: true)
                self.uploadSpeedCompact = Self.formatBytes(upRate, compact: true)
                appendHistory(downRate, to: &netHistory)
            }
        }

        lastBytesIn = currentBytesIn
        lastBytesOut = currentBytesOut
        lastNetSampleTime = now
    }

    private func appendHistory(_ value: Double, to history: inout [Double]) {
        history.append(value)
        if history.count > maxHistorySamples {
            history.removeFirst(history.count - maxHistorySamples)
        }
    }

    // MARK: - Formatters

    static func formatBytes(_ bytesPerSec: Double, compact: Bool) -> String {
        if bytesPerSec >= 1_000_000_000 {
            return compact
                ? String(format: "%.1fG", bytesPerSec / 1_000_000_000)
                : String(format: "%.1f GB/s", bytesPerSec / 1_000_000_000)
        }
        if bytesPerSec >= 1_000_000 {
            return compact
                ? String(format: "%.1fM", bytesPerSec / 1_000_000)
                : String(format: "%.1f MB/s", bytesPerSec / 1_000_000)
        }
        if bytesPerSec >= 1_000 {
            return compact
                ? String(format: "%.0fK", bytesPerSec / 1_000)
                : String(format: "%.0f KB/s", bytesPerSec / 1_000)
        }
        return compact
            ? "\(Int(bytesPerSec))B"
            : "\(Int(bytesPerSec)) B/s"
    }

    deinit {
        if let prev = prevCpuInfo {
            let prevSize = vm_size_t(prevNumCpuInfo) * vm_size_t(MemoryLayout<integer_t>.size)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: prev), prevSize)
        }
    }
}
