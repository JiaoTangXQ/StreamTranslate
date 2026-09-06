import SwiftUI
import CompanionKit
import CoreImage.CIFilterBuiltins

struct RemoteCompanionSettingsView: View {
    let server: RemoteCaptionRelay
    @Environment(CaptionSettings.self) private var settings
    @State private var consent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("手机用流量，也能看字幕").font(.headline)
            Text("不同 Wi-Fi 也可以。电脑联网并保持唤醒，iPhone 相机扫码即可，无需 VPN 或安装证书。")
                .font(.callout).foregroundStyle(.secondary)
            if server.configured {
                Button(server.isRunning ? "显示连接二维码" : "手机用流量 / 不同 Wi-Fi…") {
                    guard !settings.phoneOnlyDisplay else { return }
                    if server.isRunning { server.createInvitation() } else { consent = true }
                }.buttonStyle(.borderedProminent).disabled(settings.phoneOnlyDisplay)
                Label(server.status, systemImage: server.isConnected ? "checkmark.shield.fill" : "network")
                    .font(.callout)
                if !server.pairingURL.isEmpty, let image = qr(server.pairingURL) {
                    Image(nsImage: image).interpolation(.none).resizable().scaledToFit()
                        .frame(width: 240, height: 240).padding(10).background(.white).frame(maxWidth: .infinity)
                    Text("相机扫码 → 点链接 → 开始阅读").font(.headline)
                    Text("二维码两分钟、一次有效，请勿在共享屏幕时展示。网页可添加到主屏幕；本次授权最长 12 小时，关闭连接后需重新扫码。")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("复制连接链接") {
                            guard !settings.phoneOnlyDisplay else { return }
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(server.pairingURL, forType: .string)
                        }
                        Button("隐藏二维码") { server.cancelInvitation() }
                    }
                    Text("桌面图标需要重新配对时，可在其中粘贴此链接。链接包含私密授权，请勿转发。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if server.isRunning {
                    Button("关闭跨网络连接", role: .destructive) { settings.remoteCompanionEnabled = false }
                    Text("音频与模型留在 Mac。字幕加密后经你的杭州服务器转发；服务器只暂存密文。网页代码由这台服务器提供。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("这台 Mac 尚未配置跨网络服务。可先使用下方局域网连接。")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .onDisappear { server.cancelInvitation() }
        .confirmationDialog("开启跨网络字幕？", isPresented: $consent, titleVisibility: .visible) {
            Button("开启加密连接并显示二维码") {
                guard !settings.phoneOnlyDisplay else { return }
                server.createInvitation(); settings.remoteCompanionEnabled = true
            }
        } message: {
            Text("原文和译文在 Mac 加密后，通过你部署的公网服务器转发给手机，不上传音频。请确认会议内容允许使用此方式传输。可随时关闭。")
        }
    }
    private func qr(_ value: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator(); filter.message = Data(value.utf8); filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: .init(scaleX: 8, y: 8)),
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: image, size: .init(width: image.width, height: image.height))
    }
}
