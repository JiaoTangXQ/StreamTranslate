import SwiftUI
import CompanionKit
import CoreImage.CIFilterBuiltins

struct RemoteCompanionSettingsView: View {
    let server: RemoteCaptionRelay
    @Environment(CaptionSettings.self) private var settings
    @State private var consent = false
    @State private var revoke = false

    var body: some View {
        @Bindable var settings = settings
        return VStack(alignment: .leading, spacing: 12) {
            Text("手机用流量，也能看字幕").font(.headline)
            Text("不同 Wi-Fi 也可以。电脑联网并保持唤醒，iPhone 相机扫码即可，无需 VPN 或安装证书。配对一次可用 90 天，经常打开会自动续期。")
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
                    Text("二维码两分钟、一次有效，请勿在共享屏幕时展示。配对后可添加到主屏幕；Mac 重启后无需重新扫码。")
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
                    Divider()
                    Toggle(isOn: $settings.phoneMicrophoneEnabled) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("允许手机远程收音").font(.callout.weight(.medium))
                            Text("在手机网页点「用手机收音」，声音加密后传到这台 Mac 识别和翻译，字幕再回到手机。开启时 Mac 不会自动睡眠，建议接上电源；只能启动手机的麦克风，Mac 自己的麦克风和电脑音频不会被远程打开。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.toggleStyle(.switch)
                    Divider()
                    HStack {
                        Text(server.pairedDeviceCount > 0 ? "已配对 \(server.pairedDeviceCount) 个手机入口" : "还没有配对的手机")
                            .font(.callout)
                        Spacer()
                        Button("撤销所有手机", role: .destructive) { revoke = true }
                            .disabled(server.pairedDeviceCount == 0)
                    }
                    Button("关闭跨网络连接", role: .destructive) { settings.remoteCompanionEnabled = false }
                    Text("字幕和手机声音都在端上加密，经你的杭州服务器转发；服务器只暂存密文，不保存字幕或音频。网页代码由这台服务器提供。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("这台 Mac 尚未配置跨网络服务。可先使用下方局域网连接。")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .onDisappear { server.cancelInvitation() }
        .confirmationDialog("撤销所有手机的授权？", isPresented: $revoke, titleVisibility: .visible) {
            Button("撤销并更换连接密钥", role: .destructive) { server.revokeAllDevices() }
        } message: {
            Text("已配对的手机和主屏幕图标都需要重新扫码。手机丢失时请使用此操作。")
        }
        .confirmationDialog("开启跨网络字幕？", isPresented: $consent, titleVisibility: .visible) {
            Button("开启加密连接并显示二维码") {
                guard !settings.phoneOnlyDisplay else { return }
                server.createInvitation(); settings.remoteCompanionEnabled = true
            }
        } message: {
            Text("原文和译文在 Mac 加密后，通过你部署的公网服务器转发给手机；允许手机收音时，手机声音也加密后经该服务器传到 Mac。请确认会议内容允许使用此方式传输。可随时关闭。")
        }
    }
    private func qr(_ value: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator(); filter.message = Data(value.utf8); filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: .init(scaleX: 8, y: 8)),
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: image, size: .init(width: image.width, height: image.height))
    }
}
