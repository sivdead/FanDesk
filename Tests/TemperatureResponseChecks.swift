import Foundation
import FanCore

func runTemperatureResponseChecks() throws {
    let setting = FanSetting(curve: FanCurve(start: 40, full: 75))
    let preset = Preset(fans: [setting, setting])

    // Brief CPU bursts should not immediately turn into the raw curve's RPM.
    let pulseHardware = FakeHardware()
    pulseHardware.reading.average = 45
    for index in 0..<2 {
        pulseHardware.reading.fans[index].actual = setting.curve.rpm(temperature: 45,
            minimum: pulseHardware.reading.fans[index].minimum, maximum: pulseHardware.reading.fans[index].maximum)
    }
    let pulse = ControlEngine(hardware: pulseHardware, thermalEmergency: { false })
    try pulse.apply(preset, now: 0)
    let initial = pulseHardware.targets[0]!
    pulseHardware.reading.average = 60
    pulse.heartbeat(now: 1)
    _ = pulse.tick(now: 1)
    let burst = pulseHardware.targets[0]!
    check(burst > initial && burst <= initial + 300, "a CPU burst raises speed within the normal upward limit")
    check(burst < setting.curve.rpm(temperature: 60, minimum: 1350, maximum: 5350) - 1000,
          "a short CPU burst does not jump to its unsmoothed target")
    pulseHardware.reading.average = 45
    for time in 2...10 {
        pulse.heartbeat(now: Double(time))
        _ = pulse.tick(now: Double(time))
    }
    check(pulseHardware.targets[0]! < initial + 100, "an ended one-second burst settles back without chasing its peak")
    pulseHardware.reading.average = 60
    for time in 11...40 {
        pulse.heartbeat(now: Double(time))
        _ = pulse.tick(now: Double(time))
    }
    let sustained = setting.curve.rpm(temperature: 60, minimum: 1350, maximum: 5350)
    check(abs(pulseHardware.targets[0]! - sustained) < 5, "sustained heat still reaches the requested curve")

    // A steady falling demand must have the same limit at any request frequency.
    func coolingHardware() -> FakeHardware {
        let hardware = FakeHardware()
        hardware.reading.average = 45
        for index in 0..<2 {
            hardware.reading.fans[index].mode = 1
            hardware.reading.fans[index].actual = 3900
            hardware.reading.fans[index].target = 4000
        }
        return hardware
    }
    let slowHardware = coolingHardware(), frequentHardware = coolingHardware()
    let slow = ControlEngine(hardware: slowHardware, thermalEmergency: { false })
    let frequent = ControlEngine(hardware: frequentHardware, thermalEmergency: { false })
    try slow.apply(preset, now: 0)
    try frequent.apply(preset, now: 0)
    check(slowHardware.targets == [4000, 4000], "taking over manual control does not suddenly lower its target")
    slow.heartbeat(now: 1)
    _ = slow.tick(now: 1)
    for step in 1...20 {
        let time = Double(step) / 20
        frequent.heartbeat(now: time)
        _ = frequent.tick(now: time)
        try frequent.apply(preset, now: time)
    }
    check(abs(slowHardware.targets[0]! - 3925) < 0.01, "normal cooling is limited to 75 RPM per second")
    check(abs(frequentHardware.targets[0]! - slowHardware.targets[0]!) < 0.01,
          "dense heartbeats and repeated apply cannot accelerate cooling")
    let beforeDuplicate = frequentHardware.targets
    for _ in 0..<10 { _ = frequent.tick(now: 1) }
    check(frequentHardware.targets == beforeDuplicate, "same-time status requests do not gain an RPM step")
    _ = frequent.tick(now: 0.5)
    check(frequentHardware.targets == beforeDuplicate, "a backwards timestamp cannot move the response")

    var changed = preset
    changed.fans[0].sensor = SensorChoice(rawValue: "cpuA")
    changed.fans[0].curve = FanCurve(start: 40, full: 80)
    changed.fans[1].mode = .constant
    changed.fans[1].rpm = 3200
    try frequent.apply(changed, now: 1)
    check(frequentHardware.targets == [beforeDuplicate[0], 3200],
          "changing a sensor and curve preserves the output anchor while fixed mode remains immediate")
    frequent.heartbeat(now: 2)
    _ = frequent.tick(now: 2)
    check(abs(frequentHardware.targets[0]! - (beforeDuplicate[0]! - 75)) < 0.01,
          "a changed curve still lowers speed gradually")
    frequentHardware.reading.fans[1].mode = 1
    frequentHardware.reading.fans[1].actual = 3200
    frequentHardware.reading.fans[1].target = 3200
    changed.fans[1].mode = .temperature
    try frequent.apply(changed, now: 2)
    check(frequentHardware.targets[1] == 3200, "returning from fixed speed starts at the current output instead of old temperature history")
    _ = frequent.tick(now: 2.5)
    check(abs(frequentHardware.targets[1]! - 3162.5) < 0.01, "returning from fixed speed preserves gradual cooling")

    // CPU hotspot and OS protection must bypass both smoothing and rate limits.
    let protectedHardware = coolingHardware()
    var emergency = false
    let protected = ControlEngine(hardware: protectedHardware, thermalEmergency: { emergency })
    try protected.apply(preset, now: 0)
    protectedHardware.reading.maximum = 90
    _ = protected.tick(now: 0.001)
    check(protectedHardware.targets == [5350, 5750], "a raw 90-degree CPU hotspot immediately reaches maximum")
    protectedHardware.reading.maximum = 60
    _ = protected.tick(now: 0.101)
    check(protectedHardware.targets[0]! >= 5350 - 7.501 && protectedHardware.targets[1]! >= 5750 - 7.501,
          "leaving hotspot protection ramps down from maximum instead of restoring an old low target")
    emergency = true
    _ = protected.tick(now: 0.102)
    check(protectedHardware.targets == [5350, 5750], "OS thermal protection immediately overrides the smoothed response")
    emergency = false
    try protected.apply(preset, now: 0.102)
    check(protectedHardware.targets == [5350, 5750], "reapplying a preset cannot skip gradual recovery after protection")

    protectedHardware.reading.average = 75
    _ = protected.tick(now: 0.103)
    check(protectedHardware.targets == [5350, 5750], "the raw curve full-speed threshold remains immediate")
    protectedHardware.reading.average = 45
    protectedHardware.reading.sensorCount = 1
    _ = protected.tick(now: 0.104)
    check(protected.active == nil && protectedHardware.targets.isEmpty,
          "a cached filtered temperature cannot hide loss of the selected sensor")

    // Releasing control clears the old high output; automatic SMC targets can be stale.
    protectedHardware.reading.sensorCount = 2
    for index in 0..<2 {
        protectedHardware.reading.fans[index].mode = 0
        protectedHardware.reading.fans[index].actual = 1700
        protectedHardware.reading.fans[index].target = 5300
    }
    try protected.apply(preset, now: 10)
    check(protectedHardware.targets == [1700, 1700], "fresh automatic takeover ignores a stale manual SMC target and old filter state")
    _ = protected.tick(now: 16)
    check(protected.active == nil && protectedHardware.targets.isEmpty, "smoothing never delays the lost-heartbeat release")

    // State is independent for each fan, including mixed automatic operation.
    let independentHardware = coolingHardware()
    independentHardware.reading.sensors[1].value = 70
    let independent = ControlEngine(hardware: independentHardware, thermalEmergency: { false })
    var independentPreset = preset
    independentPreset.fans[1].sensor = SensorChoice(rawValue: "gpuA")
    try independent.apply(independentPreset, now: 0)
    independent.heartbeat(now: 1)
    _ = independent.tick(now: 1)
    check(independentHardware.targets[0]! < 4000 && independentHardware.targets[1]! > 4000,
          "separate sensor histories can lower one fan while raising the other")
    let leftBefore = independentHardware.targets[0]!
    independentPreset.fans[1].mode = .automatic
    try independent.apply(independentPreset, now: 1)
    check(independentHardware.targets == [leftBefore, nil], "switching one fan to automatic does not reset the other fan")
    independentHardware.reading.maximum = 95
    _ = independent.tick(now: 1.001)
    check(independentHardware.targets == [5350, nil], "high-temperature protection leaves an automatic fan under system control")
    independentHardware.reading.maximum = 60
    independentHardware.reading.fans[1].mode = 0
    independentHardware.reading.fans[1].actual = 1800
    independentHardware.reading.fans[1].target = 5500
    independentPreset.fans[1].mode = .temperature
    try independent.apply(independentPreset, now: 1.002)
    check(independentHardware.targets[1] == 1800, "returning one automatic fan to temperature control starts from its actual speed")
}
