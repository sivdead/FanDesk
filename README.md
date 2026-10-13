# FanDesk

FanDesk 是一个原生 macOS 双风扇控制应用，使用 SwiftUI、AppKit 和独立的特权后台服务。当前版本为 **0.2.0**，界面为简体中文。

目前以 Mac17,8（Apple M5 Pro 双风扇机型）为实机验证对象。其他机型尚未验证；配置中的 macOS 14 最低版本也尚未在旧系统实测。FanDesk 不依赖 Macs Fan Control 的程序或后台服务。

## 功能

- 两个风扇分别选择系统自动、固定 RPM 或温度曲线；温控可独立绑定传感器。
- 读取 CPU、GPU、电池、电源、触控板、NVMe SSD 等温度，并保留未知 SMC 温度项的原始标识。
- 命名预设的新建、保存、重命名、删除，以及未保存修改提示、丢弃和读取当前控制设置。
- 菜单栏提供单风扇控制、预设切换、全部自动和全部全速入口；可配置温度、RPM、图标及单行或双行显示。
- 登录启动、隐藏启动、启动恢复和唤醒恢复选项。
- 正常退出、客户端连接断开、心跳超时或控制错误时尝试恢复系统自动控制；后台服务在睡眠通知中先交回控制，再确认睡眠。

固定转速受实机上下限约束。温度曲线在起始温度以下使用最低转速，在全速温度以上使用最高转速，中间线性变化。CPU 达到 90°C 或系统报告严重/临界热状态时，正在手动控制的风扇使用硬件最高转速。

## 构建与检查

已验证工具链为 macOS 27.0.1、Xcode Command Line Tools 和 Swift 6.4，使用该版本默认的 Swift Build 引擎。模型检查脚本使用其 `.build/out` 产物布局；旧版 SwiftPM 构建布局尚未适配。

```sh
bash scripts/build.sh
```

脚本构建 release 产物，运行 68 项核心检查与 33 项实际应用模型/启动检查，再生成并校验本地 ad-hoc 签名的 `build/FanDesk.app`。这些自动检查使用模拟硬件和登录服务，不改变实机风扇或系统登录项。没有外部 Swift 包依赖。

只运行已有构建的自动检查：

```sh
swift run -c release --skip-build CoreChecks
bash scripts/model-checks.sh
```

读取实机传感器与风扇状态（只读）：

```sh
swift run -c release FanDeskProbe --snapshot
```

## 本机安装

在准备使用应用的普通用户账户下构建。构建脚本把该用户的 UID 写入应用，后台服务仅接受这个用户运行的已配对应用连接。

首次安装时，将 `build/FanDesk.app` 放入 `/Applications/FanDesk.app` 后打开。点击应用中的“启用风扇控制”，按 macOS 提示在“系统设置 → 通用 → 登录项与扩展”允许 FanDesk 后台运行，并完成系统要求的管理员认证。授权完成后，确认应用显示后台服务已连接，再应用预设。

升级本地签名版本时：

1. 在旧版点击“全部自动”，确认两风扇已回到系统自动控制，然后退出应用。
2. 在系统登录项设置中关闭 FanDesk 后台运行，等旧后台服务停止。
3. 把旧应用移动到备份位置，再复制新应用到 `/Applications/FanDesk.app`，不要覆盖正在运行的程序。
4. 重新允许 FanDesk 后台运行并打开新应用；必要时点击“启用风扇控制”刷新注册。系统可能重新要求管理员确认。

界面和后台服务相互校验签名，修改应用内容或替换版本会改变签名。本版本采用本地签名，未做 Developer ID 签名或公证，不提供通用分发安装包。

预设和偏好保存在 `~/Library/Application Support/FanDesk/presets.json`。退出应用恢复自动控制；是否在下一次启动或唤醒时恢复设置，由应用内选项决定。同时运行 Macs Fan Control 时，FanDesk 会阻止开始控制，以免两个控制器同时写入。

## 验证范围

101 项自动检查已通过，并完成了本机固定 RPM/自动混合、固定 RPM/GPU 温控混合、温度读取、预设持久化和系统登录项注册等验证。真实睡眠/唤醒、真实登录隐藏启动以及部分 V2 生命周期实测尚未完成，具体见 [验收记录](docs/validation.md)。自动检查、界面观察和硬件读回分别记录，不视为相互替代。

## 代码结构

| 路径 | 内容 |
| --- | --- |
| `Sources/FanDesk` | 原生窗口、菜单栏、预设及应用生命周期 |
| `Sources/FanDeskHelper` | 特权 XPC 服务、心跳控制与系统电源通知 |
| `Sources/FanCore` | 数据模型、传感器、控制引擎和签名校验 |
| `Sources/FanStorage` | NVMe SMART 的 IOKit C 接口桥接 |
| `Sources/FanDeskProbe` | 只读硬件探针 |
| `Tests` / `ModelTests` | 核心检查与实际应用模型检查 |

## 第三方来源

`Sources/FanCore/SMC.swift` 基于 [adilkairolla/fan-control](https://github.com/adilkairolla/fan-control) 的 MIT 许可代码修改，来源提交及许可全文位于 [ThirdParty](ThirdParty)。打包时一并保留第三方声明和许可。Macs Fan Control 的应用、补丁、备份及本机原始运行记录不属于此仓库。
