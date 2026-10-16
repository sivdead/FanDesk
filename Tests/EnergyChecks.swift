import Foundation
import FanCore

func runEnergyChecks() throws {
    let hardware = FakeHardware()
    var emergency = false
    let engine = ControlEngine(hardware: hardware, thermalEmergency: { emergency })
    let preset = Preset()
    try engine.apply(preset, now: 0)
    for time in [0.5, 1, 1.9] {
        engine.heartbeat(now: time)
        _ = engine.status(now: time)
    }
    check(hardware.readCalls == 1 && hardware.driveCalls == 1,
          "heartbeats and intervening watchdog checks do not repeat hardware sampling or writes")
    _ = engine.tick(now: 2)
    check(hardware.readCalls == 2 && hardware.driveCalls == 2,
          "the scheduled control pass samples again after two seconds")
    let cached = engine.status(now: 2.1)
    check(cached.snapshot == hardware.reading && cached.activePreset == preset,
          "cached status still returns the sensor inventory and active preset")

    emergency = true
    _ = engine.status(now: 3)
    check(hardware.targets == [5350, 5750] && hardware.readCalls == 3,
          "OS thermal protection bypasses the two-second sampling interval")
    emergency = false
    hardware.reading.maximum = 90
    engine.heartbeat(now: 5)
    _ = engine.tick(now: 5)
    check(hardware.targets == [5350, 5750], "raw CPU hotspot protection remains effective at the next sample")
    hardware.reading.maximum = 60
    hardware.reading.sensorCount = 1
    engine.heartbeat(now: 7)
    let failed = engine.tick(now: 7)
    check(engine.active == nil && hardware.targets.isEmpty && failed.error != nil,
          "loss of a selected CPU sensor still releases manual control")
    check(engine.status(now: 7.1).snapshot == nil,
          "a failed sample cannot return a previously healthy cached reading")

    let leaseHardware = FakeHardware()
    let lease = ControlEngine(hardware: leaseHardware, thermalEmergency: { false })
    try lease.apply(preset, now: 0)
    _ = lease.tick(now: 4.5)
    _ = lease.status(now: 5.01)
    check(lease.active == nil && leaseHardware.targets.isEmpty,
          "the five-second lease expires even while the last sample is still fresh")
    check(lease.status(now: 5.1).snapshot?.fans.allSatisfy { $0.mode == 0 } == true,
          "lease expiry refreshes automatic-mode telemetry instead of returning stale manual status")

    let recoveryHardware = FakeHardware()
    let recovery = ControlEngine(hardware: recoveryHardware, thermalEmergency: { false })
    try recovery.apply(preset, now: 0)
    recoveryHardware.failReset = true
    _ = recovery.status(now: 5.1)
    let resets = recoveryHardware.autoCalls
    _ = recovery.status(now: 5.2)
    check(recoveryHardware.autoCalls > resets,
          "pending automatic recovery retries even inside the cached-sample interval")
    recoveryHardware.failReset = false
    _ = recovery.status(now: 6)
    check(recovery.active == nil && recovery.failure == nil && recoveryHardware.targets.isEmpty,
          "successful recovery clears the error and leaves the system in control")
}
