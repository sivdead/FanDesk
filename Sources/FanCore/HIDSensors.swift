import Foundation
import IOKit.hidsystem

// These temperature-event entry points are exported by IOKit but omitted from
// the public SDK. The argument layout and temperature field are corroborated
// by Stats' Modules/Sensors/bridge.h and reader.m. Copy returns an owned CF
// object, so takeRetainedValue() balances it through ARC.
@_silgen_name("IOHIDEventSystemClientCreate")
private func createTemperatureClient(_ allocator: CFAllocator?) -> Unmanaged<IOHIDEventSystemClient>?

@_silgen_name("IOHIDEventSystemClientSetMatching")
private func matchTemperatureServices(_ client: IOHIDEventSystemClient, _ matching: CFDictionary)

@_silgen_name("IOHIDServiceClientCopyEvent")
private func copyTemperatureEvent(_ service: IOHIDServiceClient, _ type: Int64,
                                  _ matching: Int32, _ options: Int64) -> Unmanaged<CFTypeRef>?

@_silgen_name("IOHIDEventGetFloatValue")
private func temperatureEventValue(_ event: CFTypeRef, _ field: Int32) -> Double

/// Reads only Apple vendor temperature services. It never subscribes to HID
/// input, schedules a run loop, registers event callbacks, or sets device data.
public final class HIDSensors {
    private struct Descriptor {
        let product: String
        let name: String
        let category: String
    }

    private static let descriptors: [Descriptor] = [
        Descriptor(product: "gas gauge battery", name: "电池电量计", category: "电池"),
        Descriptor(product: "NAND CH0 temp", name: "SSD 温度", category: "存储")
    ] + [1, 2, 4, 5, 6, 7, 8].map {
        Descriptor(product: "PMU tdie\($0)", name: "电源管理芯片 \($0)", category: "电源")
    }
    private static let products = Set(descriptors.map(\.product))
    private static let powerProducts = descriptors.filter { $0.category == "电源" }.map(\.product)
    private let client: IOHIDEventSystemClient?

    public init() {
        // The SDK's CreateSimpleClient enumerates properties but returns no
        // temperature events on this Mac. The event-capable client is needed
        // for the same read path used by Macs Fan Control's IOKit sensors.
        let client = createTemperatureClient(kCFAllocatorDefault)?.takeRetainedValue()
        self.client = client
        if let client {
            matchTemperatureServices(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        }
    }

    public func readings() -> [TemperatureReading] {
        var values: [String: Double] = [:]
        if let client,
           let services = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] {
            for service in services {
                guard let product = IOHIDServiceClientCopyProperty(service, "Product" as CFString) as? String,
                      Self.products.contains(product), values[product] == nil,
                      let event = copyTemperatureEvent(service, 15, 0, 0)?.takeRetainedValue() else { continue }
                let value = temperatureEventValue(event, 15 << 16)
                if value.isFinite, (1...130).contains(value) { values[product] = value }
            }
        }

        var readings = Self.descriptors.map { descriptor in
            TemperatureReading(id: "HID:\(descriptor.product)", name: descriptor.name,
                               category: descriptor.category, value: values[descriptor.product])
        }
        let powerValues = Self.powerProducts.compactMap { values[$0] }
        // A missing member must not silently change the meaning of this fixed
        // MFC aggregate; expose an unavailable average instead of a partial one.
        let powerAverage = powerValues.count == Self.powerProducts.count
            ? powerValues.reduce(0, +) / Double(powerValues.count) : nil
        readings.append(TemperatureReading(id: "HID:Power Manager Die Average", name: "电源管理芯片平均",
                                           category: "电源", value: powerAverage))
        return readings
    }
}
