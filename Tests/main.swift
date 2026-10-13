import Foundation
import FanCore

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ label: String) {
    checks += 1
    guard condition() else { fputs("FAIL: \(label)\n", stderr); exit(1) }
}
func rejects(_ label: String, _ action: () throws -> Void) {
    do { try action(); check(false, label) } catch { checks += 1 }
}
final class FakeHardware: FanHardware {
    var reading = Snapshot(average: 55, maximum: 60, sensorCount: 2, fans: [
        FanReading(id: 0, actual: 1350, target: 1350, minimum: 1350, maximum: 5350, mode: 0),
        FanReading(id: 1, actual: 1350, target: 1350, minimum: 1350, maximum: 5750, mode: 0)], sensors: [
        TemperatureReading(id: "cpuA", name: "CPU 核心", category: "CPU", value: 45),
        TemperatureReading(id: "gpuA", name: "GPU", category: "GPU", value: 60),
        TemperatureReading(id: "batteryA", name: "电池", category: "电池", value: nil)])
    var targets: [Double?] = []
    var autoCalls = 0, driveCalls = 0
    var failRead = false, failWrite = false, failReset = false
    func snapshot() throws -> Snapshot {
        if failRead { throw DeskError.invalid("sensor unavailable") }; return reading
    }
    func drive(_ values: [Double?]) throws {
        driveCalls += 1
        targets = values
        if failWrite { throw DeskError.invalid("partial write failure") }
    }
    func restoreAutomatic() throws {
        autoCalls += 1
        if failReset { throw DeskError.invalid("reset unavailable") }
        targets = []
    }
}

