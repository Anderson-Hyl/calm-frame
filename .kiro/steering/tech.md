---
inclusion: always
---
# 技术栈（全部使用 Swift）

## iOS App
- Swift 6，SwiftUI，最低 iOS 17 / iPadOS 17
- `SoundAnalysis` + `AVAudioEngine`（只在内存中分析 buffer，不写文件）
- `StoreKit 2`（消耗型 IAP），`AuthenticationServices`（Sign in with Apple）
- `WidgetKit`（"今日画作"小组件），`CoreHaptics`（呼吸引导）
- 网络层：`URLSession` + async/await，模型来自共享包 `CalmFrameKit`

## 后端
- Vapor 4 + Fluent + PostgreSQL（`fluent-postgres-driver`）
- `JWTKit`（验证 Apple identity token、签发自己的 server JWT）
- `app-store-server-library-swift`（验证 StoreKit 2 交易 JWS、解析 App Store Server Notifications V2）
- `AsyncHTTPClient` 调用 Claude（写 prompt）与图像模型（可插拔 `ImageProvider` 协议）
- 对象存储：S3 兼容（Cloudflare R2 或 AWS S3），用 `Soto` 的 S3 模块
- 部署：Docker（多阶段构建，swift:6.0-jammy → ubuntu:jammy），Fly.io 或 Render

## 约定
- 所有金额/点数用 `Int`，禁止浮点
- 秘密只读环境变量：`ANTHROPIC_API_KEY`、`IMAGE_API_KEY`、`APPLE_*`、`JWT_SECRET`、`S3_*`、`DATABASE_URL`
- 测试：iOS 用 Swift Testing；后端用 `XCTVapor`；关键逻辑（点数账本、mood 分类）加属性测试（swift-testing 参数化 + 随机输入）
- 许可证：MIT
