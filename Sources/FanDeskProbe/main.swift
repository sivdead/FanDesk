import Foundation
#if canImport(FanCore)
import FanCore
#endif

do {
    if CommandLine.arguments.contains("--snapshot") {
        let reading = try Hardware().snapshot()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(reading), as: UTF8.self))
        exit(0)
    }
    let smc = try SMC()
    for key in ["FNum", "F0Ac", "F0Mn", "F0Mx", "F0Tg", "F0md", "F0Md", "F1Ac", "F1Mn", "F1Mx", "F1Tg", "F1md", "F1Md", "Ftst"] {
        do { print(key, try smc.keyInfo(key), try smc.readNumber(key)) }
        catch { print(key, String(describing: error)) }
    }
    let keys = try smc.allKeys().filter { $0.hasPrefix("Tp") || $0.hasPrefix("Te") || $0.hasPrefix("Tc") }
    for key in keys {
        if let value = try? smc.readNumber(key), value.isFinite, value > 0, value < 130 {
            print(key, value)
        }
    }
} catch {
    fputs("\(error)\n", stderr)
    exit(1)
}
