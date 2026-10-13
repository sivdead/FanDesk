import Foundation

public protocol FanHardware {
    func snapshot() throws -> Snapshot
    func drive(_ targets: [Double?]) throws
    func restoreAutomatic() throws
}

public final class Hardware: FanHardware {
    private let smc: SMC
    private let temperatureSpecs: [SensorSpec]
    private let modeKeys: [String]
    private let hid = HIDSensors()
    private let nvme = NVMESensors()
    public init() throws {
        let smc = try SMC()
        self.smc = smc
        guard try smc.readUInt8("FNum") == 2 else { throw DeskError.invalid("未检测到两个风扇。") }
        modeKeys = try (0..<2).map { i in
            guard let key = ["F\(i)md", "F\(i)Md"].first(where: { smc.keyExists($0) }) else {
                throw DeskError.invalid("无法识别风扇 \(i + 1) 的控制接口。")
            }
            return key
        }
        temperatureSpecs = try SensorCatalog.discover(smc: smc)
    }
    public func snapshot() throws -> Snapshot {
        var sensors = temperatureSpecs.map { spec -> TemperatureReading in
            let value = try? smc.readNumber(spec.key)
            let valid = value.flatMap { $0.isFinite && (1...130).contains($0) ? $0 : nil }
            return TemperatureReading(id: spec.key, name: spec.name, category: spec.category, value: valid)
        }
        let temperatures = zip(temperatureSpecs, sensors).compactMap { spec, reading in spec.isCPU ? reading.value : nil }
        let gpuKeys = ["Tg08", "Tg12", "Tg1x", "Tg29"]
        let gpu = gpuKeys.compactMap { key in sensors.first(where: { $0.id == key && $0.category == "GPU" })?.value }
        if gpu.count == gpuKeys.count {
            sensors.append(TemperatureReading(id: "gpuAverage", name: "GPU 集群平均", category: "GPU", value: gpu.reduce(0, +) / Double(gpu.count)))
        }
        sensors.append(contentsOf: hid.readings())
        sensors.append(contentsOf: nvme.snapshot())
        let fans = try (0..<2).map { i -> FanReading in
            let lo = try smc.readNumber("F\(i)Mn"), hi = try smc.readNumber("F\(i)Mx")
            let actual = try smc.readNumber("F\(i)Ac"), target = try smc.readNumber("F\(i)Tg")
            guard lo.isFinite, hi.isFinite, lo > 0, hi > lo, hi <= 20000,
                  actual.isFinite, actual >= 0, actual <= 22000, target.isFinite else {
                throw DeskError.invalid("风扇范围或转速读数无效。")
            }
            return FanReading(id: i, actual: actual, target: target, minimum: lo, maximum: hi,
                              mode: Int(try smc.readUInt8(modeKeys[i])))
        }
        let expectedCPU = temperatureSpecs.filter(\.isCPU).count
        return Snapshot(average: temperatures.isEmpty ? 0 : temperatures.reduce(0, +) / Double(temperatures.count),
                        maximum: temperatures.max() ?? 0, sensorCount: temperatures.count, fans: fans,
                        sensors: sensors, cpuExpectedCount: expectedCPU)
    }
    public func drive(_ targets: [Double?]) throws {
        guard getuid() == 0, targets.count == 2 else { throw DeskError.invalid("风扇写入需要已授权的后台服务。") }
        // Validate every requested speed before changing any fan.
        for i in 0..<2 {
            guard let target = targets[i] else { continue }
            let lo = try smc.readNumber("F\(i)Mn"), hi = try smc.readNumber("F\(i)Mx")
            guard lo.isFinite, hi.isFinite, lo > 0, hi > lo, hi <= 20000 else {
                throw DeskError.invalid("风扇范围读数无效。")
            }
            guard target.isFinite, (lo...hi).contains(target) else {
                throw DeskError.invalid("风扇 \(i + 1) 的固定转速须在 \(Int(lo))–\(Int(hi)) RPM 内。")
            }
        }
        for i in 0..<2 {
            guard let target = targets[i] else {
                try smc.writeUInt8(modeKeys[i], 0)
                continue
            }
            try smc.writeUInt8(modeKeys[i], 1)
            try smc.writeNumber("F\(i)Tg", target)
        }
    }
    public func restoreAutomatic() throws {
        var failures: [String] = []
        for key in modeKeys {
            do { try smc.writeUInt8(key, 0) } catch { failures.append(String(describing: error)) }
        }
        if !failures.isEmpty { throw DeskError.invalid("恢复系统控制失败：" + failures.joined(separator: "；")) }
    }
}

