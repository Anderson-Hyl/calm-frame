---
inclusion: always
---
# 仓库结构

```
calm-frame/
├── .kiro/                  # 不得加入 .gitignore（参赛要求）
├── LICENSE                 # MIT
├── README.md
├── Packages/
│   └── CalmFrameKit/       # 共享 Swift 包：DTO、Mood、Style、API 路由常量
│       └── Sources/CalmFrameKit/
├── App/                    # Xcode 工程
│   ├── CalmFrame/          # 主 App
│   │   ├── Listening/      # AmbienceListener, MoodClassifier
│   │   ├── Frame/          # FrameView, GildedFrame, GhostOverlay
│   │   ├── Breathing/
│   │   ├── Store/          # StoreKit 2, CreditsStore
│   │   └── Networking/     # APIClient
│   └── CalmFrameWidget/    # WidgetKit 扩展
├── Server/                 # Vapor 工程
│   ├── Sources/App/
│   │   ├── Controllers/    # Auth, Credits, Paintings, AppStoreNotifications
│   │   ├── Models/         # Fluent 模型
│   │   ├── Migrations/
│   │   ├── Services/       # Ledger, PromptWriter, ImageProvider, ImageCache, Storage
│   │   └── Middleware/     # JWTAuth, RateLimit
│   ├── Tests/AppTests/
│   └── Dockerfile
└── docs/                   # Kiro 使用说明、演示脚本
```

规则：App 与 Server 之间传递的类型只能定义在 `CalmFrameKit`，不得在两边各写一份。
