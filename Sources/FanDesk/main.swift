import AppKit
import SwiftUI
import FanCore

// Keep the property-wrapper spelling usable with Command Line Tools SDKs.
private typealias ViewState<Value> = SwiftUI.State<Value>

extension Notification.Name {
    static let fanDeskFocusFan = Notification.Name("FanDesk.focusFan")
}

private func fanName(_ index: Int) -> String { index == 0 ? "左侧风扇" : "右侧风扇" }
private func sensorCategories(_ sensors: [TemperatureReading]) -> [String] {
    let order = ["CPU", "GPU", "电池", "存储", "无线", "电源", "机身", "其它", "其他", "不可用"]
    return Array(Set(sensors.map(\.category))).sorted {
        let first = order.firstIndex(of: $0) ?? order.count
        let second = order.firstIndex(of: $1) ?? order.count
        return first == second ? $0 < $1 : first < second
    }
}
private func temperatureText(_ value: Double?) -> String {
    guard let value, value.isFinite else { return "—" }
    return String(format: "%.1f°C", value)
}
private func sensorName(_ sensor: SensorChoice, in model: DeskModel) -> String {
    model.sensorOptions.first(where: { $0.id == sensor.rawValue })?.name ?? sensor.title
}

private struct SensorPicker: View {
    @ObservedObject var model: DeskModel
    @Binding var selection: SensorChoice
    var label: String
    private var missingSelection: Bool {
        selection != .cpuAverage && selection != .cpuMaximum &&
        !model.sensorOptions.contains(where: { $0.id == selection.rawValue })
    }
    var body: some View {
        Picker(label, selection: $selection) {
            ForEach(sensorCategories(model.sensorOptions), id: \.self) { category in
                Section(category) {
                    ForEach(model.sensorOptions.filter { $0.category == category }, id: \.id) { sensor in
                        Text(sensor.value == nil ? "\(sensor.name)（当前不可用）" : sensor.name)
                            .tag(SensorChoice(rawValue: sensor.id)).disabled(sensor.value == nil)
                    }
                }
            }
            if missingSelection { Text("\(selection.title)（当前不可用）").tag(selection) }
        }
    }
}

private struct FanControlCard: View {
    @ObservedObject var model: DeskModel
    var index: Int
    var focused: Bool
    private var reading: FanReading? { model.snapshot?.fans.first(where: { $0.id == index }) }
    private var mode: FanMode { model.draft.fans[index].mode }
    private var limits: ClosedRange<Double> {
        let minimum = max(0, reading?.minimum ?? 1200)
        return minimum...max(minimum + 1, reading?.maximum ?? 6000)
    }
    private func value<T>(_ path: WritableKeyPath<FanSetting, T>) -> Binding<T> {
        Binding(get: { model.draft.fans[index][keyPath: path] }, set: { newValue in
            var draft = model.draft
            draft.fans[index][keyPath: path] = newValue
            model.draft = draft
        })
    }
    private var rpmSlider: Binding<Double> {
        Binding(get: { min(limits.upperBound, max(limits.lowerBound, model.draft.fans[index].rpm)) },
                set: { value(\.rpm).wrappedValue = $0.rounded() })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .firstTextBaseline) {
                Text(fanName(index)).font(.headline)
                Text(reading.map { String(format: "%.0f RPM", $0.actual) } ?? "— RPM")
                    .font(.title3.monospacedDigit().bold())
                Spacer()
                Text(model.fanStatus(index)).font(.caption).foregroundStyle(.secondary)
            }
            Text(reading.map { String(format: "最低 %.0f · 最高 %.0f · 目标 %.0f RPM", $0.minimum, $0.maximum, $0.target) } ?? "正在读取风扇…")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            HStack {
                Picker("控制方式", selection: Binding(get: { mode }, set: { model.setFanMode(index, $0) })) {
                    Text(FanMode.automatic.title).tag(FanMode.automatic)
                    Text(FanMode.constant.title).tag(FanMode.constant)
                    Text(FanMode.temperature.title).tag(FanMode.temperature)
                }.frame(maxWidth: 310, alignment: .leading)
                    .accessibilityIdentifier("fan-\(index)-mode")
                Spacer()
                Button("应用此风扇") { model.applyFan(index) }
                    .disabled(!model.helperReady || model.competitor || model.controlBusy)
                    .accessibilityIdentifier("fan-\(index)-apply")
            }
            switch mode {
            case .automatic:
                Text("由 macOS 根据负载和温度调节转速。")
                    .font(.callout).foregroundStyle(.secondary)
            case .constant:
                HStack(spacing: 10) {
                    Slider(value: rpmSlider, in: limits, step: 1)
                        .accessibilityLabel("\(fanName(index))固定转速")
                    TextField("固定转速", value: value(\.rpm), format: .number.precision(.fractionLength(0)))
                        .textFieldStyle(.roundedBorder).frame(width: 74)
                        .accessibilityIdentifier("fan-\(index)-rpm")
                    Text("RPM").font(.caption).foregroundStyle(.secondary)
                }
                Text("固定转速须在此风扇的最低与最高转速之间。")
                    .font(.caption).foregroundStyle(.secondary)
            case .temperature:
                SensorPicker(model: model, selection: value(\.sensor), label: "温度来源")
                    .accessibilityIdentifier("fan-\(index)-sensor")
                HStack(spacing: 8) {
                    Text("开始升速").font(.callout)
                    TextField("开始温度", value: value(\.curve.start), format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 54)
                        .accessibilityIdentifier("fan-\(index)-start")
                    Text("°C").foregroundStyle(.secondary)
                    Spacer(minLength: 10)
                    Text("达到最高").font(.callout)
                    TextField("最高转速温度", value: value(\.curve.full), format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 54)
                        .accessibilityIdentifier("fan-\(index)-full")
                    Text("°C").foregroundStyle(.secondary)
                }
                Text("日常变化平滑处理，降速较慢；低温逐步降至最低，上限温度立即全速。范围 25–90°C，间隔至少 5°C。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(focused ? Color.accentColor.opacity(0.65) : .clear, lineWidth: 2))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(fanName(index))控制设置")
    }
}

