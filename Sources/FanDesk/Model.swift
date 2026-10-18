import Foundation
import AppKit
import ServiceManagement
import OSLog
import FanCore

typealias DeskTransport = (HelperRequest, @escaping (HelperResponse?) -> Void) -> Void
protocol LoginManaging {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister(_ completion: @escaping (Error?) -> Void)
}
struct SystemLoginManager: LoginManaging {
    var status: SMAppService.Status { SMAppService.mainApp.status }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister(_ completion: @escaping (Error?) -> Void) { SMAppService.mainApp.unregister(completionHandler: completion) }
}

// UI layout and modal work must not delay the helper's five-second lease.
// This timer only renews liveness; telemetry and all model updates stay on main.
final class HelperHeartbeat {
    private let timer: DispatchSourceTimer
    init(send: @escaping () -> Void) {
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "FanDesk.heartbeat"))
        timer.schedule(deadline: .now() + 2, repeating: 2, leeway: .milliseconds(200))
        timer.setEventHandler(handler: send)
        timer.resume()
    }
    deinit { timer.cancel() }
}

final class DeskModel: ObservableObject {
    @Published var saved = SavedState()
    @Published var draft = Preset()
    // Menu-bar telemetry stays current while hidden windows stop observing it.
    var snapshot: Snapshot?
    @Published var active: Preset?
    @Published var notice = "正在读取传感器…"
    @Published var helperReady = false
    @Published var needsApproval = false
    @Published var competitor = false
    @Published var storageError = false
    @Published var loginStatus = ""
    @Published var controlBusy = false
    @Published var loginBusy = false
    private let preferencesURL: URL
    private let injectedTransport: DeskTransport?
    private let loginManager: LoginManaging
    private var hardware: Hardware?
    private var timer: Timer?
    private var heartbeat: HelperHeartbeat?
    private var connection: NSXPCConnection?
    private var polling = false
    private var interfaceVisible = false
    private var closing = false
    private var sleeping = false
    private var startupPending = true
    private var resumePreset: Preset?
    private var wakePending = false
    private var controlEpoch = 0
    private var intendedPreset: Preset?
    private var lifecycleObservers: [NSObjectProtocol] = []
    private let monitor = DispatchQueue(label: "FanDesk.monitor")
    private let logger = Logger(subsystem: DeskPaths.appID, category: "lifecycle")
    var changed: (() -> Void)?

