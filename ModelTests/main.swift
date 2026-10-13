import Foundation
import AppKit
import ServiceManagement
import FanCore

var count = 0
func check(_ value: @autoclosure () -> Bool, _ message: String) {
    count += 1
    guard value() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
func drain() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03)) }
final class FakeLogin: LoginManaging {
    var status: SMAppService.Status = .notRegistered
    var registrations = 0
    var approvalRequired = false
    var unregisterReply: ((Error?) -> Void)?
    func register() throws {
        registrations += 1
        status = approvalRequired ? .requiresApproval : .enabled
        if approvalRequired { throw DeskError.invalid("approval required") }
    }
    func unregister(_ reply: @escaping (Error?) -> Void) { unregisterReply = reply }
    func finishUnregister() { status = .notRegistered; unregisterReply?(nil); unregisterReply = nil; drain() }
}
final class FakeTransport {
    struct Pending { let request: HelperRequest; let reply: (HelperResponse?) -> Void }
    var pending: [Pending] = []
    func send(_ request: HelperRequest, reply: @escaping (HelperResponse?) -> Void) { pending.append(Pending(request: request, reply: reply)) }
}
let fans = [FanReading(id: 0, actual: 1350, target: 1350, minimum: 1350, maximum: 5349, mode: 0),
            FanReading(id: 1, actual: 1350, target: 1350, minimum: 1350, maximum: 5777, mode: 0)]
let reading = Snapshot(average: 55, maximum: 60, sensorCount: 18, fans: fans)
func response(_ preset: Preset? = nil) -> HelperResponse {
    var snapshot = reading
    for i in snapshot.fans.indices { snapshot.fans[i].mode = preset?.fans[i].mode == .automatic || preset == nil ? 0 : 1 }
    return HelperResponse(snapshot: snapshot, activePreset: preset)
}
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FanDesk-model-checks-\(UUID())")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
func fixture(_ name: String) -> (DeskModel, FakeTransport, FakeLogin, URL) {
    let transport = FakeTransport(), login = FakeLogin(), url = directory.appendingPathComponent(name + ".json")
    let model = DeskModel(preferencesURL: url, transport: transport.send, loginManager: login, startMonitoring: false)
    model.snapshot = reading; model.helperReady = true
    return (model, transport, login, url)
}

