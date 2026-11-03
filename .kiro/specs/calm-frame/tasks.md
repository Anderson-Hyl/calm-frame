# 实施计划：Calm Frame

截止：**北京时间 2026-12-05 06:00**（目标 12-03 晚提交，留 1 天缓冲）

## 里程碑
| 周 | 日期（北京时间） | 目标 |
|---|---|---|
| W1 | 11-04 → 11-10 | 骨架：共享包、Vapor 跑通、登录、聆听+分类器 |
| W2 | 11-11 → 11-17 | 生成链路：账本、Claude+图像、缓存、R2；相框 UI |
| W3 | 11-18 → 11-24 | 付费：StoreKit 2、交易验证、退款通知；小组件、呼吸、彩蛋 |
| W4 | 11-25 → 12-03 | 部署、TestFlight、打磨、视频、写 Kiro 使用说明、提交 |

## 任务

### W1
- [ ] 1. 仓库初始化：MIT LICENSE、README、`.gitignore`（确认不含 `.kiro`）
- [ ] 2. 创建 `Packages/CalmFrameKit`，定义 Mood/Style/DTO（需求 2、7）
- [ ] 3. Vapor 工程：`/health`、Postgres 连接、Fluent 迁移 `users` `ledger_entries`（需求 7）
  - [ ] 3.1 本地 `docker compose` 起 Postgres
- [ ] 4. `POST /v1/auth/apple`：验证 identity token、建号、发 5 点、签 JWT；`JWTAuthMiddleware`（需求 7.1）
- [ ] 5. iOS：`AmbienceListener` + `SoundAnalysis`，只内存处理（需求 1.2、1.3）
- [ ] 6. `MoodClassifier` 纯函数 + 属性测试（需求 1.4）
- [ ] 7. 调试页：实时显示特征与 mood、手动 mood 模式（需求 1.5）

### W2
- [ ] 8. `LedgerService`：事务扣点、幂等 refID、余额查询 + 属性测试（需求 2.3、2.4）
- [ ] 9. `PromptWriter` 协议 + `ClaudePromptWriter`（需求 2.3）
- [ ] 10. `ImageProvider` 协议 + 一个真实实现 + `FakeImageProvider`（需求 2.3）
- [ ] 11. `StorageService`（Soto S3 → R2），`ImageCache` 变体策略（需求 2.2）
- [ ] 12. `POST /v1/paintings` 串起全流程，失败退点，`ai_costs` 记账（需求 2、8.1）
- [ ] 13. `RateLimitMiddleware`（需求 8.2）
- [ ] 14. iOS：`APIClient`、`FrameView` crossfade、`GildedFrame` 铭牌、相框模式常亮（需求 3）
- [ ] 15. 内置离线画作（需求 2.5）

### W3
- [ ] 16. App Store Connect 建消耗型商品 `credits.10` / `credits.50`，StoreKit 配置文件用于本地测试
- [ ] 17. iOS `CreditsStore`：购买、`appAccountToken`、补发未完成交易（需求 7.2、7.5）
- [ ] 18. `POST /v1/credits/redeem`：`SignedDataVerifier` 验证、`purchases` 幂等（需求 7.3）
- [ ] 19. `POST /v1/appstore/notifications`：REFUND / REFUND_REVERSED（需求 7.4）
- [ ] 20. 小组件"今日画作" + `GET /v1/paintings/latest`（需求 5）
- [ ] 21. 呼吸引导 + CoreHaptics（需求 4）
- [ ] 22. 彩蛋：`GhostOverlay`、下班后 `gothicNight`（需求 6）

### W4
- [ ] 23. Dockerfile + Fly.io/Render 部署，配置 secrets，ASSN 回调 URL 填到 App Store Connect（需求 8.3）
- [ ] 24. TestFlight 外部测试公开链接；README 写沙盒账号与体验步骤（需求 9.2）
- [ ] 25. 预热缓存：每个 mood×style 先生成 2 个变体，保证评委首次体验快
- [ ] 26. 隐私测试 + 端到端走查
- [ ] 27. 录制并剪辑 3 分钟视频，上传 YouTube 公开（需求 9.3）
- [ ] 28. `docs/kiro-usage.md`：spec / steering / hooks 截图与说明；Devpost 提交

## 演示视频大纲（≤ 3:00）
| 时间 | 画面 | 旁白要点 |
|---|---|---|
| 0:00–0:15 | 老相框特写 → iPad 上的鎏金相框 | "200 年来相框只会挂着。我们让它学会读空气。" |
| 0:15–0:45 | 办公室忙乱（键盘、讨论），铭牌变成"房间：忙乱"，画面淡入静水湖 | 设备端 SoundAnalysis，只有 mood 标签离开手机 |
| 0:45–1:10 | 突然安静 → 开阔天空；下午犯困 → 阳光窗台 | 四种 mood 与反向安抚 |
| 1:10–1:30 | 点画面 → 呼吸引导，手机触感特写 | |
| 1:30–1:50 | 有人大笑，小幽灵飘过；切到 19:00 后哥特夜景 | 万圣节彩蛋 |
| 1:50–2:10 | 首次登录送 5 点 → 购买 10 点（沙盒）→ 小组件 | StoreKit 2 + 后端验证 |
| 2:10–2:50 | 屏幕录制 Kiro：spec 三件套、steering、hook 自动拦截"写音频文件"的代码 | 讲 Kiro 如何驱动开发 |
| 2:50–3:00 | 相框静静切换 + 仓库/TestFlight 链接 | |
