import Foundation
import IOKit
import FanStorage

/// Reads NVMe SMART composite temperatures through the SDK's official SMART
/// interface. This is a separate source from the HID NAND temperature sensor.
public final class NVMESensors {
    private struct Drive {
        let service: io_service_t
        let id: String
        let model: String
    }
    private let drives: [Drive]

    public init() {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDevice"),
                                          &iterator) == KERN_SUCCESS else {
            drives = []
            return
        }
        defer { IOObjectRelease(iterator) }

        var discovered: [Drive] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            guard let property = IORegistryEntryCreateCFProperty(service, "NVMe SMART Capable" as CFString,
                                                                 kCFAllocatorDefault, 0)?.takeRetainedValue(),
                  property as? Bool == true else {
                IOObjectRelease(service)
                continue
            }
            let characteristics = IORegistryEntryCreateCFProperty(service, "Device Characteristics" as CFString,
                                                                  kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any]
            let model = (characteristics?["Product Name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let bsdName = IORegistryEntrySearchCFProperty(service, kIOServicePlane, "BSD Name" as CFString,
                                                          kCFAllocatorDefault, IOOptionBits(kIORegistryIterateRecursively)) as? String
            var registryID: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(service, &registryID) == KERN_SUCCESS else {
                IOObjectRelease(service)
                continue
            }
            let id = bsdName.map { "NVMe:\($0)" } ?? "NVMe:registry-\(registryID)"
            discovered.append(Drive(service: service, id: id,
                                    model: model.flatMap { $0.isEmpty ? nil : $0 } ?? "NVMe 磁盘"))
        }
        drives = discovered.sorted { $0.id < $1.id }
    }

    deinit {
        for drive in drives { IOObjectRelease(drive.service) }
    }

    public func snapshot() -> [TemperatureReading] {
        drives.map { drive in
            var temperature = 0.0
            let result = FanStorageReadNVMeTemperature(drive.service, &temperature)
            let value = result == kIOReturnSuccess && temperature.isFinite && (1...130).contains(temperature)
                ? temperature : nil
            // Keep the discovered drive in the list when the read fails, so a
            // previously selected disk reports unavailable instead of vanishing.
            return TemperatureReading(id: drive.id, name: drive.model, category: "存储", value: value)
        }
    }
}
