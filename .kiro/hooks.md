# Hook 建议

Kiro hook 文件格式（已按 https://kiro.dev/docs/hooks/ 核对，2026-11）：`.kiro/hooks/<name>.json`，`{"version":"v1","hooks":[{name, trigger(PascalCase), matcher(正则), action:{type:"command"|"agent", command|prompt}, timeout?}]}`。命令通过 STDIN 收到 JSON 上下文。触发器以官方 Hook types 页面为准。

已落地为 JSON 的（见 `.kiro/hooks/`）：

| 文件 | 触发 | 作用 |
|---|---|---|
| `privacy-guard.json` | `PostFileSave` on `App/.*\.swift$` | 搜 `AVAudioFile`、`AVAudioRecorder`、`write(to:` 等，出现即让 agent 解释或移除（守护"永不录音"） |
| `shared-models.json` | `PostFileSave` on `(App|Server)/.*\.swift$` | agent 检查是否在 App/Server 里重复定义了应放在 `CalmFrameKit` 的 DTO |
| `server-build.json` | `PostFileSave` on `Server/Sources/.*\.swift$` | 运行 `swift build`（Server 目录），快速反馈编译错误 |
| `no-secrets.json` | `PostFileSave` on `App/.*` | grep `sk-ant-`、`ANTHROPIC_API_KEY` 等，防止密钥进 app |

更多可选想法：
- `Stop` 时运行 `swift test`（Server + CalmFrameKit），用 `confirm` 询问是否运行
- 修改 `Migrations/` 时，agent 提醒同步更新 design.md 的数据模型表
- 新增 `Mood` case 时，agent 检查 `MoodClassifier`、内置离线画、Claude system prompt 是否都覆盖
- 修改 `ledger` 相关代码时，强制运行账本属性测试
