# 需求文档：Calm Frame

## 简介
Calm Frame 是一个 iOS/iPadOS app：在设备端分析办公室环境声，判断氛围（mood），由后端生成一幅风格复古、与当前氛围"反着来"的安抚画作，展示在屏幕上的鎏金相框里。用户购买消耗型点数来生成画作。

## 术语
- **Mood**：`hectic` / `noisy` / `tenseQuiet` / `drowsy` / `calm`（calm 时不生成新画）
- **Style**：`oilPainting1800s` / `oldPostcard` / `gothicNight`
- **Credit**：生成一幅新画消耗 1 点；命中缓存消耗 0 点

## 需求 1：设备端氛围聆听
**用户故事：** 作为办公室员工，我希望 app 在不录音的前提下感知周围氛围，这样我能安心把它放在工位上。

验收标准：
1. WHEN 用户首次开启聆听 THEN 系统 SHALL 说明"只在设备端分析、不录音、不上传"并请求麦克风权限
2. WHILE 聆听开启 THE 系统 SHALL 每 N 分钟（默认 5，可选 3/5/10）采样 30 秒并用 `SoundAnalysis` 计算特征：打字密度、人声比例、平均音量（dBFS）、相对上一窗口的安静突变
3. THE 系统 SHALL NOT 将音频 buffer 写入磁盘或通过网络发送
4. WHEN 一个采样窗口结束 THEN 系统 SHALL 将特征映射为一个 Mood，并记录置信度
5. IF 麦克风权限被拒绝 THEN 系统 SHALL 提供手动选择 Mood 的模式

## 需求 2：反向安抚画作生成
**用户故事：** 作为用户，我希望看到一幅能让我平静下来的画，与当下氛围相反。

验收标准：
1. WHEN Mood 发生变化且持续 ≥ 2 个窗口 THEN app SHALL 向后端请求 `POST /v1/paintings`，只携带 `mood`、`style`、`locale`
2. WHEN 后端收到请求 THEN 系统 SHALL 先查缓存；IF 缓存命中 THEN 返回缓存图片且不扣点
3. IF 缓存未命中 THEN 系统 SHALL 先扣 1 点，再调用 Claude 生成画面描述与一句话 caption，再调用图像模型出图
4. IF 生成任一步失败 THEN 系统 SHALL 退还该点数并返回可重试的错误
5. WHEN 用户余额为 0 THEN 系统 SHALL 返回 `402` 并在 app 中只使用缓存画作/本地内置画作

## 需求 3：相框模式
**用户故事：** 作为用户，我希望 iPad 或旧 iPhone 常亮显示画作，像一个真的相框。

验收标准：
1. WHILE 相框模式开启 THE app SHALL 禁止自动锁屏（`isIdleTimerDisabled`）并隐藏所有控件
2. WHEN 新画到达 THEN app SHALL 用 ≥ 3 秒的 crossfade 替换旧画
3. THE 画面 SHALL 包在 SwiftUI 绘制的鎏金相框中，下方铭牌显示"房间：<mood> · 正在展示：<title>"
4. WHERE 用户开启 caption THE app SHALL 在铭牌下显示一句话

## 需求 4：呼吸引导
1. WHEN 用户点击画面 THEN app SHALL 提供 1 分钟呼吸引导（吸 4 秒、停 4 秒、呼 6 秒）
2. WHERE 设备支持 CoreHaptics THE app SHALL 用渐强/渐弱触感配合节奏

## 需求 5：小组件
1. THE 系统 SHALL 提供"今日画作"小组件（small/medium/large），显示最近一幅画与 mood
2. WHEN 新画生成 THEN app SHALL 调用 `WidgetCenter.reloadAllTimelines()`

## 需求 6：万圣节彩蛋
1. WHEN 音量连续 2 个窗口超过"很吵"阈值 THEN app SHALL 让一只小幽灵在 8–12 秒内飘过画面（本地 SwiftUI 动画，不消耗点数）
2. WHEN 本地时间晚于下班时间（默认 19:00，可配置）THEN 请求的 style SHALL 自动切换为 `gothicNight`

## 需求 7：登录与点数
**用户故事：** 作为评委，我希望打开就能试，不必先付钱。

验收标准：
1. WHEN 用户首次使用 Sign in with Apple THEN 后端 SHALL 验证 Apple identity token，创建账户，发放 5 点 starter credits，并返回 server JWT
2. WHEN 用户通过 StoreKit 2 购买消耗型商品 THEN app SHALL 将 `jwsRepresentation` 发给 `POST /v1/credits/redeem`
3. WHEN 后端收到交易 THEN 系统 SHALL 用 `app-store-server-library-swift` 验证签名；IF 该 `transactionId` 已处理过 THEN 系统 SHALL 幂等返回当前余额
4. WHEN 收到 App Store Server Notification V2 类型 `REFUND` THEN 系统 SHALL 扣回对应点数（余额可为负，负数时禁止生成）
5. THE 系统 SHALL 只在后端验证成功后调用 `transaction.finish()`

## 需求 8：成本与风控
1. THE 后端 SHALL 为每次 AI 调用记录成本账本（provider、model、估算美分成本、关联用户）
2. THE 后端 SHALL 对 `POST /v1/paintings` 做每用户速率限制（默认 每分钟 2 次、每天 50 次），超限返回 `429`
3. THE AI API key SHALL 只存在于服务器环境变量

## 需求 9：参赛交付
1. 仓库公开，带 MIT LICENSE，根目录 `.kiro/` 不被忽略
2. TestFlight 公开链接 + 沙盒账号说明可让评委体验
3. 3 分钟内 YouTube 演示视频与 Kiro 使用说明
