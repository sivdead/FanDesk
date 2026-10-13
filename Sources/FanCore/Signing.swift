import Foundation
import Security

public func pinnedRequirement(for url: URL) throws -> String {
    var code: SecStaticCode?
    let create = SecStaticCodeCreateWithPath(url as CFURL, [], &code)
    guard create == errSecSuccess, let code else { throw DeskError.invalid("无法读取应用签名。") }
    guard SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess else {
        throw DeskError.invalid("应用签名无效，请重新构建或安装完整应用。")
    }
    var info: CFDictionary?
    guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
          let values = info as? [String: Any], let digest = values[kSecCodeInfoUnique as String] as? Data else {
        throw DeskError.invalid("无法读取应用代码标识。")
    }
    return "cdhash H\"" + digest.map { String(format: "%02x", $0) }.joined() + "\""
}