// All access is serialized by the helper's single work queue.
public final class ControlEngine {
    private let hardware: FanHardware
    private let thermalEmergency: () -> Bool
    public private(set) var active: Preset?
    public private(set) var failure: String?
    private var lastHeartbeat = 0.0
    private var recoveryPending = false
    private var responses = [TemperatureResponse(), TemperatureResponse()]
    public init(hardware: FanHardware, thermalEmergency: @escaping () -> Bool = {
        [.serious, .critical].contains(ProcessInfo.processInfo.thermalState)
    }) { self.hardware = hardware; self.thermalEmergency = thermalEmergency }
    public func heartbeat(now: Double) { lastHeartbeat = now }
    @discardableResult public func apply(_ preset: Preset, now: Double) throws -> HelperResponse {
        try preset.validate()
        if recoveryPending {
            automatic()
            if recoveryPending { throw DeskError.invalid(failure ?? "尚未恢复系统自动控制。") }
        }
        if preset.fans.allSatisfy({ $0.mode == .automatic }) {
            automatic()
            if recoveryPending { throw DeskError.invalid(failure ?? "尚未恢复系统自动控制。") }
            let result = tick(now: now)
            if let failure { throw DeskError.invalid(failure) }
            return result
        }
        active = preset; failure = nil; lastHeartbeat = now
        let result = tick(now: now)
        if let failure { throw DeskError.invalid(failure) }
        return result
    }
    public func automatic() {
        active = nil
        responses = [TemperatureResponse(), TemperatureResponse()]
        do { try hardware.restoreAutomatic(); recoveryPending = false; failure = nil }
        catch { recoveryPending = true; failure = error.localizedDescription }
    }
    public func tick(now: Double) -> HelperResponse {
        if recoveryPending { automatic() }
        if active != nil && now - lastHeartbeat > 5 { automatic() }
        do {
            let reading = try hardware.snapshot()
            if let preset = active {
                try preset.validate(fanCount: reading.fans.count)
                let emergency = thermalEmergency() || (reading.sensorCount > 0 && reading.maximum >= 90)
                let targets = try zip(preset.fans, reading.fans).enumerated().map { index, pair -> Double? in
                    let (setting, fan) = pair
                    guard fan.minimum.isFinite, fan.maximum.isFinite, fan.minimum > 0,
                          fan.maximum > fan.minimum, fan.maximum <= 20000 else {
                        throw DeskError.invalid("风扇范围读数无效。")
                    }
                    switch setting.mode {
                    case .automatic:
                        responses[index] = TemperatureResponse()
                        return nil
                    case .constant:
                        guard (fan.minimum...fan.maximum).contains(setting.rpm) else {
                            throw DeskError.invalid("\(fan.title)的固定转速须在 \(Int(fan.minimum))–\(Int(fan.maximum)) RPM 内。")
                        }
                        responses[index] = TemperatureResponse()
                        return emergency ? fan.maximum : setting.rpm
                    case .temperature:
                        let temperature = try reading.temperature(for: setting.sensor)
                        return responses[index].target(temperature: temperature, setting: setting, fan: fan,
                                                       emergency: emergency, now: now)
                    }
                }
                try hardware.drive(targets)
            }
            return HelperResponse(snapshot: reading, activePreset: active, error: failure)
        } catch {
            let reason = error.localizedDescription
            if active != nil || recoveryPending { automatic() }
            let resetFailure = recoveryPending ? failure : nil
            failure = [reason, resetFailure].compactMap { $0 }.joined(separator: "；")
            return HelperResponse(error: failure)
        }
    }
}
