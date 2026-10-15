# 开发指南

## 环境

- macOS 与 Xcode Command Line Tools。
- Swift 6.4，使用默认的 Swift Build 引擎。
- 没有外部 Swift 包依赖。

当前模型检查脚本使用 Swift 6.4 的 `.build/out` 产物布局。旧版 SwiftPM 的目录结构尚未适配。

## 构建和检查

```sh
bash scripts/build.sh
```

脚本构建 release 产物、运行核心和应用模型检查，生成本地签名的 `build/FanDesk.app`，并校验嵌套签名。自动检查使用模拟硬件和登录服务，不改变实机风扇或系统登录项。

已有构建时可以单独运行：

```sh
swift run -c release --skip-build CoreChecks
bash scripts/model-checks.sh
```

读取实际硬件状态，仅执行读取：

```sh
swift run -c release FanDeskProbe --snapshot
```

## 打包

```sh
bash scripts/package.sh
```

输出目录为 `build/release`，包含 DMG 与 `SHA256SUMS.txt`。脚本会验证应用签名和 arm64 架构，把应用、Applications 快捷方式和安装说明放入只读压缩磁盘映像，再校验映像完整性。

发布前应挂载磁盘映像，检查内含应用签名、版本与校验和。源码提交、Git 标签和 Release 安装包必须对应同一份构建。

## 正式签名与公证

`build.sh` 和 `package.sh` 默认生成本地签名包，使用 `docs/install.txt`。正式发布包需要开发者自己的 Developer ID Application 证书和钥匙串中的公证凭据；私钥和密码均不放入仓库。

正式分发时，先为后台服务、再为主应用签名，启用 Hardened Runtime 并添加安全时间戳。提交应用 ZIP 至 Apple，确认 Accepted 且日志无错误后，为应用附加并验证公证凭证。将已附凭证的应用、Applications 快捷方式、MIT 许可证及 [公证包安装说明](install-notarized.txt) 制作成独立 DMG，正式签名后再提交磁盘映像公证。确认 Accepted 后为映像附加凭证，完成 Gatekeeper、`syspolicy_check`、只读挂载和校验和检查，再生成最终下载校验文件。

0.2.2 公证包使用与原始发布相同的程序代码；差异为正式签名、运行保护、时间戳和公证凭证，安装说明也相应更新。原始资产和 `v0.2.2` 标签保留，公证包使用 `-notarized.dmg` 后缀及独立校验文件。Apple 的完整流程见 [自定义公证工作流](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)。

## 代码结构

| 路径 | 职责 |
| --- | --- |
| `Sources/FanDesk` | SwiftUI 主窗口、AppKit 菜单栏、预设、应用生命周期 |
| `Sources/FanDeskHelper` | 特权 XPC 服务、控制循环、电源通知 |
| `Sources/FanCore` | 控制引擎、会话权限、数据模型、传感器、签名校验 |
| `Sources/FanStorage` | NVMe SMART 的 IOKit C 接口桥接 |
| `Sources/FanDeskProbe` | 只读硬件探针 |
| `Tests` | 核心逻辑与故障路径检查 |
| `ModelTests` | 实际应用模型、异步行为和启动事件检查 |

## 控制边界

后台只接受当前活动控制台用户和签名匹配的应用连接。连接身份与用户身份共同标识控制者；请求和定时循环均检查用户切换。失联超过 5 秒、控制失败、活动用户变化或睡眠时，后台尝试恢复系统自动控制，恢复失败会继续重试。

CPU 达到 90°C 或系统热状态为 serious/critical 时，当前处于手动控制的风扇使用硬件最高转速。已选择的温度来源失效会结束手动控制。

从 0.2.2 起，温度控制采用 4 秒时间常数的指数平滑；正常目标转速每秒最多上升 300 RPM、下降 75 RPM。两个风扇分别维护输入与输出状态，以单调时钟的实际间隔计算，额外的状态查询、心跳和重复应用不会增加调速额度。系统自动和固定转速模式保持各自的原有行为。

首次接手温控从当前转速开始；手动状态也考虑正在生效的硬件目标，自动状态则忽略可能残留的旧手动目标。更换传感器或曲线会重置温度滤波，保留转速衔接；退出控制、故障恢复和睡眠归还系统后清空状态。原始选中温度达到曲线上限，或原始 CPU 最高温度/系统热状态触发保护时，立即全速；保护解除后从最高转速缓慢下降。

涉及后台权限、恢复行为或风扇写入的修改，需要对应故障路径检查。请勿仅以成功编译或 XPC 请求成功代替硬件读回；真实验证进度见 [验证记录](validation.md)。
