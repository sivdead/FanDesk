import Foundation

public enum DeskError: Error, LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case let .invalid(s) = self { return s }; return nil }
}

public enum FanMode: String, Codable, CaseIterable {
    case automatic, constant, temperature
    public var title: String {
        switch self {
        case .automatic: return "系统自动"
        case .constant: return "固定转速"
        case .temperature: return "温度控制"
        }
    }
}

public struct SensorChoice: RawRepresentable, Codable, Hashable {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let cpuAverage = SensorChoice(rawValue: "cpuAverage")
    public static let cpuMaximum = SensorChoice(rawValue: "cpuMaximum")
    public var title: String {
        if self == .cpuAverage { return "CPU 传感器平均" }
        if self == .cpuMaximum { return "CPU 最高温度" }
        return rawValue
    }
    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }
    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer(); try value.encode(rawValue)
    }
}

public struct FanCurve: Codable, Equatable {
    public var start: Double
    public var full: Double
    public init(start: Double = 40, full: Double = 70) { self.start = start; self.full = full }
    public func validate() throws {
        guard start.isFinite, full.isFinite, start >= 25, full <= 90, full - start >= 5 else {
            throw DeskError.invalid("温控范围须在 25–90°C 内，两个温度至少相差 5°C。")
        }
    }
    public func rpm(temperature: Double, minimum: Double, maximum: Double) -> Double {
        let fraction = min(1, max(0, (temperature - start) / (full - start)))
        return minimum + fraction * (maximum - minimum)
    }
}

public struct FanSetting: Codable, Equatable {
    public var mode: FanMode
    public var rpm: Double
    public var sensor: SensorChoice
    public var curve: FanCurve
    public init(mode: FanMode = .temperature, rpm: Double = 2500,
                sensor: SensorChoice = .cpuAverage, curve: FanCurve = FanCurve()) {
        self.mode = mode; self.rpm = rpm; self.sensor = sensor; self.curve = curve
    }
    public func validate() throws {
        switch mode {
        case .automatic: break
        case .constant:
            guard rpm.isFinite, rpm > 0, rpm <= 20000 else {
                throw DeskError.invalid("固定转速须为有效的 RPM。")
            }
        case .temperature:
            guard !sensor.rawValue.isEmpty else { throw DeskError.invalid("请选择温度传感器。") }
            try curve.validate()
        }
    }
}

public struct Preset: Codable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var fans: [FanSetting]
    public init(id: UUID = UUID(), name: String = "日常温控",
                fans: [FanSetting] = [FanSetting(), FanSetting()]) {
        self.id = id; self.name = name; self.fans = fans
    }
    private enum CodingKeys: String, CodingKey { case id, name, sensor, fans }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        // Version 1 used one shared sensor and a curve per fan.
        if values.contains(.sensor) {
            let sensor = try values.decode(SensorChoice.self, forKey: .sensor)
            fans = try values.decode([FanCurve].self, forKey: .fans).map { FanSetting(sensor: sensor, curve: $0) }
        } else {
            fans = try values.decode([FanSetting].self, forKey: .fans)
        }
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id); try values.encode(name, forKey: .name)
        try values.encode(fans, forKey: .fans)
    }
    public func validate(fanCount: Int = 2) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 50 else {
            throw DeskError.invalid("预设名称须为 1–50 个字符。")
        }
        guard fans.count == fanCount, fanCount == 2 else {
            throw DeskError.invalid("当前版本仅支持已验证的双风扇机型。")
        }
        for fan in fans { try fan.validate() }
    }
}

public struct FanReading: Codable, Identifiable, Equatable {
    public var id: Int
    public var actual: Double
    public var target: Double
    public var minimum: Double
    public var maximum: Double
    public var mode: Int
    public var title: String { id == 0 ? "左侧风扇" : "右侧风扇" }
    public init(id: Int, actual: Double, target: Double, minimum: Double, maximum: Double, mode: Int) {
        self.id = id; self.actual = actual; self.target = target
        self.minimum = minimum; self.maximum = maximum; self.mode = mode
    }
}

public struct TemperatureReading: Codable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var category: String
    public var value: Double?
    public init(id: String, name: String, category: String, value: Double?) {
        self.id = id; self.name = name; self.category = category; self.value = value
    }
}

public struct Snapshot: Codable, Equatable {
    public var average: Double
    public var maximum: Double
    public var sensorCount: Int
    public var cpuExpectedCount: Int
    public var fans: [FanReading]
    public var sensors: [TemperatureReading]
    public init(average: Double, maximum: Double, sensorCount: Int, fans: [FanReading],
                sensors: [TemperatureReading] = [], cpuExpectedCount: Int? = nil) {
        self.average = average; self.maximum = maximum; self.sensorCount = sensorCount; self.fans = fans
        self.sensors = sensors
        self.cpuExpectedCount = cpuExpectedCount ?? sensorCount
    }
    public func temperature(for choice: SensorChoice) throws -> Double {
        let value: Double?
        if choice == .cpuAverage { value = sensorCount > 0 && sensorCount == cpuExpectedCount ? average : nil }
        else if choice == .cpuMaximum { value = sensorCount > 0 && sensorCount == cpuExpectedCount ? maximum : nil }
        else { value = sensors.first(where: { $0.id == choice.rawValue })?.value }
        guard let value, value.isFinite, (1...130).contains(value) else {
            throw DeskError.invalid("所选温度传感器不可用：\(choice.title)。")
        }
        return value
    }
}