private struct SensorPanel: View {
    @ObservedObject var model: DeskModel
    @ViewState<String> private var search = ""
    @ViewState<Bool> private var showOther = false
    private var inventory: [TemperatureReading] { model.snapshot?.sensors ?? [] }
    private var filtered: [TemperatureReading] {
        inventory.filter { search.isEmpty || "\($0.name) \($0.id) \($0.category)".localizedCaseInsensitiveContains(search) }
    }
    private var categories: [String] { sensorCategories(filtered) }
    private func readings(_ category: String) -> some View {
        ForEach(filtered.filter { $0.category == category }, id: \.id) { sensor in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(sensor.name).font(.callout)
                    Text(sensor.id).font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 4)
                Text(temperatureText(sensor.value)).font(.callout.monospacedDigit())
                    .foregroundStyle(sensor.value == nil ? .secondary : .primary)
            }
            .accessibilityLabel("\(sensor.name)，\(sensor.value == nil ? "当前不可用" : temperatureText(sensor.value))")
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("温度传感器").font(.headline)
                Spacer()
                Text("\(inventory.count) 项").font(.caption).foregroundStyle(.secondary)
            }
            TextField("搜索名称或传感器编号", text: $search).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("sensor-search")
            HStack {
                Text("CPU 平均 / 最高").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(temperatureText(try? model.snapshot?.temperature(for: .cpuAverage))) / \(temperatureText(try? model.snapshot?.temperature(for: .cpuMaximum)))")
                    .font(.caption.monospacedDigit())
            }
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(categories, id: \.self) { category in
                        if category == "其它" || category == "其他" {
                            DisclosureGroup(isExpanded: Binding(get: { !search.isEmpty || showOther }, set: { showOther = $0 })) {
                                VStack(alignment: .leading, spacing: 7) { readings(category) }.padding(.top, 5)
                            } label: {
                                Text("其它传感器（\(filtered.filter { $0.category == category }.count)）")
                                    .font(.caption.bold()).foregroundStyle(.secondary)
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 7) {
                                Text(category.isEmpty ? "其他" : category).font(.caption.bold()).foregroundStyle(.secondary)
                                readings(category)
                            }
                        }
                    }
                    if filtered.isEmpty {
                        Text(search.isEmpty ? "正在读取传感器…" : "没有匹配的传感器")
                            .font(.callout).foregroundStyle(.secondary).padding(.top, 12)
                    }
                }.padding(.trailing, 3)
            }
            Text("温度随硬件更新；“—”表示当前无法读取。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(14).frame(minWidth: 280, idealWidth: 300, maxWidth: 325, maxHeight: .infinity, alignment: .topLeading)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct Dashboard: View {
    @ObservedObject var model: DeskModel
    var openSettings: () -> Void
    @ViewState<Int?> private var focusedFan: Int? = nil
    private var selectedPreset: Preset? { model.saved.presets.first(where: { $0.id == model.draft.id }) }
    private var selectedIsSaved: Bool { selectedPreset != nil }
    private func loadCurrentControl() {
        if model.hasUnsavedChanges && model.draft != model.active {
            let alert = NSAlert(); alert.messageText = "用当前控制替换编辑中的设置？"
            alert.informativeText = "未保存的编辑会被替换。读取后可以另存为命名预设。"
            alert.addButton(withTitle: "替换"); alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        model.useActiveConfiguration()
    }
    private func deletePreset() {
        guard let selectedPreset else { return }
        let alert = NSAlert()
        alert.messageText = "删除“\(selectedPreset.name)”？"
        alert.informativeText = "此操作会删除已保存的预设。如果此预设正在使用，删除前将恢复系统自动控制。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn { model.deleteSelected() }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "fanblades.fill").font(.system(size: 29)).foregroundStyle(.teal)
                VStack(alignment: .leading, spacing: 3) {
                    Text("FanDesk").font(.title2.bold())
                    Text(model.modeTitle).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("全部自动") { model.automatic() }.disabled(!model.helperReady || model.competitor || model.controlBusy)
                    .accessibilityIdentifier("all-automatic")
                Button("全部全速") { model.fullBlast() }.disabled(!model.helperReady || model.competitor || model.controlBusy)
                    .accessibilityIdentifier("all-full-speed")
                Button(action: openSettings) { Image(systemName: "gearshape") }
                    .help("设置").accessibilityLabel("设置")
            }
            HStack(alignment: .top, spacing: 14) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            GroupBox {
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack {
                                        Picker("预设", selection: Binding(get: { model.draft.id }, set: model.select)) {
                                            ForEach(model.saved.presets) { preset in Text(preset.name).tag(preset.id) }
                                            if !selectedIsSaved { Text("自定义（未保存）").tag(model.draft.id) }
                                        }.accessibilityIdentifier("preset-selection")
                                        Spacer()
                                        if model.hasUnsavedChanges {
                                            Label("未保存", systemImage: "circle.fill").font(.caption).foregroundStyle(.orange)
                                        } else { Text("已保存").font(.caption).foregroundStyle(.secondary) }
                                    }
                                    HStack {
                                        Text("名称").font(.callout)
                                        TextField("预设名称", text: $model.draft.name).textFieldStyle(.roundedBorder)
                                            .accessibilityIdentifier("preset-name")
                                    }
                                    HStack(spacing: 8) {
                                        Button("另存为新预设") { model.save(asNew: true) }
                                        Button("保存") { model.save(asNew: false) }
                                            .accessibilityIdentifier("preset-save")
                                        Button("删除", role: .destructive, action: deletePreset).disabled(!selectedIsSaved || model.controlBusy)
                                            .accessibilityIdentifier("preset-delete")
                                        Spacer()
                                        Button("丢弃修改") { model.discardChanges() }.disabled(!model.hasUnsavedChanges || model.controlBusy)
                                            .help("丢弃未保存的修改并恢复系统自动控制")
                                            .accessibilityIdentifier("preset-discard")
                                    }
                                    HStack {
                                        Button("读取当前控制", action: loadCurrentControl).disabled(model.active == nil || model.controlBusy)
                                            .accessibilityIdentifier("preset-read-current")
                                        Text("编辑后应用才会改变风扇；保存可长期保留设置。")
                                            .font(.caption).foregroundStyle(.secondary)
                                        Spacer()
                                        Button("应用预设") { model.apply() }.buttonStyle(.borderedProminent)
                                            .disabled(!model.helperReady || model.competitor || model.controlBusy)
                                            .accessibilityIdentifier("preset-apply")
                                    }
                                }.padding(5)
                            }.disabled(model.controlBusy)
                            ForEach(Array(model.draft.fans.indices.prefix(2)), id: \.self) { index in
                                FanControlCard(model: model, index: index, focused: focusedFan == index).id(index)
                                    .disabled(model.controlBusy)
                            }
                        }.padding(.trailing, 3)
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .fanDeskFocusFan)) { notification in
                        focusedFan = notification.object as? Int
                        if let focusedFan { withAnimation { proxy.scrollTo(focusedFan, anchor: .center) } }
                    }
                }.frame(minWidth: 515, maxWidth: .infinity)
                SensorPanel(model: model)
            }
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: model.helperReady ? "checkmark.shield" : "info.circle").foregroundStyle(.secondary)
                Text(model.notice).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                if !model.helperReady {
                    Button(model.needsApproval ? "打开系统设置" : "启用风扇控制") { model.enableHelper() }
                        .disabled(model.competitor || model.controlBusy)
                }
            }.frame(minHeight: 35)
            Text("关闭窗口后留在菜单栏；退出时恢复系统自动控制。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(minWidth: 880, minHeight: 630)
    }
}