do {
    let (model, transport, _, _) = fixture("serial")
    model.setFanMode(0, .constant); model.draft.fans[0].rpm = 2222
    model.applyFan(0)
    check(model.controlBusy && transport.pending.count == 1, "first fan application is pending")
    model.applyFan(1)
    check(transport.pending.count == 1, "concurrent application cannot overwrite pending fan update")
    let first = transport.pending[0].request.preset!
    transport.pending[0].reply(response(first)); drain()
    check(!model.controlBusy && model.active?.fans[0].rpm == 2222, "first action completes before next")
    model.setFanMode(1, .constant); model.draft.fans[1].rpm = 3333; model.applyFan(1)
    let second = transport.pending[1].request.preset!
    check(second.fans[0].rpm == 2222 && second.fans[1].rpm == 3333, "second application preserves first fan")
    transport.pending[1].reply(response(second)); drain()
    check(model.draft.fans == second.fans, "saving after a fan shortcut uses actual running configuration")
    model.fullBlast()
    let full = transport.pending[2].request.preset!
    transport.pending[2].reply(response(full)); drain()
    check(model.draft.fans.map(\.rpm) == [5349,5777], "full speed draft reflects hardware limits")
    model.draft.name = "全速保存"; model.save(asNew: true)
    check(model.saved.presets.last?.fans == full.fans, "saving full speed stores the running settings")
    check(model.saved.presets.last?.id == model.active?.id, "first save of running custom settings keeps control identity")
    let savedFullID = model.draft.id
    model.deleteSelected()
    check(transport.pending[3].request.command == .automatic, "deleting the running saved custom preset first releases hardware")
    transport.pending[3].reply(response()); drain()
    check(model.active == nil && !model.saved.presets.contains(where: { $0.id == savedFullID }), "running preset deletion completes only after automatic reset")
}
do {
    let (model, transport, _, _) = fixture("other-edits")
    model.setFanMode(0, .constant); model.draft.fans[0].rpm = 2400
    model.setFanMode(1, .constant); model.draft.fans[1].rpm = 2600
    model.applyFan(0)
    let applied = transport.pending[0].request.preset!
    transport.pending[0].reply(response(applied)); drain()
    check(model.draft.fans[1].mode == .constant && model.draft.fans[1].rpm == 2600, "single fan application preserves other unapplied edits")
    model.fullBlast(); let full = transport.pending[1].request.preset!
    transport.pending[1].reply(response(full)); drain()
    check(model.draft.fans[1].rpm == 2600, "full speed preserves a pending draft until explicit read-current")
    model.useActiveConfiguration()
    check(model.draft.fans.map(\.rpm) == [5349,5777], "explicit read-current exposes running full speed for saving")
}
do {
    let (model, transport, _, _) = fixture("edits-during-reply")
    model.setFanMode(0, .constant); model.draft.fans[0].rpm = 2400; model.applyFan(0)
    model.draft.name = "之后输入的名称"
    transport.pending[0].reply(response(transport.pending[0].request.preset)); drain()
    check(model.draft.name == "之后输入的名称", "late application result cannot discard subsequent draft input")
}
do {
    let (model, transport, _, _) = fixture("stale-poll")
    model.poll()
    let oldHeartbeat = transport.pending[0]
    model.setFanMode(0, .constant); model.draft.fans[0].rpm = 2400; model.applyFan(0)
    let applied = transport.pending[1].request.preset!
    transport.pending[1].reply(response(applied)); drain()
    oldHeartbeat.reply(response()); drain()
    check(model.active == applied, "old heartbeat cannot erase a newer fan application")
    model.poll()
    check(transport.pending.count == 3, "discarding old heartbeat does not stall polling")
}
do {
    let (model, transport, _, _) = fixture("sleep")
    model.apply(); let preset = transport.pending[0].request.preset!
    transport.pending[0].reply(response(preset)); drain()
    model.active = nil // A helper sleep response arrived before UI willSleep.
    model.prepareForSleep()
    let oldSleepReply = transport.pending[1].reply
    model.resumeFromSleep()
    check(transport.pending[2].request.command == .heartbeat, "wake reconnects and requests current status")
    transport.pending[2].reply(response()); drain()
    check(transport.pending.count == 4 && transport.pending[3].request.preset == preset, "sleep recovery uses successful intent, not transient active")
    transport.pending[3].reply(response(preset)); drain()
    oldSleepReply(response()); drain()
    check(model.active == preset && model.helperReady, "late sleep completion cannot revoke wake restoration")
}
do {
    let (model, transport, _, _) = fixture("stale-action")
    model.apply()
    let oldApply = transport.pending[0]
    model.prepareForSleep(); model.resumeFromSleep()
    transport.pending[2].reply(response()); drain()
    oldApply.reply(response(oldApply.request.preset)); drain()
    check(model.active == nil, "old application reply cannot cross the sleep generation")
}
do {
    let (model, transport, _, url) = fixture("save-failure")
    model.apply(); let preset = transport.pending[0].request.preset!
    transport.pending[0].reply(response(preset)); drain()
    try FileManager.default.moveItem(at: url, to: url.appendingPathExtension("backup"))
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    model.automatic(); transport.pending[1].reply(response()); drain()
    check(model.active == nil && model.notice.contains("保存失败"), "hardware reset cannot hide persistence failure")
    check(model.saved.lastApplied == preset, "failed preference write is not reported committed")
}
do {
    let (model, _, login, _) = fixture("login-approval")
    login.approvalRequired = true
    var preference = model.saved.preferences; preference.launchAtLogin = true
    model.updatePreferences(preference)
    check(model.saved.preferences.launchAtLogin && model.loginStatus.contains("需要"), "pending login authorization remains visible and saved")
    login.status = .enabled; model.syncLoginStatus()
    check(model.saved.preferences.launchAtLogin && model.loginStatus.contains("已启用"), "system approval synchronizes login state")
    model.updatePreferences(model.saved.preferences)
    check(login.registrations == 1, "approved login item is not registered twice")
    preference = model.saved.preferences; preference.launchAtLogin = false
    model.updatePreferences(preference)
    check(model.loginBusy, "unregistration is serialized")
    var concurrent = model.saved.preferences; concurrent.menuFan = 1; concurrent.menuIcon = .colored
    model.updatePreferences(concurrent)
    login.finishUnregister()
    check(!model.saved.preferences.launchAtLogin && model.saved.preferences.menuFan == 1 && model.saved.preferences.menuIcon == .colored,
          "late login callback preserves later display preferences")
}
func event(_ id: AEEventID = AEEventID(0x6f617070)) -> NSAppleEventDescriptor {
    NSAppleEventDescriptor(eventClass: AEEventClass(0x61657674), eventID: id, targetDescriptor: nil, returnID: AEReturnID(-1), transactionID: AETransactionID(0))
}
check(!isLoginLaunchEvent(event: nil), "nil is not a login launch")
check(!isLoginLaunchEvent(event: event()), "normal launch is not hidden")
let loginEvent = event(); loginEvent.setParam(NSAppleEventDescriptor(enumCode: OSType(0x6c676974)), forKeyword: AEKeyword(0x70726474))
check(isLoginLaunchEvent(event: loginEvent), "login launch enum is recognized")
let wrongEvent = event(AEEventID(0x6f646f63)); wrongEvent.setParam(NSAppleEventDescriptor(enumCode: OSType(0x6c676974)), forKeyword: AEKeyword(0x70726474))
check(!isLoginLaunchEvent(event: wrongEvent), "wrong event id is not hidden")
let oldShape = event(); oldShape.setParam(NSAppleEventDescriptor(boolean: true), forKeyword: AEKeyword(0x6c676974))
check(!isLoginLaunchEvent(event: oldShape), "wrong parameter shape is rejected")
let wrongProperty = event(); wrongProperty.setParam(NSAppleEventDescriptor(enumCode: OSType(0x6e6f7065)), forKeyword: AEKeyword(0x70726474))
check(!isLoginLaunchEvent(event: wrongProperty), "wrong property enum is rejected")
print("PASS: \(count) model and launch checks")
