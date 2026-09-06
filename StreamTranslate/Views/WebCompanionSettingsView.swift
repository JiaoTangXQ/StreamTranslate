import SwiftUI
import CompanionKit
import CoreImage.CIFilterBuiltins

struct WebCompanionSettingsView: View {
    let server: WebCaptionServer
    let remote: RemoteCaptionRelay
    @Environment(CaptionSettings.self) private var settings
    @State private var exportMessage = ""
    @State private var confirmRevoke = false
    @State private var confirmReset = false
    @State private var confirmQuick = false
    @State private var inviteWhenReady = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            RemoteCompanionSettingsView(server: remote)
            DisclosureGroup("同一 Wi-Fi：局域网连接") {
            VStack(alignment: .leading, spacing: 14) {
            Text("连接手机，只需扫码").font(.headline)
            Text("Mac 和 iPhone 连到同一可互通局域网，用 iPhone 自带相机扫码，点链接即可看字幕。不用下载 App、登录账号或安装证书。")
                .font(.callout).foregroundStyle(.secondary)
            Button(server.isRunning && server.transport == .trustedLAN ? "显示新的连接二维码" : "快速连接手机…") {
                if settings.webQuickConnection { connectQuick() } else { confirmQuick = true }
            }.buttonStyle(.borderedProminent)
                .disabled(settings.phoneOnlyDisplay)
            Text("快速连接使用未加密 HTTP，仅适合你信任的家庭/办公室网络。公共网络或敏感会议请选择下方 HTTPS 加密连接。")
                .font(.caption).foregroundStyle(.orange)
            Label(server.status, systemImage: server.isConnected ? "iphone" : "network")
                .font(.callout)
            if server.isRunning {
                if !server.pairingURL.isEmpty {
                    if let qr = qrImage(server.pairingURL) {
                        Image(nsImage: qr).interpolation(.none).resizable().scaledToFit()
                            .frame(width: 240, height: 240).padding(10).background(.white).frame(maxWidth: .infinity)
                    }
                    Text("相机扫码 → 点链接 → 自动连接").font(.headline)
                    Text("二维码两分钟、一次有效，请勿在共享屏幕时展示。微信若无法打开，请改用 iPhone 相机或在 Safari 打开链接。")
                        .font(.caption).foregroundStyle(.orange)
                    DisclosureGroup("无法扫码？手动连接") {
                        Text(server.address).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        Text("配对码：\(server.pairingCode)").font(.system(.title2, design: .monospaced)).textSelection(.enabled)
                        Button("复制网页地址") { copy(server.address) }
                    }
                    Button("隐藏二维码") { inviteWhenReady = false; server.cancelInvitation() }
                }
                if server.isConnected { Label("手机已连接，可以进入仅手机显示模式", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                Text("添加桌面图标是可选的：Safari 分享 → 添加到主屏幕。无需先安装就能看字幕。")
                    .font(.caption).foregroundStyle(.secondary)
                Text(server.transport == .trustedLAN ? "快速连接授权最长 12 小时；关闭/重启电脑网页服务后重新扫码。网络换了请关闭服务再连接。HTTP 无法自动保持亮屏。" : "HTTPS 授权有效 90 天；清除网站数据后重新扫码。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("关闭网页连接") { inviteWhenReady = false; settings.webCompanionEnabled = false }
                    if server.pairedCount > 0 { Button("解除网页配对…", role: .destructive) { confirmRevoke = true } }
                }
                if server.pairedCount >= 3 { Text("已授权 3 个浏览器。如需连接新入口，请先解除旧配对。").font(.caption) }
            }
            DisclosureGroup("高级：HTTPS 加密连接") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("加密传输，适合敏感字幕；首次需要在 iPhone 手动安装并信任本机证书。不会因为 HTTPS 失败而自动切换为未加密连接。")
                        .font(.caption)
                    Button("使用 HTTPS 加密连接") {
                        guard !settings.phoneOnlyDisplay else { return }
                        inviteWhenReady = true; settings.webQuickConnection = false; settings.webCompanionEnabled = true
                        showInvitationIfReady()
                    }
                    if server.isRunning && server.transport == .secure {
                        Button("导出手机证书描述文件…") { exportProfile() }
                        Text("Finder 隔空投送到自己的 iPhone → 设置 → 通用 → VPN 与设备管理，安装；再到通用 → 关于本机 → 证书信任设置，信任 StreamTranslate Local。仅含本机公开证书，无管理/VPN/私钥；一年有效。")
                            .font(.caption).foregroundStyle(.secondary)
                        if !exportMessage.isEmpty { Text(exportMessage).font(.caption).textSelection(.enabled) }
                        Text(server.address).font(.caption).textSelection(.enabled)
                        Button("生成 HTTPS 配对二维码") { showInvitationIfReady() }
                        DisclosureGroup("证书 SHA-256 / 有效期") {
                            Text(server.certificateFingerprint).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                            if let expires = server.certificateExpires { Text(expires.formatted(date: .numeric, time: .omitted)).font(.caption) }
                        }
                    }
                    Text("电脑改名或证书到期可重置：将停止网页、解除所有网页授权；需重新安装手机证书，不影响原生 App 配对。")
                        .font(.caption)
                    Button("重置网页证书…", role: .destructive) { confirmReset = true }
                }
            }
            }
            }
        }
        .onChange(of: server.isRunning) { _, running in if running && inviteWhenReady { showInvitationIfReady() } }
        .onDisappear { inviteWhenReady = false; server.cancelInvitation() }
        .confirmationDialog("在可信局域网启用快速连接？", isPresented: $confirmQuick, titleVisibility: .visible) {
            Button("我信任此网络，开启快速扫码") { connectQuick() }
        } message: {
            Text("无需手机证书，但字幕和配对凭据通过 HTTP 明文传输，网络攻击者可能窃听或篡改。请勿用于公共 Wi-Fi 或敏感会议。不会上传至外部服务器；原有 HTTPS 不会自动降级。")
        }
        .confirmationDialog("所有网页浏览器将断开，之后需要重新配对。", isPresented: $confirmRevoke) {
            Button("解除网页配对", role: .destructive) { server.revokePairings() }
        }
        .confirmationDialog("重置后，手机上的旧证书与网页配对均不可再用。", isPresented: $confirmReset) {
            Button("重置网页证书", role: .destructive) { settings.webCompanionEnabled = false; server.resetCertificate() }
        }
    }
    private func connectQuick() {
        guard !settings.phoneOnlyDisplay else { return }
        inviteWhenReady = true; settings.webQuickConnection = true; settings.webCompanionEnabled = true
        if server.isRunning && server.transport == .trustedLAN { showInvitationIfReady() }
    }
    private func showInvitationIfReady() {
        guard !settings.phoneOnlyDisplay, server.isRunning,
              (server.transport == .trustedLAN) == settings.webQuickConnection else { return }
        inviteWhenReady = false; server.createInvitation()
    }
    private func copy(_ text: String) {
        guard !settings.phoneOnlyDisplay else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }
    private func exportProfile() {
        guard !settings.phoneOnlyDisplay else { return }
        do {
            let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true).appendingPathComponent("StreamTranslate/WebSetup", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("StreamTranslate-\(server.certificateFingerprint.prefix(8)).mobileconfig")
            try server.certificateProfile().write(to: url, options: .atomic)
            exportMessage = "已导出。请在 Finder 右键此文件 → 共享 → 隔空投送。"
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch { exportMessage = error.localizedDescription }
    }
    private func qrImage(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator(); filter.message = Data(text.utf8); filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: .init(scaleX: 8, y: 8)),
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: image, size: .init(width: image.width, height: image.height))
    }
}