public struct HelperRequest: Codable {
    public enum Command: String, Codable { case status, apply, automatic, heartbeat }
    public var command: Command
    public var preset: Preset?
    public init(_ command: Command, preset: Preset? = nil) { self.command = command; self.preset = preset }
}

public struct HelperResponse: Codable {
    public var snapshot: Snapshot?
    public var activePreset: Preset?
    public var error: String?
    public init(snapshot: Snapshot? = nil, activePreset: Preset? = nil, error: String? = nil) {
        self.snapshot = snapshot; self.activePreset = activePreset; self.error = error
    }
}

@objc public protocol FanDeskHelperProtocol {
    func request(_ data: Data, reply: @escaping (Data) -> Void)
}

public enum DeskPaths {
    public static let service = "local.jingwen.FanDesk.helper"
    public static let appID = "local.jingwen.FanDesk"
    public static let daemonPlist = service + ".plist"
    public static var preferences: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/FanDesk/presets.json")
    }
}

public enum MenuIcon: String, Codable, CaseIterable { case monochrome, colored, none }

public struct DeskPreferences: Codable, Equatable {
    public var menuSensor: SensorChoice
    public var menuFan: Int?
    public var menuTwoLines: Bool
    public var menuIcon: MenuIcon
    public var launchAtLogin: Bool
    public var startHidden: Bool
    public var restoreOnLaunch: Bool
    public var restoreAfterWake: Bool
    public init(menuSensor: SensorChoice = .cpuAverage, menuFan: Int? = nil, menuTwoLines: Bool = false,
                menuIcon: MenuIcon = .monochrome, launchAtLogin: Bool = false, startHidden: Bool = true,
                restoreOnLaunch: Bool = true, restoreAfterWake: Bool = true) {
        self.menuSensor = menuSensor; self.menuFan = menuFan; self.menuTwoLines = menuTwoLines
        self.menuIcon = menuIcon; self.launchAtLogin = launchAtLogin; self.startHidden = startHidden
        self.restoreOnLaunch = restoreOnLaunch; self.restoreAfterWake = restoreAfterWake
    }
    private enum CodingKeys: String, CodingKey {
        case menuSensor, menuFan, menuTwoLines, menuIcon, launchAtLogin, startHidden, restoreOnLaunch, restoreAfterWake
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        menuSensor = try values.decodeIfPresent(SensorChoice.self, forKey: .menuSensor) ?? .cpuAverage
        menuFan = try values.decodeIfPresent(Int.self, forKey: .menuFan)
        menuTwoLines = try values.decodeIfPresent(Bool.self, forKey: .menuTwoLines) ?? false
        menuIcon = try values.decodeIfPresent(MenuIcon.self, forKey: .menuIcon) ?? .monochrome
        launchAtLogin = try values.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        startHidden = try values.decodeIfPresent(Bool.self, forKey: .startHidden) ?? true
        restoreOnLaunch = try values.decodeIfPresent(Bool.self, forKey: .restoreOnLaunch) ?? true
        restoreAfterWake = try values.decodeIfPresent(Bool.self, forKey: .restoreAfterWake) ?? true
    }
    public func validate() throws {
        guard !menuSensor.rawValue.isEmpty, menuFan.map({ (0..<2).contains($0) }) ?? true else {
            throw DeskError.invalid("菜单栏显示设置无效。")
        }
    }
}

public struct SavedState: Codable {
    public private(set) var version = 2
    public var presets: [Preset]
    public var selected: UUID?
    public var preferences: DeskPreferences
    public var lastApplied: Preset?
    public init(presets: [Preset] = [Preset()], selected: UUID? = nil,
                preferences: DeskPreferences = DeskPreferences(), lastApplied: Preset? = nil) {
        self.presets = presets; self.selected = selected
        self.preferences = preferences; self.lastApplied = lastApplied
    }
    private enum CodingKeys: String, CodingKey { case version, presets, selected, preferences, lastApplied }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let sourceVersion = try values.decode(Int.self, forKey: .version)
        guard (1...2).contains(sourceVersion) else { throw DeskError.invalid("预设文件版本不受支持，原文件已保留。") }
        presets = try values.decode([Preset].self, forKey: .presets)
        selected = try values.decodeIfPresent(UUID.self, forKey: .selected)
        preferences = try values.decodeIfPresent(DeskPreferences.self, forKey: .preferences) ?? DeskPreferences()
        lastApplied = try values.decodeIfPresent(Preset.self, forKey: .lastApplied)
    }
    private func validate() throws {
        guard Set(presets.map(\.id)).count == presets.count else {
            throw DeskError.invalid("预设文件包含重复项目，原文件已保留。")
        }
        for preset in presets { try preset.validate() }
        try lastApplied?.validate(); try preferences.validate()
    }
    public static func load(from url: URL) throws -> SavedState {
        guard FileManager.default.fileExists(atPath: url.path) else { return SavedState() }
        let state = try JSONDecoder().decode(SavedState.self, from: Data(contentsOf: url))
        try state.validate()
        return state
    }
    public func save(to url: URL) throws {
        try validate()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