    init(preferencesURL: URL = DeskPaths.preferences, transport: DeskTransport? = nil,
         loginManager: LoginManaging = SystemLoginManager(), startMonitoring: Bool = true) {
        self.preferencesURL = preferencesURL; self.injectedTransport = transport; self.loginManager = loginManager
        do {
            saved = try SavedState.load(from: preferencesURL)
            draft = saved.presets.first(where: { $0.id == saved.selected }) ?? saved.presets.first ?? Preset()
        } catch { notice = "预设读取失败，原文件已保留：\(error.localizedDescription)"; storageError = true }
        syncLoginStatus()
        guard startMonitoring else { return }
        let center = NSWorkspace.shared.notificationCenter
        lifecycleObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.prepareForSleep() })
        lifecycleObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.resumeFromSleep() })
        monitor.async { [weak self] in
            do {
                let hardware = try Hardware()
                self?.hardware = hardware
                let reading = try hardware.snapshot()
                DispatchQueue.main.async { self?.updateSnapshot(reading); self?.changed?() }
            } catch { DispatchQueue.main.async { self?.notice = error.localizedDescription } }
        }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.poll() }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
        poll()
    }
    deinit {
        timer?.invalidate()
        for token in lifecycleObservers { NSWorkspace.shared.notificationCenter.removeObserver(token) }
    }
    func setInterfaceVisible(_ visible: Bool) {
        guard interfaceVisible != visible else { return }
        interfaceVisible = visible
        if visible { objectWillChange.send() }
    }
    private func updateSnapshot(_ reading: Snapshot) {
        guard snapshot != reading else { return }
        if interfaceVisible { objectWillChange.send() }
        snapshot = reading
    }
    var service: SMAppService { .daemon(plistName: DeskPaths.daemonPlist) }
    var hasUnsavedChanges: Bool { draft != saved.presets.first(where: { $0.id == draft.id }) }
    var sensorOptions: [TemperatureReading] {
        var values = snapshot?.sensors ?? []
        if !values.contains(where: { $0.id == SensorChoice.cpuAverage.rawValue }) {
            values.insert(TemperatureReading(id: SensorChoice.cpuAverage.rawValue, name: SensorChoice.cpuAverage.title, category: "CPU", value: try? snapshot?.temperature(for: .cpuAverage)), at: 0)
        }
        if !values.contains(where: { $0.id == SensorChoice.cpuMaximum.rawValue }) {
            values.insert(TemperatureReading(id: SensorChoice.cpuMaximum.rawValue, name: SensorChoice.cpuMaximum.title, category: "CPU", value: try? snapshot?.temperature(for: .cpuMaximum)), at: 1)
        }
        // A saved sensor may disappear; retain it visibly rather than silently substituting another sensor.
        for choice in draft.fans.map(\.sensor) + [saved.preferences.menuSensor] where !values.contains(where: { $0.id == choice.rawValue }) {
            values.append(TemperatureReading(id: choice.rawValue, name: "\(choice.title)（不可用）", category: "不可用", value: nil))
        }
        return values
    }
    var modeTitle: String {
        if let active { return "控制中 · \(active.name)" }
        if competitor { return "监测中 · Macs Fan Control 正在运行" }
        if !helperReady { return "监测中 · 尚未连接风扇控制" }
        if snapshot?.fans.contains(where: { $0.mode == 1 }) == true { return "监测中 · 外部手动控制" }
        return "系统自动控制"
    }
    func fanStatus(_ index: Int) -> String {
        guard (0..<2).contains(index) else { return "不可用" }
        if let setting = active?.fans[index] {
            if setting.mode != .automatic && ([.serious, .critical].contains(ProcessInfo.processInfo.thermalState) || (snapshot?.maximum ?? 0) >= 90) { return "高温保护 · 全速" }
            if setting.mode == .constant { return "固定 \(Int(setting.rpm)) RPM" }
            if setting.mode == .temperature {
                let name = sensorOptions.first(where: { $0.id == setting.sensor.rawValue })?.name ?? setting.sensor.title
                return "温控 · \(name)"
            }
            return "系统自动"
        }
        return snapshot?.fans[index].mode == 1 ? "外部手动控制" : "系统自动"
    }
    @discardableResult private func commit(_ updated: SavedState) -> Bool {
        guard !storageError else { notice = "请先修复预设文件，避免覆盖原有数据。"; return false }
        do { try updated.save(to: preferencesURL); saved = updated; changed?(); return true }
        catch { notice = "保存失败：\(error.localizedDescription)"; return false }
    }
    func select(_ id: UUID) {
        guard !controlBusy else { return }
        guard let value = saved.presets.first(where: { $0.id == id }) else { return }
        if hasUnsavedChanges && id != draft.id {
            let alert = NSAlert(); alert.messageText = "丢弃未保存的修改？"; alert.informativeText = "切换预设会替换编辑中的设置，当前正在运行的控制保持到你点击应用。"
            alert.addButton(withTitle: "丢弃并切换"); alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        draft = value
        var updated = saved; updated.selected = id; _ = commit(updated)
    }
    func save(asNew: Bool) {
        guard !controlBusy else { return }
        do {
            var value = draft; value.name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
            try value.validate()
            if asNew && saved.presets.contains(where: { $0.id == value.id }) { value.id = UUID() }
            guard !saved.presets.contains(where: { $0.name == value.name && $0.id != value.id }) else {
                throw DeskError.invalid("已有同名预设，请换一个名称或保存所选预设。")
            }
            var updated = saved
            if let index = updated.presets.firstIndex(where: { $0.id == value.id }) { updated.presets[index] = value }
            else { updated.presets.append(value) }
            updated.selected = value.id
            // Renaming a running saved preset also updates its identity in the next-launch state.
            if let current = active, current.id == draft.id, current.fans == value.fans { updated.lastApplied = value }
            if commit(updated) {
                draft = value
                if active?.id == value.id && active?.fans == value.fans { active = value; intendedPreset = value }
                notice = "已保存“\(value.name)”。"
            }
        } catch { notice = error.localizedDescription }
    }
    func deleteSelected() {
        guard !controlBusy else { return }
        let id = draft.id
        guard saved.presets.contains(where: { $0.id == id }) else { return }
        let remove = { [weak self] in
            guard let self else { return }
            var updated = saved; updated.presets.removeAll { $0.id == id }
            if updated.lastApplied?.id == id { updated.lastApplied = nil }
            updated.selected = updated.presets.first?.id
            if commit(updated) {
                draft = updated.presets.first ?? Preset(name: "新预设")
                notice = "已删除所选预设。"
            }
        }
        if active?.id == id {
            requestAutomatic(clearRestore: true) { success in if success { remove() } }
        } else { remove() }
    }
    func discardChanges() {
        requestAutomatic(clearRestore: true) { [weak self] success in
            guard let self, success else { return }
            draft = saved.presets.first(where: { $0.id == self.draft.id }) ?? saved.presets.first(where: { $0.id == self.saved.selected }) ?? saved.presets.first ?? Preset(name: "新预设")
            notice = "未保存的修改已丢弃，风扇由系统自动控制。"
        }
    }
    func setFanMode(_ index: Int, _ mode: FanMode) {
        guard !controlBusy else { return }
        guard draft.fans.indices.contains(index) else { return }
        draft.fans[index].mode = mode
        if mode == .constant, let fan = snapshot?.fans[index] {
            draft.fans[index].rpm = min(fan.maximum, max(fan.minimum, draft.fans[index].rpm))
        }
    }
    func applyFan(_ index: Int) {
        guard draft.fans.indices.contains(index) else { return }
        var value = active ?? Preset(name: "自定义", fans: Array(repeating: FanSetting(mode: .automatic), count: 2))
        value.id = UUID(); value.name = "自定义（未保存）"; value.fans[index] = draft.fans[index]
        let baseline = saved.presets.first(where: { $0.id == draft.id }) ?? active
        let otherIndex = index == 0 ? 1 : 0
        let preservesOtherEdits = baseline.map { draft.fans[otherIndex] == $0.fans[otherIndex] && draft.name == $0.name } ?? false
        applyPreset(value, adoptDraft: preservesOtherEdits)
    }
    func apply() { applyPreset(draft) }
    func applySaved(_ id: UUID) {
        guard let value = saved.presets.first(where: { $0.id == id }) else { return }
        select(id)
        guard draft == value else { return }
        applyPreset(value, adoptDraft: true)
    }
    func fullBlast() {
        guard let snapshot else { notice = "尚未读取到风扇范围。"; return }
        let value = Preset(name: "全速", fans: snapshot.fans.map { FanSetting(mode: .constant, rpm: $0.maximum) })
        // This is a temporary control override, not an edit to the selected preset.
        applyPreset(value)
    }
    func useActiveConfiguration() {
        guard !controlBusy, let active else { return }
        draft = active; changed?()
    }
    private func applyPreset(_ value: Preset, restored: Bool = false, adoptDraft: Bool = false) {
        guard !closing, !sleeping, !controlBusy else { return }
        if injectedTransport == nil { competitor = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.crystalidea.macsfancontrol").isEmpty }
        guard !competitor else { notice = "请先退出 Macs Fan Control，再应用控制设置。"; return }
        guard helperReady else { notice = "请先启用并连接后台风扇控制。"; return }
        do { try value.validate() } catch { notice = error.localizedDescription; return }
        if !restored { startupPending = false; wakePending = false; resumePreset = nil }
        controlBusy = true; controlEpoch += 1; polling = false
        let epoch = controlEpoch
        let submittedDraft = draft
        send(HelperRequest(.apply, preset: value)) { [weak self] result in
            guard let self, !closing, epoch == controlEpoch else { return }
            controlBusy = false
            accept(result)
            if let result, result.error == nil {
                intendedPreset = active
                if adoptDraft && draft == submittedDraft { draft = value }
                var updated = saved; updated.lastApplied = result.activePreset
                if commit(updated) {
                    notice = restored ? "已恢复“\(value.name)”的控制设置。" : "已应用“\(value.name)”。"
                    logger.info("Applied preset \(value.name, privacy: .public)")
                }
            }
        }
    }
    func automatic() { requestAutomatic(clearRestore: true) { _ in } }
    private func requestAutomatic(clearRestore: Bool, completion: @escaping (Bool) -> Void) {
        guard !controlBusy, !closing, !sleeping else { completion(false); return }
        if clearRestore { startupPending = false; wakePending = false; resumePreset = nil }
        if !helperReady && active == nil {
            var persisted = true
            if clearRestore { var updated = saved; updated.lastApplied = nil; persisted = commit(updated) }
            intendedPreset = nil
            completion(persisted && snapshot?.fans.allSatisfy { $0.mode == 0 } == true); return
        }
        controlBusy = true; controlEpoch += 1; polling = false
        let epoch = controlEpoch
        send(HelperRequest(.automatic)) { [weak self] result in
            guard let self, epoch == controlEpoch, !closing, !sleeping else { completion(false); return }
            controlBusy = false
            accept(result)
            let success = result?.error == nil && result?.activePreset == nil && result?.snapshot?.fans.allSatisfy { $0.mode == 0 } == true
            if success {
                intendedPreset = nil
                if clearRestore {
                    var updated = saved; updated.lastApplied = nil
                    guard commit(updated) else {
                        notice = "风扇已交回系统，但启动恢复设置保存失败：\(notice)"
                        completion(false); return
                    }
                }
                notice = "已恢复系统自动控制。"
            }
            completion(success)
        }
    }
    func updatePreferences(_ preferences: DeskPreferences) {
        do { try preferences.validate() } catch { notice = error.localizedDescription; return }
        if preferences.launchAtLogin != saved.preferences.launchAtLogin {
            guard !loginBusy else { notice = "登录启动设置正在更新。"; return }
            if preferences.launchAtLogin {
                do { if loginManager.status != .enabled && loginManager.status != .requiresApproval { try loginManager.register() } }
                catch {
                    if loginManager.status != .requiresApproval {
                        syncLoginStatus(); notice = "登录启动尚未启用：\(error.localizedDescription)"; return
                    }
                }
            } else {
                if loginManager.status == .notRegistered || loginManager.status == .notFound {
                    var updated = saved; updated.preferences = preferences
                    _ = commit(updated); syncLoginStatus(); return
                }
                loginBusy = true
                // Apply the non-login settings now; completion only merges its own field.
                var updated = saved; updated.preferences = preferences; updated.preferences.launchAtLogin = true
                _ = commit(updated)
                loginManager.unregister { [weak self] error in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.loginBusy = false
                        if let error { self.notice = "登录启动设置失败：\(error.localizedDescription)" }
                        else { var updated = self.saved; updated.preferences.launchAtLogin = false; _ = self.commit(updated); self.syncLoginStatus() }
                    }
                }
                return
            }
        }
        var updated = saved; updated.preferences = preferences
        if commit(updated) {
            syncLoginStatus()
            notice = loginManager.status == .requiresApproval ? "请在系统设置中允许 FanDesk 登录启动。" : "设置已保存。"
        }
    }
    func syncLoginStatus() {
        switch loginManager.status {
        case .enabled: loginStatus = "已启用登录启动"
        case .requiresApproval: loginStatus = "需要在系统设置中允许登录启动"
        default: loginStatus = "未启用登录启动"
        }
        guard !loginBusy, !storageError else { return }
        let enabled = loginManager.status == .enabled || loginManager.status == .requiresApproval
        if saved.preferences.launchAtLogin != enabled { var updated = saved; updated.preferences.launchAtLogin = enabled; _ = commit(updated) }
    }
    func enableHelper() {
        guard !controlBusy else { return }
        guard !competitor else { notice = "请先退出 Macs Fan Control，再启用后台控制。"; return }
        guard Bundle.main.bundleURL.path == "/Applications/FanDesk.app" else { notice = "请使用应用程序文件夹中的完整 FanDesk。"; return }
        if service.status == .enabled && !helperReady {
            refreshInstalledHelper()
            return
        }
        do {
            if service.status == .requiresApproval { needsApproval = true; SMAppService.openSystemSettingsLoginItems(); return }
            if service.status != .enabled { try service.register() }
            needsApproval = service.status == .requiresApproval
            notice = needsApproval ? "请在系统设置中允许 FanDesk 后台服务。" : "后台服务已注册，正在连接…"
            if needsApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch {
            if service.status == .requiresApproval {
                needsApproval = true; notice = "请在系统设置中允许 FanDesk 后台服务。"; SMAppService.openSystemSettingsLoginItems()
            } else { notice = "后台服务尚未启用：\(error.localizedDescription)" }
        }
    }
    private func refreshInstalledHelper() {
        // A replaced executable must be re-registered with ServiceManagement.
        // Never remove the only recovery service while a fan is still manual.
        guard !sleeping, !closing else { return }
        controlBusy = true; controlEpoch += 1; polling = false
        let epoch = controlEpoch
        notice = "正在确认风扇状态并连接新版后台服务…"
        monitor.async { [weak self] in
            guard let self else { return }
            do {
                let current = try Hardware().snapshot()
                guard current.fans.allSatisfy({ $0.mode == 0 }) else {
                    throw DeskError.invalid("检测到手动控制。请先退出其他风扇控制软件并恢复系统自动，再连接新版服务。")
                }
                DispatchQueue.main.async {
                    guard epoch == self.controlEpoch else { return }
                    guard !self.closing, !self.sleeping else { self.controlBusy = false; return }
                    guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.crystalidea.macsfancontrol").isEmpty else {
                        self.controlBusy = false; self.notice = "请先退出 Macs Fan Control。"; return
                    }
                    self.service.unregister { error in
                        DispatchQueue.main.async {
                            guard !self.closing, !self.sleeping, epoch == self.controlEpoch else { return }
                            self.controlBusy = false
                            if let error { self.notice = "后台更新失败：\(error.localizedDescription)"; return }
                            self.heartbeat = nil
                            self.connection?.invalidate(); self.connection = nil
                            self.enableHelper()
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    guard epoch == self.controlEpoch, !self.closing, !self.sleeping else { return }
                    self.controlBusy = false; self.notice = error.localizedDescription
                }
            }
        }
    }
    private func connect() throws -> NSXPCConnection {
        if let connection { return connection }
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchServices/FanDeskHelper")
        let new = NSXPCConnection(machServiceName: DeskPaths.service, options: .privileged)
        new.setCodeSigningRequirement(try pinnedRequirement(for: helper))
        new.remoteObjectInterface = NSXPCInterface(with: FanDeskHelperProtocol.self)
        let heartbeatData = try JSONEncoder().encode(HelperRequest(.heartbeat))
        let lost = { [weak self, weak new] in
            DispatchQueue.main.async {
                guard self?.connection === new else { return }
                self?.heartbeat = nil
                new?.invalidate(); self?.connection = nil; self?.helperReady = false; self?.active = nil
                if self?.sleeping == false { self?.notice = "后台连接中断，恢复连接后请重新应用预设。" }
            }
        }
        new.invalidationHandler = lost; new.interruptionHandler = lost
        new.resume(); connection = new
        heartbeat = HelperHeartbeat { [weak new] in
            guard let proxy = new?.remoteObjectProxyWithErrorHandler({ _ in }) as? FanDeskHelperProtocol else { return }
            proxy.request(heartbeatData) { _ in }
        }
        return new
    }
    private func send(_ request: HelperRequest, completion: @escaping (HelperResponse?) -> Void) {
        if let injectedTransport {
            if heartbeat == nil && request.command != .automatic {
                heartbeat = HelperHeartbeat { injectedTransport(HelperRequest(.heartbeat)) { _ in } }
            }
            injectedTransport(request) { result in DispatchQueue.main.async { completion(result) } }
            return
        }
        do {
            let data = try JSONEncoder().encode(request), conn = try connect()
            var completed = false
            let finish: (HelperResponse?) -> Void = { result in
                DispatchQueue.main.async {
                    guard !completed else { return }; completed = true; completion(result)
                }
            }
            guard let proxy = conn.remoteObjectProxyWithErrorHandler({ _ in finish(nil) }) as? FanDeskHelperProtocol else { finish(nil); return }
            proxy.request(data) { bytes in finish(try? JSONDecoder().decode(HelperResponse.self, from: bytes)) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { finish(nil) }
        } catch { notice = error.localizedDescription; completion(nil) }
    }
    private func accept(_ result: HelperResponse?) {
        let wasReady = helperReady, wasActive = active != nil
        if helperReady != (result != nil) { helperReady = result != nil }
        guard let result else { active = nil; notice = "后台服务未连接，当前仅监测。"; return }
        if let reading = result.snapshot { updateSnapshot(reading) }
        let received = result.activePreset.flatMap { received in
            saved.presets.first(where: { $0.id == received.id && $0.fans == received.fans }) ?? received
        }
        if active != received { active = received }
        if let error = result.error { notice = error }
        else if wasActive && active == nil && !sleeping { notice = "已恢复系统自动控制，需要继续时请重新应用预设。" }
        else if !wasReady { notice = "后台服务已连接。" }
        changed?()
        if wakePending && !sleeping && result.error == nil && result.snapshot != nil {
            wakePending = false
            if saved.preferences.restoreAfterWake, let value = resumePreset {
                resumePreset = nil; applyPreset(value, restored: true)
            } else { resumePreset = nil; notice = "已唤醒，风扇由系统自动控制。" }
        } else if startupPending && !sleeping && result.error == nil && result.snapshot != nil {
            startupPending = false
            if saved.preferences.restoreOnLaunch, let value = saved.lastApplied { applyPreset(value, restored: true) }
        }
    }
    func poll() {
        guard !closing, !sleeping, !polling, !controlBusy else { return }
        if injectedTransport == nil {
            let running = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.crystalidea.macsfancontrol").isEmpty
            if competitor != running { competitor = running }
        }
        if competitor && active != nil { automatic(); return }
        let helperStatus = service.status
        if needsApproval != (helperStatus == .requiresApproval) { needsApproval = helperStatus == .requiresApproval }
        polling = true
        let epoch = controlEpoch
        if injectedTransport != nil || helperStatus == .enabled {
            send(HelperRequest(.status)) { [weak self] response in
                guard let self, !closing else { return }
                guard epoch == controlEpoch, !sleeping else { return }
                if let response { accept(response); polling = false }
                else { if helperReady { helperReady = false }; if active != nil { active = nil }; localRead() }
            }
        } else { if helperReady { helperReady = false }; localRead() }
    }
    private func localRead() {
        monitor.async { [weak self] in
            guard let self else { return }
            do {
                guard let hardware else { DispatchQueue.main.async { self.polling = false }; return }
                let value = try hardware.snapshot()
                DispatchQueue.main.async {
                    self.updateSnapshot(value); self.polling = false
                    if self.notice == "正在读取传感器…" { self.notice = "预设可以直接保存；启用后台服务后即可控制风扇。" }
                    self.changed?()
                }
            } catch { DispatchQueue.main.async { self.notice = error.localizedDescription; self.polling = false } }
        }
    }
    func prepareForSleep() {
        guard !closing, !sleeping else { return }
        sleeping = true; startupPending = false; resumePreset = intendedPreset; wakePending = false
        heartbeat = nil
        controlEpoch += 1; controlBusy = false; active = nil; polling = false
        let sleepingConnection = connection
        logger.info("Sleep: releasing fan control")
        send(HelperRequest(.automatic)) { [weak self, weak sleepingConnection] _ in
            if let sleepingConnection {
                sleepingConnection.invalidate()
                if self?.connection === sleepingConnection { self?.connection = nil; self?.helperReady = false }
            }
        }
    }
    func resumeFromSleep() {
        guard !closing else { return }
        sleeping = false; wakePending = true; polling = false; helperReady = false
        controlEpoch += 1; controlBusy = false
        heartbeat = nil
        connection?.invalidate(); connection = nil
        logger.info("Wake: reconnecting fan control")
        poll()
    }
    func shutdown(_ completion: @escaping () -> Void) {
        closing = true; timer?.invalidate(); heartbeat = nil
        guard connection != nil else { completion(); return }
        send(HelperRequest(.automatic)) { [weak self] _ in self?.connection?.invalidate(); completion() }
    }
}
