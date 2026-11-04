# Calm Frame

> 把老式相框复活成一个会读空气的相框。Kiroween 2026 · Resurrection

iPhone / iPad 放在工位上，Calm Frame 在**设备端**分析办公室环境声（打字密度、人声、音量、突然安静），判断氛围（忙乱 / 吵闹 / 紧绷的安静 / 犯困），然后在鎏金相框里淡入一幅反向安抚的 19 世纪风景油画或老明信片。**从不录音，也不上传音频**，只有氛围标签会发到服务器。

- 相框模式（常亮）、一句话 caption、带触感的 1 分钟呼吸引导
- 桌面小组件"今日画作"
- 万圣节彩蛋：太吵时小幽灵飘过画面；下班后切成哥特夜景
- 新用户免费送 5 点，之后通过 App 内购买点数

## 技术
全栈 Swift：SwiftUI + SoundAnalysis + StoreKit 2 + WidgetKit；后端 Vapor 4 + Fluent + Postgres，共享包 `CalmFrameKit`。AI：Claude 写画面描述，图像模型可插拔。图片存 R2/S3，Docker 部署到 Fly.io/Render。

## 本地开发

### 前置要求
- macOS 26 / Apple silicon（M1 或更新）
- Xcode 27+
- [Apple `container` CLI](https://github.com/apple/container)：`brew install container`

### 启动本地数据库

```bash
# 一次性初始化（安装 container 后执行一次）
container system start

# 启动 Postgres
./scripts/db-up.sh

# 停止 Postgres（保留数据）
./scripts/db-down.sh

# 停止并删除容器（数据清空）
./scripts/db-down.sh --rm
```

数据库连接信息（与 `Server/.env.example` 默认值一致）：
```
DATABASE_URL=postgres://calmframe:calmframe@localhost:5432/calmframe
```

### 运行服务器

```bash
cd Server
cp .env.example .env          # 填写真实的 API key（本地用 IMAGE_PROVIDER=fake 即可）
swift run App serve           # 自动执行 migration，监听 http://localhost:8080
curl http://localhost:8080/health   # 应返回 {"status":"ok"}
```

### 备用：Docker Compose（非 Apple silicon 或 CI 环境）

```bash
cd Server
docker compose up -d          # 启动 Postgres
docker compose down -v        # 停止并清除数据
```

## 用 Kiro 开发
- `.kiro/specs/calm-frame/`：requirements（EARS）/ design / tasks
- `.kiro/steering/`：product / tech / structure
- `.kiro/hooks/`：隐私守护、密钥扫描、共享模型检查、保存即编译（说明见 `.kiro/hooks.md`）

## 体验
TestFlight 链接与沙盒测试步骤：_待补充_

## License
MIT
