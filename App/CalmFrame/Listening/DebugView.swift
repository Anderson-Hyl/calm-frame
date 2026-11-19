import CalmFrameKit
import SwiftUI

/// 调试图（tasks.md 任务 7，需求 1.5）：实时显示特征与 mood、手动 mood 模式。
/// 入口：相框页右上角“调试”；启动参数 `--debug` 可直接进本页（用于截图验证）。
struct DebugView: View {
    @Bindable var viewModel: ListeningViewModel
    @Bindable var frameViewModel: FrameViewModel
    @Bindable var authViewModel: AuthViewModel
    @Bindable var storeViewModel: StoreViewModel

    var body: some View {
        List {
            statusSection
            authSection
            storeSection
            currentWindowSection
            samplingSection
            modeSection
            frameSection
            recentWindowsSection
        }
        .navigationTitle("聆听调试")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $viewModel.isExplainerPresented) {
            PermissionExplainerView(
                onConfirm: { viewModel.explainerConfirmed() },
                onCancel: { viewModel.isExplainerPresented = false }
            )
        }
    }

    // MARK: - 状态

    private var statusSection: some View {
        Section("状态") {
            HStack {
                Text("麦克风权限")
                Spacer()
                Text(permissionText).foregroundStyle(.secondary)
            }
            HStack {
                Text("聆听")
                Spacer()
                Text(stateText).foregroundStyle(.secondary)
            }
            if let error = viewModel.errorMessage {
                Text(error).foregroundStyle(.red)
            }
            if viewModel.permission == .denied {
                Button("在设置中开启麦克风") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            }
            if viewModel.permission == .unavailable {
                Text("这台设备没有可用麦克风（模拟器），只能用手动模式。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var permissionText: String {
        switch viewModel.permission {
        case .unknown: return "未请求"
        case .granted: return "已允许"
        case .denied: return "已拒绝"
        case .unavailable: return "无麦克风"
        }
    }

    private var stateText: String {
        switch viewModel.state {
        case .idle: return "未开始"
        case .listening: return "聆听中"
        case .denied: return "权限被拒"
        case .unavailable: return "无麦克风"
        case .error(let message): return "出错：\(message)"
        }
    }

    // MARK: - 账户（Auth 切片）

    /// 登录入口与状态。用普通 Button 走 AuthViewModel.signIn()，不直接用
    /// SignInWithAppleButton——授权整条路收在 AuthService 里，只有一个代码路径，
    /// 测试替身 MockAuthService 才能替掉它。
    private var authSection: some View {
        Section("账户") {
            if authViewModel.isSignedIn {
                HStack {
                    Text("余额")
                    Spacer()
                    Text(authViewModel.balance.map { "\($0) 点" } ?? "—")
                        .foregroundStyle(.secondary)
                }
                Button("退出登录", role: .destructive) {
                    authViewModel.signOut()
                }
            } else {
                Button("用 Apple 登录") {
                    Task { await authViewModel.signIn() }
                }
                .disabled(authViewModel.isSigningIn)
                if authViewModel.isSigningIn {
                    ProgressView("登录中…")
                }
                Text("登录后服务端发放 5 点 starter credits；长期凭证是服务端 JWT，存在钥匙串里。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = authViewModel.errorMessage {
                Text(error).foregroundStyle(.red)
            }
        }
    }

    // MARK: - 充值（购买切片 B4）

    /// 购买入口只放调试页，不动相框。商品行用 StoreKit 的 displayName +
    /// 本地化价格；未登录也能看到商品与价格，购买按钮禁用（价格是公开信息，
    /// 买才要登录）。余额以服务端 GET /v1/credits 为准，不在客户端本地维护。
    private var storeSection: some View {
        Section("充值") {
            if !authViewModel.isSignedIn {
                Text("先登录，再购买点数。").foregroundStyle(.secondary)
            }
            if storeViewModel.isLoadingProducts {
                ProgressView("正在加载商品…")
            } else if storeViewModel.products.isEmpty {
                if authViewModel.isSignedIn {
                    Text("没有可用商品").foregroundStyle(.secondary)
                    Button("重试") {
                        Task { await storeViewModel.loadProducts() }
                    }
                }
            } else {
                ForEach(storeViewModel.products) { product in
                    HStack {
                        Text(product.displayName)
                        Spacer()
                        Text(product.displayPrice).foregroundStyle(.secondary)
                        Button("购买") {
                            Task { await storeViewModel.purchase(productID: product.id) }
                        }
                        .disabled(!authViewModel.isSignedIn || storeViewModel.isPurchasing)
                    }
                }
                if storeViewModel.isPurchasing {
                    ProgressView("购买中…")
                }
            }
            if let message = storeViewModel.purchaseMessage {
                Text(message).foregroundStyle(.green)
            }
            if let error = storeViewModel.errorMessage {
                Text(error).foregroundStyle(.red)
            }
            // 调试口子：对最新一笔 credits.10 调 beginRefundRequest 弹退款表
            // （抓 REFUND fixture 用，抓完即删）。
            Button("申请退款（调试）") {
                Task { await storeViewModel.requestRefund() }
            }
            .disabled(storeViewModel.isRequestingRefund)
            if let refundMessage = storeViewModel.refundMessage {
                Text(refundMessage).foregroundStyle(.secondary)
            }
        }
        .task {
            await storeViewModel.loadProducts()
        }
    }

    // MARK: - 当前窗口

    private var currentWindowSection: some View {
        Section("当前窗口") {
            if let features = viewModel.lastFeatures {
                featureRow("打字密度", value: String(format: "%.2f", features.typingDensity))
                featureRow("人声比例", value: String(format: "%.2f", features.speechRatio))
                featureRow("平均音量", value: String(format: "%.1f dBFS", features.meanDBFS))
                featureRow("安静突变", value: features.quietDrop ? "是" : "否")
            } else {
                Text("还没有窗口结果").foregroundStyle(.secondary)
            }
            HStack {
                Text("Mood")
                Spacer()
                if let mood = viewModel.currentMood {
                    Text(mood.chineseName).bold()
                    if let confidence = viewModel.lastConfidence {
                        Text(String(format: "置信度 %.2f", confidence))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
            }
        }
    }

    private func featureRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    // MARK: - 采样与模式

    private var samplingSection: some View {
        Section("采样") {
            Picker("间隔", selection: Binding(
                get: { viewModel.intervalMinutes },
                set: { viewModel.setInterval($0) }
            )) {
                ForEach(ListeningViewModel.intervalOptions, id: \.self) { minutes in
                    Text(minutes == 1 ? "1 分钟（调试）" : "\(minutes) 分钟").tag(minutes)
                }
            }
            .pickerStyle(.segmented)
            Text("每周期采样 30 秒，窗口长度不变。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if viewModel.state == .listening {
                Button("停止聆听", role: .destructive) {
                    viewModel.stopListening()
                }
            } else {
                Button("开始聆听") {
                    viewModel.startListening()
                }
                .disabled(viewModel.permission == .denied || viewModel.permission == .unavailable)
            }
        }
    }

    private var modeSection: some View {
        Section("模式") {
            Picker("模式", selection: $viewModel.mode) {
                Text(ListeningViewModel.Mode.auto.rawValue).tag(ListeningViewModel.Mode.auto)
                Text(ListeningViewModel.Mode.manual.rawValue).tag(ListeningViewModel.Mode.manual)
            }
            .pickerStyle(.segmented)
            if viewModel.mode == .manual {
                Text("手动选择 Mood（权限被拒或无麦克风时，这是唯一的 mood 通路）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(Mood.allCases, id: \.self) { mood in
                    Button {
                        viewModel.selectManualMood(mood)
                    } label: {
                        HStack {
                            Text(mood.chineseName)
                            Spacer()
                            if viewModel.manualMood == mood {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                }
            }
        }
    }

    // MARK: - 相框（C4）

    private var frameSection: some View {
        Section("相框") {
            HStack {
                Text("正在展示")
                Spacer()
                Text(frameViewModel.currentPainting.title)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("铭牌")
                Spacer()
                Text(frameViewModel.nameplateText)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            Toggle("显示一句话", isOn: $frameViewModel.captionEnabled)
        }
    }

    // MARK: - 最近窗口

    private var recentWindowsSection: some View {
        Section("最近窗口") {
            if viewModel.recentWindows.isEmpty {
                Text("还没有窗口结果").foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.recentWindows) { record in
                    HStack {
                        Text(record.endsAt, style: .time)
                        Spacer()
                        Text(record.mood.chineseName)
                        Text(String(format: "%.2f", record.confidence))
                            .foregroundStyle(.secondary)
                        Text(String(format: "%.0f dB", record.features.meanDBFS))
                            .foregroundStyle(.secondary)
                    }
                    .monospacedDigit()
                }
            }
        }
    }
}

/// 首次开启聆听的说明页（需求 1.1）：先说明，再弹系统权限。
/// 文案就是需求原文：“只在设备端分析、不录音、不上传”。
private struct PermissionExplainerView: View {
    var onConfirm: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("开始聆听之前")
                .font(.title2)
                .bold()
            Text("Calm Frame 会用麦克风聆听周围的环境声，判断房间的氛围。")
            VStack(alignment: .leading, spacing: 8) {
                Label("只在设备端分析", systemImage: "checkmark.circle")
                Label("不录音", systemImage: "checkmark.circle")
                Label("不上传音频", systemImage: "checkmark.circle")
            }
            Text("分析只产生一个氛围标签（比如“忙乱”“平静”），音频本身不会保存、不会离开这台设备。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("我知道了，开始聆听") {
                onConfirm()
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)
            Button("以后再说") {
                onCancel()
            }
            .frame(maxWidth: .infinity)
        }
        .padding()
    }
}