do {
    var consoleUID: uid_t? = 502
    let session = ControlSession(currentUser: { consoleUID })
    let client = NSObject()
    let clientID = ObjectIdentifier(client)
    check(session.allows(502), "distribution supports a console user other than the builder")
    check(!session.allows(501), "inactive users cannot control fans")
    session.claim(clientID, uid: 502)
    let sessionHardware = FakeHardware()
    let sessionEngine = ControlEngine(hardware: sessionHardware, thermalEmergency: { false })
    try sessionEngine.apply(Preset(), now: 1)
    session.releaseInactiveOwner { sessionEngine.automatic() }
    check(sessionEngine.active != nil && session.owner == clientID, "current console user retains control")
    consoleUID = 503
    session.releaseInactiveOwner { sessionEngine.automatic() }
    check(sessionEngine.active == nil && session.owner == nil && sessionHardware.autoCalls == 1, "fast user switching restores automatic and releases ownership")
    check(!session.allows(502) && session.allows(503), "old connections lose access after a user switch")
    session.claim(clientID, uid: 503)
    try sessionEngine.apply(Preset(), now: 2)
    consoleUID = nil
    session.releaseInactiveOwner { sessionEngine.automatic() }
    check(sessionEngine.active == nil && session.owner == nil && !session.allows(503), "logout or missing console state restores automatic and denies access")
    consoleUID = 0
    check(!session.allows(0), "loginwindow and root are not interactive controllers")
    consoleUID = uid_t.max
    check(!session.allows(uid_t.max), "invalid console UID is rejected")
    consoleUID = 500
    check(session.allows(500), "a valid directory account is not tied to local UID allocation")
    session.releaseInactiveOwner { sessionEngine.automatic() }
    check(sessionHardware.autoCalls == 2, "an unowned session does not repeatedly reset the hardware")
    let curve = FanCurve()
    check(curve.rpm(temperature: 20, minimum: 1350, maximum: 5350) == 1350, "below threshold clamps to minimum")
    check(curve.rpm(temperature: 55, minimum: 1350, maximum: 5350) == 3350, "linear midpoint")
    check(curve.rpm(temperature: 100, minimum: 1350, maximum: 5350) == 5350, "above threshold clamps to maximum")
    for invalid in [FanCurve(start: .nan), FanCurve(full: .infinity), FanCurve(start: 24), FanCurve(full: 91), FanCurve(start: 68, full: 70)] {
        rejects("invalid temperature rejected") { try invalid.validate() }
    }
    rejects("one fan rejected") { try Preset(fans: [FanSetting()]).validate() }
    rejects("blank name rejected") { try Preset(name: "  ").validate() }
    for speed in [Double.nan, .infinity, 0, -1, 20001] {
        rejects("invalid constant speed rejected") { try FanSetting(mode: .constant, rpm: speed).validate() }
    }
    let sensor = SensorChoice(rawValue: "cpuA")
    let sensorData = try JSONEncoder().encode(sensor)
    check(String(data: sensorData, encoding: .utf8) == "\"cpuA\"", "sensor keys use single string encoding")
    let decodedSensor = try JSONDecoder().decode(SensorChoice.self, from: Data("\"cpuMaximum\"".utf8))
    check(decodedSensor == .cpuMaximum, "legacy CPU choice decodes unchanged")
    let hardware = FakeHardware(), preset = Preset()
    var thermalEmergency = false
    let engine = ControlEngine(hardware: hardware, thermalEmergency: { thermalEmergency })
    try engine.apply(preset, now: 10)
    check(hardware.targets == [3350, 3550], "independent hardware maxima")
    engine.heartbeat(now: 14)
    _ = engine.tick(now: 18)
    check(engine.active != nil, "heartbeat renews ownership")
    _ = engine.tick(now: 20)
    check(engine.active == nil && hardware.autoCalls == 1, "lost app restores automatic")
    try engine.apply(preset, now: 30)
    thermalEmergency = true
    _ = engine.tick(now: 31)
    check(hardware.targets == [5350, 5750], "OS thermal emergency uses maximum")
    engine.heartbeat(now: 31.5)
    _ = engine.tick(now: 31.5)
    check(hardware.targets == [5350, 5750], "heartbeat cannot override OS thermal emergency")
    try engine.apply(preset, now: 31.7)
    check(hardware.targets == [5350, 5750], "apply cannot override OS thermal emergency")
    thermalEmergency = false
    hardware.reading.maximum = 95
    _ = engine.tick(now: 32)
    check(hardware.targets == [5350, 5750], "hotspot emergency uses maximum")
    hardware.failRead = true
    _ = engine.tick(now: 33)
    check(engine.active == nil && hardware.autoCalls == 2, "sensor loss restores automatic")
    let failureText = engine.failure
    for step in 1...5 { _ = engine.tick(now: 33 + Double(step) / 10) }
    check(engine.failure == failureText, "repeated sensor failure does not accumulate messages")
    hardware.failRead = false; hardware.failWrite = true; hardware.failReset = true
    rejects("partial failure rejects apply") { try engine.apply(preset, now: 40) }
    check(engine.active == nil && engine.failure != nil, "failed write deactivates preset")
    let count = hardware.autoCalls
    _ = engine.tick(now: 41)
    check(hardware.autoCalls > count, "failed restoration retries")
    hardware.failWrite = false; hardware.failReset = false
    try engine.apply(preset, now: 42)
    check(engine.failure == nil && engine.active != nil && !hardware.targets.isEmpty, "apply after pending recovery actually activates preset")
    try engine.apply(preset, now: 50)
    engine.automatic()
    check(engine.active == nil && hardware.targets.isEmpty, "explicit automatic restores both fans")

    hardware.reading.maximum = 60
    let independent = Preset(name: "独立传感器", fans: [
        FanSetting(sensor: sensor, curve: FanCurve(start: 40, full: 60)),
        FanSetting(sensor: SensorChoice(rawValue: "gpuA"), curve: FanCurve(start: 40, full: 80))])
    try engine.apply(independent, now: 60)
    check(hardware.targets == [2350, 3550], "each fan uses its own temperature and curve")
    check(engine.active == independent, "independent preset remains active with an unrelated unavailable sensor")
    let average = try hardware.reading.temperature(for: .cpuAverage)
    let maximum = try hardware.reading.temperature(for: .cpuMaximum)
    check(average == 55 && maximum == 60, "CPU aggregate choices select the intended statistic")
    rejects("missing selected sensor rejected") { _ = try hardware.reading.temperature(for: SensorChoice(rawValue: "missing")) }
    rejects("unavailable selected sensor rejected") { _ = try hardware.reading.temperature(for: SensorChoice(rawValue: "batteryA")) }
    hardware.reading.sensors[0].value = nil
    _ = engine.tick(now: 61)
    check(engine.active == nil && hardware.targets.isEmpty, "loss of selected sensor restores all fans")
    hardware.reading.sensors[0].value = .nan
    rejects("nonfinite selected sensor rejected") { _ = try hardware.reading.temperature(for: sensor) }
    hardware.reading.sensors[0].value = 131
    rejects("out of range selected sensor rejected") { _ = try hardware.reading.temperature(for: sensor) }
    hardware.reading.sensors[0].value = 45

    let mixed = Preset(name: "独立模式", fans: [FanSetting(mode: .automatic), FanSetting(mode: .constant, rpm: 3200)])
    try engine.apply(mixed, now: 70)
    check(hardware.targets == [nil, 3200], "automatic and constant speed modes coexist")
    thermalEmergency = true
    _ = engine.tick(now: 71)
    check(hardware.targets == [nil, 5750], "thermal protection only increases manually controlled fans")
    thermalEmergency = false
    hardware.reading.maximum = 95
    _ = engine.tick(now: 72)
    check(hardware.targets == [nil, 5750], "CPU hotspot protection preserves the automatic fan")
    hardware.reading.maximum = 60
    let boundaries = Preset(name: "转速边界", fans: [FanSetting(mode: .constant, rpm: 1350), FanSetting(mode: .constant, rpm: 5750)])
    try engine.apply(boundaries, now: 73)
    check(hardware.targets == [1350, 5750], "exact hardware speed bounds accepted")
    let writes = hardware.driveCalls
    rejects("below hardware minimum rejected") {
        try engine.apply(Preset(fans: [FanSetting(mode: .constant, rpm: 1349), FanSetting(mode: .automatic)]), now: 74)
    }
    check(hardware.driveCalls == writes && engine.active == nil, "invalid fixed speed is not clamped or written")
    rejects("above hardware maximum rejected") {
        try engine.apply(Preset(fans: [FanSetting(mode: .automatic), FanSetting(mode: .constant, rpm: 5751)]), now: 75)
    }
    check(hardware.driveCalls == writes, "second fan validated before writing the first")
    let allAutomatic = Preset(name: "自动", fans: [FanSetting(mode: .automatic), FanSetting(mode: .automatic)])
    try engine.apply(mixed, now: 76)
    let response = try engine.apply(allAutomatic, now: 77)
    check(engine.active == nil && response.activePreset == nil && hardware.targets.isEmpty, "all automatic preset releases ownership")
    hardware.reading.sensorCount = 0
    rejects("empty CPU aggregation rejected") { _ = try hardware.reading.temperature(for: .cpuAverage) }
    try engine.apply(mixed, now: 78)
    check(hardware.targets == [nil, 3200], "constant speed works without a CPU aggregate")
    engine.automatic()
    hardware.reading.sensorCount = 2
    hardware.reading.fans[0].minimum = .nan
    rejects("invalid fan bounds fail without trapping") { try engine.apply(preset, now: 79) }
    hardware.reading.fans[0].minimum = 1350

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FanDesk-tests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("presets.json")
    let second = Preset(name: "工作", fans: [FanSetting(sensor: .cpuMaximum, curve: FanCurve(start: 45, full: 75)), FanSetting(mode: .constant, rpm: 3000)])
    let preferences = DeskPreferences(menuSensor: SensorChoice(rawValue: "gpuA"), menuFan: 1, menuTwoLines: true,
                                      menuIcon: .colored, launchAtLogin: true, startHidden: false,
                                      restoreOnLaunch: false, restoreAfterWake: false)
    let state = SavedState(presets: [preset, second], selected: second.id, preferences: preferences, lastApplied: mixed)
    try state.save(to: file)
    let restored = try SavedState.load(from: file)
    check(restored.presets == state.presets && restored.selected == second.id, "named presets survive disk round trip")
    check(restored.version == 2 && restored.preferences == preferences && restored.lastApplied == mixed, "preferences and last applied preset survive disk round trip")
    let original = try Data(contentsOf: file)
    rejects("duplicate preset IDs rejected on save") { try SavedState(presets: [preset, preset]).save(to: file) }
    let unchanged = try Data(contentsOf: file)
    check(original == unchanged, "rejected save preserves existing file")
    let legacy = """
    {"version":1,"selected":"\(second.id.uuidString)","presets":[
      {"id":"\(second.id.uuidString)","name":"旧版工作","sensor":"cpuMaximum","fans":[
        {"start":45,"full":75},{"start":50,"full":80}
      ]}
    ]}
    """
    try Data(legacy.utf8).write(to: file)
    let migrated = try SavedState.load(from: file)
    check(migrated.version == 2 && migrated.selected == second.id, "version 1 state migrates in memory and preserves selection")
    check(migrated.presets[0].id == second.id && migrated.presets[0].name == "旧版工作", "migration preserves preset identity and name")
    check(migrated.presets[0].fans == [FanSetting(sensor: .cpuMaximum, curve: FanCurve(start: 45, full: 75)),
                                     FanSetting(sensor: .cpuMaximum, curve: FanCurve(start: 50, full: 80))], "legacy shared sensor moves to both temperature fan settings")
    check(migrated.preferences == DeskPreferences() && migrated.lastApplied == nil, "migration supplies new preference defaults")
    let legacyUnchanged = try String(contentsOf: file, encoding: .utf8)
    check(legacyUnchanged == legacy, "loading legacy state does not mutate the source file")
    try migrated.save(to: file)
    let upgraded = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
    let upgradedPreset = (upgraded["presets"] as! [[String: Any]])[0]
    check(upgraded["version"] as? Int == 2 && upgradedPreset["sensor"] == nil, "saving migrated state writes version 2 per fan schema")
    rejects("unsupported version rejected") {
        _ = try JSONDecoder().decode(SavedState.self, from: Data("{\"version\":3,\"presets\":[]}".utf8))
    }
    rejects("invalid menu fan rejected") { try SavedState(preferences: DeskPreferences(menuFan: 2)).save(to: file) }
    let partialPreferences = try JSONDecoder().decode(DeskPreferences.self, from: Data("{}".utf8))
    check(partialPreferences == DeskPreferences(), "omitted preference keys use defaults")
    try Data("invalid json".utf8).write(to: file)
    rejects("corrupt state rejected") { _ = try SavedState.load(from: file) }
    let corrupt = try String(contentsOf: file, encoding: .utf8)
    check(corrupt == "invalid json", "corrupt input is preserved")
    let incompleteCPU = Snapshot(average: 50, maximum: 55, sensorCount: 17, fans: hardware.reading.fans, cpuExpectedCount: 18)
    rejects("incomplete CPU average cannot control fans") { _ = try incompleteCPU.temperature(for: .cpuAverage) }
    rejects("incomplete CPU maximum cannot control fans") { _ = try incompleteCPU.temperature(for: .cpuMaximum) }
    print("PASS: \(checks) checks")
} catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
