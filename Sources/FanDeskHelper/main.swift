import Foundation
import AppKit
import OSLog
import IOKit.pwr_mgt
import FanCore

final class Bridge: NSObject, FanDeskHelperProtocol {
    let handler: (Data, @escaping (Data) -> Void) -> Void
    init(_ handler: @escaping (Data, @escaping (Data) -> Void) -> Void) { self.handler = handler }
    func request(_ data: Data, reply: @escaping (Data) -> Void) { handler(data, reply) }
}

final class Service: NSObject, NSXPCListenerDelegate {
    let engine: ControlEngine
    let queue = DispatchQueue(label: "FanDesk.control")
    var owner: ObjectIdentifier?
    var timers: [DispatchSourceTimer] = []
    var signals: [DispatchSourceSignal] = []
    var power: PowerObserver?
    var sleeping = false
    let allowedUID: uid_t

    init(allowedUID: uid_t) throws {
        self.allowedUID = allowedUID
        engine = ControlEngine(hardware: try Hardware())
        super.init()
        engine.automatic()
        power = try PowerObserver(service: self)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard !sleeping else { return }
            _ = engine.tick(now: ProcessInfo.processInfo.systemUptime)
            if engine.active == nil { owner = nil }
        }
        timer.resume(); timers.append(timer)
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: queue)
            source.setEventHandler { [weak self] in self?.engine.automatic(); exit(0) }
            source.resume(); signals.append(source)
        }
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == allowedUID else { return false }
        let identity = ObjectIdentifier(connection)
        connection.exportedInterface = NSXPCInterface(with: FanDeskHelperProtocol.self)
        connection.exportedObject = Bridge { [weak self] data, reply in
            guard let self else { return }
            queue.async {
                let result: HelperResponse
                do {
                    guard data.count < 16384 else { throw DeskError.invalid("请求过大。") }
                    let request = try JSONDecoder().decode(HelperRequest.self, from: data)
                    guard !self.sleeping else { throw DeskError.invalid("系统正在睡眠或尚未完成唤醒。") }
                    let now = ProcessInfo.processInfo.systemUptime
                    switch request.command {
                    case .apply:
                        guard self.owner == nil || self.owner == identity else { throw DeskError.invalid("已有另一个 FanDesk 窗口控制风扇。") }
                        guard let preset = request.preset else { throw DeskError.invalid("缺少预设。") }
                        result = try self.engine.apply(preset, now: now)
                        self.owner = self.engine.active == nil ? nil : identity
                    case .automatic:
                        self.engine.automatic(); self.owner = nil
                        result = self.engine.tick(now: now)
                    case .heartbeat:
                        if self.owner == identity { self.engine.heartbeat(now: now) }
                        result = self.engine.tick(now: now)
                    case .status: result = self.engine.tick(now: now)
                    }
                } catch { result = HelperResponse(error: error.localizedDescription) }
                let encoded = (try? JSONEncoder().encode(result)) ?? Data("{}".utf8)
                reply(encoded)
            }
        }
        connection.invalidationHandler = { [weak self] in
            guard let self else { return }
            queue.async { if self.owner == identity { self.engine.automatic(); self.owner = nil } }
        }
        connection.resume()
        return true
    }
}

// Release manual control before acknowledging sleep, independently of the UI.
final class PowerObserver {
    weak var service: Service?
    var root: io_connect_t = 0
    var port: IONotificationPortRef?
    var notifier: io_object_t = 0
    let logger = Logger(subsystem: DeskPaths.appID, category: "power")
    init(service: Service) throws {
        self.service = service
        root = IORegisterForSystemPower(Unmanaged.passUnretained(self).toOpaque(), &port, { context, _, message, argument in
            guard let context else { return }
            let observer = Unmanaged<PowerObserver>.fromOpaque(context).takeUnretainedValue()
            observer.receive(message, argument: argument)
        }, &notifier)
        guard root != 0, let port, let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() else {
            throw DeskError.invalid("无法注册系统睡眠通知。")
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }
    func receive(_ message: UInt32, argument: UnsafeMutableRawPointer?) {
        let notificationID = Int(bitPattern: argument)
        switch message {
        // IOMessage.h macros are not imported by Swift: sys_iokit | message.
        case 0xe0000270:
            IOAllowPowerChange(root, notificationID)
        case 0xe0000280:
            guard let service else { IOAllowPowerChange(root, notificationID); return }
            service.queue.async { [self] in
                service.sleeping = true; service.engine.automatic(); service.owner = nil
                if let failure = service.engine.failure { logger.error("Sleep reset failed: \(failure, privacy: .public)") }
                else { logger.info("Sleep: released fan control") }
                IOAllowPowerChange(root, notificationID)
            }
        case 0xe0000300:
            service?.queue.async { [weak service, self] in
                service?.sleeping = false
                logger.info("Wake: hardware ready; waiting for app to restore preset")
            }
        default: break
        }
    }
    deinit {
        if notifier != 0 { IODeregisterForSystemPower(&notifier) }
        if let port {
            if let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
            IONotificationPortDestroy(port)
        }
        if root != 0 { IOServiceClose(root) }
    }
}

do {
    guard getuid() == 0 else { throw DeskError.invalid("后台服务只能由系统启动。") }
    var pathSize: UInt32 = 0
    _ = _NSGetExecutablePath(nil, &pathSize)
    var executablePath = [CChar](repeating: 0, count: Int(pathSize))
    guard _NSGetExecutablePath(&executablePath, &pathSize) == 0 else {
        throw DeskError.invalid("无法确定后台服务的安装位置。")
    }
    let executable = URL(fileURLWithPath: String(cString: executablePath)).resolvingSymlinksInPath()
    let bundle = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    guard let info = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")),
          let uid = info["FanDeskOwnerUID"] as? NSNumber, uid.uint32Value >= 501 else {
        throw DeskError.invalid("缺少安装用户信息。")
    }
    let requirement = try pinnedRequirement(for: bundle)
    let service = try Service(allowedUID: uid.uint32Value)
    let listener = NSXPCListener(machServiceName: DeskPaths.service)
    listener.setConnectionCodeSigningRequirement(requirement)
    listener.delegate = service
    listener.resume()
    RunLoop.current.run()
    service.engine.automatic()
} catch {
    Logger(subsystem: DeskPaths.appID, category: "helper").error("Startup failed: \(error.localizedDescription, privacy: .public)")
    fputs("FanDesk helper: \(error.localizedDescription)\n", stderr)
    exit(1)
}
