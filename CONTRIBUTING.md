# 参与贡献

欢迎提交 Bug、功能建议、机型兼容性反馈和 Pull Request。

## 报告问题

请在 [Issues](https://github.com/sivdead/FanDesk/issues) 中提供：

- Mac 型号或 Model Identifier、芯片和 macOS 版本。
- FanDesk 版本、安装方式以及是否运行其他风扇控制软件。
- 复现步骤、预期行为、实际行为，以及相关截图或错误提示。

硬件兼容性问题可附上 `FanDeskProbe --snapshot` 的只读输出。提交前检查附件，移除不相关的个人信息。

## 提交代码

先阅读 [开发指南](docs/development.md)。保持修改范围清楚，说明解决的问题；涉及控制、权限或异步恢复时补充对应检查，并运行：

```sh
bash scripts/build.sh
git diff --check
```

在 Pull Request 中注明自动检查结果、实测硬件和未验证范围。新增机型支持时提供传感器与风扇范围的实际读回，避免把一个机型的映射直接推广到所有机型。
