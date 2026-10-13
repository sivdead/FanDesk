import Foundation

/// One fan's temperature response. Elapsed time, rather than the number of
/// status/heartbeat requests, determines filtering and available RPM movement.
struct TemperatureResponse {
    private var filteredTemperature: Double?
    private var output: Double?
    private var updatedAt: Double?
    private var sensor: SensorChoice?
    private var curve: FanCurve?

    mutating func target(temperature: Double, setting: FanSetting, fan: FanReading,
                         emergency: Bool, now: Double) -> Double {
        if sensor != setting.sensor || curve != setting.curve {
            // A different input must not inherit the old sensor's temperature,
            // but keep the output/time anchor so applying a curve cannot jump down.
            filteredTemperature = temperature
            sensor = setting.sensor
            curve = setting.curve
        }
        let elapsed = updatedAt.map { max(0, now - $0) } ?? 0
        updatedAt = max(updatedAt ?? now, now)

        if emergency || temperature >= setting.curve.full {
            // Protection uses the raw reading and also becomes the new output
            // anchor, so leaving protection still lowers the speed gradually.
            filteredTemperature = temperature
            output = fan.maximum
            return fan.maximum
        }

        let previousTemperature = filteredTemperature ?? temperature
        let filtered = previousTemperature + (temperature - previousTemperature) * -expm1(-elapsed / 4)
        filteredTemperature = filtered
        let desired = setting.curve.rpm(temperature: filtered, minimum: fan.minimum, maximum: fan.maximum)

        // In automatic mode the SMC target can be left over from an old manual
        // session; only the actual speed is a reliable starting point there.
        let manualTarget = fan.mode == 1 && (fan.minimum...fan.maximum).contains(fan.target) ? fan.target : fan.actual
        let previous = min(fan.maximum, max(fan.minimum, output ?? max(fan.actual, manualTarget)))
        let rate = desired >= previous ? 300.0 : 75.0
        let movement = min(abs(desired - previous), rate * elapsed)
        let next = previous + (desired >= previous ? movement : -movement)
        output = next
        return next
    }
}
