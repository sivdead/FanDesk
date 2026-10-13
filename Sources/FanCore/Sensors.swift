import Foundation
import Darwin

public struct SensorSpec: Sendable {
    public let key: String
    public let name: String
    public let category: String
    public let isCPU: Bool

    public init(key: String, name: String, category: String, isCPU: Bool = false) {
        self.key = key
        self.name = name
        self.category = category
        self.isCPU = isCPU
    }
}

/// Temperature labels are model-specific. In particular, `Tm*` is not always
/// memory and `Tp*` is not a list of individual CPU cores. Unidentified keys
/// remain visible by their SMC identifiers instead of receiving guessed names.
public enum SensorCatalog {
    public static func discover(smc: SMC) throws -> [SensorSpec] {
        let labels = knownLabels(model: systemString("hw.model") ?? "")
        var result = try smc.allKeys().filter { $0.hasPrefix("T") }.sorted().compactMap { key -> SensorSpec? in
            guard let info = try? smc.keyInfo(key), isTemperatureType(info),
                  let value = try? smc.readNumber(key), value.isFinite,
                  (1...130).contains(value) else { return nil }
            return labels[key] ?? SensorSpec(key: key, name: "温度传感器 \(key)", category: "其它")
        }
        let discovered = Set(result.map(\.key))
        // Keep expected CPU members even if the first reading is unavailable.
        // Otherwise a failed member would silently redefine the aggregate.
        result.append(contentsOf: labels.values.filter { $0.isCPU && !discovered.contains($0.key) })
        return result.sorted { $0.key < $1.key }
    }

    private static func isTemperatureType(_ info: SMC.KeyInfo) -> Bool {
        switch info.type.trimmingCharacters(in: .whitespaces) {
        case "flt": return info.size == 4
        case "ioft": return info.size == 8
        case "sp78": return info.size == 2
        default: return false
        }
    }

    private static func systemString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return nil }
        return String(cString: bytes)
    }

    private static func systemInteger(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }

    private static func physicalCoreCount(named name: String) -> Int {
        guard let levels = systemInteger("hw.nperflevels"), levels > 0 else { return 0 }
        for level in 0..<levels where systemString("hw.perflevel\(level).name") == name {
            return max(0, systemInteger("hw.perflevel\(level).physicalcpu") ?? 0)
        }
        return 0
    }

    private static func knownLabels(model: String) -> [String: SensorSpec] {
        var labels: [String: SensorSpec] = [:]
        func add(_ key: String, _ name: String, _ category: String, isCPU: Bool = false) {
            labels[key] = SensorSpec(key: key, name: name, category: category, isCPU: isCPU)
        }

        // Names verified against the installed Macs Fan Control 1.5.21 sensor
        // metadata: generic Apple Silicon labels and the MacBook Pro model rule.
        add("TB0T", "电池", "电池")
        add("TW0P", "无线芯片附近", "无线")
        add("TPMP", "电源附近", "电源")
        add("Th1H", "散热器附近", "机身")
        add("TA0P", "环境温度", "机身")
        if ["Mac17,2", "Mac17,3", "Mac17,4", "Mac17,6", "Mac17,7", "Mac17,8", "Mac17,9"].contains(model) {
            add("Ts0P", "触控板", "机身")
            add("Ts1P", "触控板振动器", "机身")
        }

        // These three labels are corroborated by the Stats project's Apple
        // Silicon sensor table. TH0x measures NAND, not the SSD SMART reading.
        add("TB1T", "电池 1", "电池")
        add("TB2T", "电池 2", "电池")
        add("TH0x", "SSD NAND", "存储")

        // MFC maps Mac17,6/7/8/9 to MacBookPro22,5/3/4/2. The
        // MacBookPro22,2+ rule declares up to 12 Tm performance-core sensors
        // and 8 Tp super-core sensors. MFC's running UI limits those lists to
        // the installed physical cores: this Mac17,8 reports 12 Performance
        // and 6 Super via hw.perflevel*.{name,physicalcpu}. Other advertised
        // temperature points remain visible as unknown sensors and must not
        // enter CPU Core Average merely because their prefix fits.
        if ["Mac17,6", "Mac17,7", "Mac17,8", "Mac17,9"].contains(model) {
            let performance = ["Tm04", "Tm0G", "Tm0R", "Tm0a", "Tm0j", "Tm1Q",
                               "Tm1c", "Tm1o", "Tm21", "Tm2D", "Tm2P", "Tm2n"]
            let superCores = ["Tp04", "Tp0G", "Tp0R", "Tp0a", "Tp0j", "Tp0u", "Tp1I", "Tp1g"]
            for (index, key) in performance.prefix(physicalCoreCount(named: "Performance")).enumerated() {
                add(key, "CPU 性能核心 \(index + 1)", "CPU", isCPU: true)
            }
            for (index, key) in superCores.prefix(physicalCoreCount(named: "Super")).enumerated() {
                add(key, "CPU 超级核心 \(index + 1)", "CPU", isCPU: true)
            }
            for (index, key) in ["Tg08", "Tg12", "Tg1x", "Tg29"].enumerated() {
                add(key, "GPU 集群 \(index + 1)", "GPU")
            }
        }
        return labels
    }
}