private struct SettingsView: View {
    @ObservedObject var model: DeskModel
    private func preference<T>(_ path: WritableKeyPath<DeskPreferences, T>) -> Binding<T> {
        Binding(get: { model.saved.preferences[keyPath: path] }, set: { newValue in
            var preferences = model.saved.preferences
            preferences[keyPath: path] = newValue
            model.updatePreferences(preferences)
        })
    }
    var body: some View {
        Form {
            Section("菜单栏") {
                SensorPicker(model: model, selection: preference(\.menuSensor), label: "显示温度")
                    .accessibilityIdentifier("menu-sensor")
                Picker("显示转速", selection: preference(\.menuFan)) {
                    Text("不显示").tag(Optional<Int>.none)
                    Text("左侧风扇").tag(Optional(0))
                    Text("右侧风扇").tag(Optional(1))
                }.accessibilityIdentifier("menu-fan")
                Picker("图标", selection: preference(\.menuIcon)) {
                    Text("单色").tag(MenuIcon.monochrome)
                    Text("彩色").tag(MenuIcon.colored)
                    Text("不显示").tag(MenuIcon.none)
                }.accessibilityIdentifier("menu-icon")
                Toggle("双行显示温度和转速", isOn: preference(\.menuTwoLines))
                    .disabled(model.saved.preferences.menuFan == nil)
                    .accessibilityIdentifier("menu-two-lines")
            }
            Section("启动与唤醒") {
                Toggle("登录时自动启动", isOn: preference(\.launchAtLogin))
                    .disabled(model.loginBusy)
                    .accessibilityIdentifier("launch-at-login")
                Text(model.loginStatus).font(.caption).foregroundStyle(.secondary)
                Toggle("登录时隐藏主窗口", isOn: preference(\.startHidden))
                    .disabled(!model.saved.preferences.launchAtLogin)
                Toggle("启动后恢复上次应用的风扇设置", isOn: preference(\.restoreOnLaunch))
                    .accessibilityIdentifier("restore-on-launch")
                Toggle("唤醒后恢复睡眠前的风扇设置", isOn: preference(\.restoreAfterWake))
                    .accessibilityIdentifier("restore-after-wake")
                Text("恢复功能仅应用本机仍可用的设置；风扇控制需要已启用后台服务。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text(model.notice).font(.callout).textSelection(.enabled)
                Text("设置更改会自动保存。").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).padding(10).frame(width: 480, height: 480)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    var model: DeskModel!
    var window: NSWindow!
    var settingsWindow: NSWindow?
    var status: NSStatusItem!
    private var controlMenu: NSMenu?
    var terminating = false
    private var launchedAtLogin = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let other = NSRunningApplication.runningApplications(withBundleIdentifier: DeskPaths.appID).first(where: { $0.processIdentifier != getpid() }) {
            other.activate(); NSApp.terminate(nil); return
        }
        launchedAtLogin = launchedAtLogin || isLoginItemLaunch
        model = DeskModel()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 930, height: 730),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "FanDesk"
        window.contentView = NSHostingView(rootView: Dashboard(model: model, openSettings: { [weak self] in self?.showSettings() }))
        window.contentMinSize = NSSize(width: 880, height: 630)
        window.isReleasedWhenClosed = false; window.delegate = self; window.center()
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self; menu.autoenablesItems = false
        status.menu = menu
        installMainMenu()
        model.changed = { [weak self] in self?.updateStatus() }
        updateStatus()
        if !ProcessInfo.processInfo.arguments.contains("--minimized") && !(launchedAtLogin && model.saved.preferences.startHidden) {
            showWindow()
        }
    }

    private var isLoginItemLaunch: Bool {
        isLoginLaunchEvent(event: NSAppleEventManager.shared().currentAppleEvent)
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        launchedAtLogin = isLoginItemLaunch
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem(); let appMenu = NSMenu()
        appMenu.addItem(withTitle: "显示 FanDesk", action: #selector(showWindow), keyEquivalent: "0").target = self
        appMenu.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 FanDesk", action: #selector(quit), keyEquivalent: "q").target = self
        appMenuItem.submenu = appMenu; mainMenu.addItem(appMenuItem)
        let controlItem = NSMenuItem(); controlItem.title = "控制"
        let controls = NSMenu(title: "控制"); controls.delegate = self; controls.autoenablesItems = false
        controlItem.submenu = controls; mainMenu.addItem(controlItem); controlMenu = controls
        let editItem = NSMenuItem(); editItem.title = "编辑"
        let edit = NSMenu(title: "编辑")
        for (title, selector, key) in [("撤销", Selector(("undo:")), "z"), ("剪切", #selector(NSText.cut(_:)), "x"), ("复制", #selector(NSText.copy(_:)), "c"), ("粘贴", #selector(NSText.paste(_:)), "v"), ("全选", #selector(NSText.selectAll(_:)), "a")] {
            edit.addItem(withTitle: title, action: selector, keyEquivalent: key)
        }
        editItem.submenu = edit; mainMenu.addItem(editItem); NSApp.mainMenu = mainMenu
    }

    private func selectedTemperature() -> Double? {
        guard let snapshot = model.snapshot else { return nil }
        return try? snapshot.temperature(for: model.saved.preferences.menuSensor)
    }

    private func updateStatus() {
        guard let button = status?.button else { return }
        let preferences = model.saved.preferences
        let temperature = selectedTemperature()
        let temperatureLabel = temperature.map { String(format: "%.0f°", $0) } ?? "—°"
        var rpmLabel: String?
        if let index = preferences.menuFan {
            rpmLabel = model.snapshot?.fans.first(where: { $0.id == index }).map { String(format: "%.0f RPM", $0.actual) } ?? "— RPM"
        }
        if preferences.menuIcon == .none { button.image = nil }
        else {
            let icon = NSImage(systemSymbolName: "fanblades.fill", accessibilityDescription: "FanDesk")
            icon?.isTemplate = preferences.menuIcon == .monochrome
            button.image = icon
            button.contentTintColor = preferences.menuIcon == .colored ? .systemTeal : nil
        }
        let text: String
        if let rpmLabel { text = preferences.menuTwoLines ? "\(temperatureLabel)\n\(rpmLabel)" : "\(temperatureLabel) · \(rpmLabel)" }
        else { text = temperatureLabel }
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
        let twoLines = preferences.menuTwoLines && rpmLabel != nil
        button.attributedTitle = NSAttributedString(string: (button.image == nil ? "" : " ") + text,
                                                    attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: twoLines ? 9 : 12, weight: .regular), .paragraphStyle: paragraph])
        button.imagePosition = .imageLeading
        button.toolTip = "\(model.modeTitle)\n\(sensorName(preferences.menuSensor, in: model))：\(temperatureText(temperature))"
        button.setAccessibilityLabel("FanDesk，\(model.modeTitle)，\(text.replacingOccurrences(of: "\n", with: "，"))")
    }

    @discardableResult
    private func addItem(_ menu: NSMenu, title: String, action: Selector? = nil, enabled: Bool = true, representedObject: Any? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self; item.isEnabled = enabled; item.representedObject = representedObject
        menu.addItem(item)
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === status.menu || menu === controlMenu else { return }
        menu.removeAllItems()
        addItem(menu, title: model.modeTitle, enabled: false)
        let canControl = model.helperReady && !model.competitor && !model.controlBusy
        for index in 0..<2 {
            let rpm = model.snapshot?.fans.first(where: { $0.id == index }).map { String(format: "%.0f RPM", $0.actual) } ?? "— RPM"
            let fan = addItem(menu, title: "\(fanName(index)) · \(rpm) · \(model.fanStatus(index))")
            let submenu = NSMenu(title: fanName(index)); submenu.autoenablesItems = false
            let activeMode: FanMode?
            if let active = model.active, active.fans.indices.contains(index) { activeMode = active.fans[index].mode }
            else if model.snapshot?.fans.first(where: { $0.id == index })?.mode == 0 { activeMode = .automatic }
            else { activeMode = nil }
            for (mode, title, action) in [(FanMode.automatic, "系统自动", #selector(menuFanAutomatic(_:))),
                                         (FanMode.constant, "固定转速…", #selector(menuFanConstant(_:))),
                                         (FanMode.temperature, "温度控制…", #selector(menuFanTemperature(_:)))] {
                let item = addItem(submenu, title: title, action: action, enabled: mode == .automatic ? canControl : true, representedObject: index)
                item.state = activeMode == mode ? .on : .off
            }
            fan.submenu = submenu
        }
        menu.addItem(.separator())
        let automaticItem = addItem(menu, title: "全部系统自动", action: #selector(automatic), enabled: canControl)
        automaticItem.state = model.active == nil && model.snapshot?.fans.allSatisfy({ $0.mode == 0 }) == true ? .on : .off
        addItem(menu, title: "全部全速", action: #selector(fullBlast), enabled: canControl)
        let presetsItem = addItem(menu, title: "已存预设")
        let presets = NSMenu(title: "已存预设"); presets.autoenablesItems = false
        for preset in model.saved.presets {
            let item = addItem(presets, title: preset.name, action: #selector(menuPreset(_:)), enabled: canControl, representedObject: preset.id.uuidString)
            item.state = model.active == preset ? .on : .off
        }
        if model.saved.presets.isEmpty { addItem(presets, title: "尚无已存预设", enabled: false) }
        presets.addItem(.separator())
        addItem(presets, title: "管理预设…", action: #selector(showWindow))
        presetsItem.submenu = presets
        menu.addItem(.separator())
        addItem(menu, title: "打开 FanDesk", action: #selector(showWindow))
        addItem(menu, title: "设置…", action: #selector(showSettings))
        menu.addItem(.separator())
        let quitItem = addItem(menu, title: "退出 FanDesk", action: #selector(quit)); quitItem.keyEquivalent = "q"
    }

    func applicationDidBecomeActive(_ notification: Notification) { model?.syncLoginStatus() }
    @objc func showWindow() {
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
    @objc func showSettings() {
        if settingsWindow == nil {
            let settings = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 480),
                                    styleMask: [.titled, .closable], backing: .buffered, defer: false)
            settings.title = "FanDesk 设置"
            settings.contentView = NSHostingView(rootView: SettingsView(model: model))
            settings.isReleasedWhenClosed = false; settings.delegate = self; settings.center()
            settingsWindow = settings
        }
        NSApp.setActivationPolicy(.regular)
        settingsWindow?.makeKeyAndOrderFront(nil); NSApp.activate()
    }
    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow else { return }
        let hasOtherWindow = [window, settingsWindow].compactMap { $0 }.contains {
            $0 !== closingWindow && ($0.isVisible || $0.isMiniaturized)
        }
        if !hasOtherWindow { NSApp.setActivationPolicy(.accessory) }
    }
    @objc func automatic() { model?.automatic() }
    @objc func fullBlast() { model?.fullBlast() }
    @objc func menuFanAutomatic(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int else { return }
        model.setFanMode(index, .automatic); model.applyFan(index)
    }
    private func editFan(_ sender: NSMenuItem, mode: FanMode) {
        guard let index = sender.representedObject as? Int else { return }
        model.setFanMode(index, mode); showWindow()
        NotificationCenter.default.post(name: .fanDeskFocusFan, object: index)
    }
    @objc func menuFanConstant(_ sender: NSMenuItem) { editFan(sender, mode: .constant) }
    @objc func menuFanTemperature(_ sender: NSMenuItem) { editFan(sender, mode: .temperature) }
    @objc func menuPreset(_ sender: NSMenuItem) {
        guard let string = sender.representedObject as? String, let id = UUID(uuidString: string) else { return }
        model.applySaved(id)
    }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, !terminating else { return .terminateNow }
        terminating = true
        model.shutdown { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
