import Foundation
import SystemConfiguration

// The helper serializes ownership changes on its control queue. Signature
// verification is handled separately by the XPC listener.
public final class ControlSession {
    private let currentUser: () -> uid_t?
    public private(set) var owner: ObjectIdentifier?
    private var ownerUID: uid_t?

    public init(currentUser: @escaping () -> uid_t? = ControlSession.consoleUser) {
        self.currentUser = currentUser
    }

    public static func consoleUser() -> uid_t? {
        var uid: uid_t = 0
        guard let name = SCDynamicStoreCopyConsoleUser(nil, &uid, nil),
              name as String != "loginwindow", uid != 0, uid != uid_t.max else { return nil }
        return uid
    }

    public func allows(_ uid: uid_t) -> Bool {
        uid != 0 && uid != uid_t.max && currentUser() == uid
    }

    public func claim(_ identity: ObjectIdentifier, uid: uid_t) {
        owner = identity
        ownerUID = uid
    }

    public func clear() {
        owner = nil
        ownerUID = nil
    }

    public func releaseInactiveOwner(_ restoreAutomatic: () -> Void) {
        if let ownerUID, !allows(ownerUID) {
            restoreAutomatic()
            clear()
        }
    }
}
