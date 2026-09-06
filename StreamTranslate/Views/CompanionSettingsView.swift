import SwiftUI
import CoreImage.CIFilterBuiltins
import CompanionKit

struct CompanionSettingsView: View {
    let server: CompanionServer
    let webServer: WebCaptionServer
    let remote: RemoteCaptionRelay
    @Environment(CaptionSettings.self) private var settings
    @Environment(CaptionViewModel.self) private var viewModel
    @State private var confirmRevoke = false
    @State private var confirmPrivate = false
    @State private var webMode = true

    var body: some View {
        @Bindable var settings = settings
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Label("手机私密字幕", systemImage: "iphone.and.arrow.forward")
                    .font(.title2.bold())
                Text("电脑负责收音与翻译，iPhone 只接收原文和译文。请先配对，再开始共享屏幕。")
                    .foregroundStyle(.secondary)
                Picker("手机入口", selection: $webMode) {
                    Text("网页版 · 免签名").tag(true)
                    Text("原生 iPhone App").tag(false)
                }.pickerStyle(.segmented)
                if webMode {
                    WebCompanionSettingsView(server: webServer, remote: remote)
                } else {
                Toggle("开启手机字幕服务", isOn: $settings.companionEnabled)
                Toggle("允许苹果近距离直连（试验性）", isOn: $settings.companionPeerToPeer)
                    .disabled(!settings.companionEnabled)
                Text("默认使用局域网。直连需要两端开启此选项，并保持 Wi-Fi 开启；尚需真机稳定性与会议共存测试。更改会重新连接。")
                    .font(.caption).foregroundStyle(.secondary)
                Label(server.status, systemImage: server.isConnected ? "lock.shield.fill" : "network")
                    .font(.callout)
                if !server.pairedNames.isEmpty {
                    Text("已授权：\(server.pairedNames.joined(separator: "、"))")
                    Button("解除手机配对…", role: .destructive) { confirmRevoke = true }
                } else {
                    Button("生成两分钟有效的配对二维码") { server.createInvitation() }
                        .disabled(!server.isRunning)
                    if !server.pairingURL.isEmpty {
                        if let image = qrImage(server.pairingURL) {
                            Image(nsImage: image).interpolation(.none).resizable()
                                .scaledToFit().frame(width: 270, height: 270)
                                .padding(12).background(.white)
                                .frame(maxWidth: .infinity)
                        }
                        Text("拥有此二维码的人可绑定手机，请勿在共享屏幕中展示。首次成功配对后立即失效。")
                            .font(.caption).foregroundStyle(.orange)
                        HStack {
                            Button("复制配对链接") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(server.pairingURL, forType: .string)
                            }
                            Button("取消邀请") { server.cancelInvitation() }
                        }
                    }
                }
                }
                Divider()
                Button("进入仅手机显示模式…") { confirmPrivate = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(!(server.isConnected || webServer.isConnected || remote.isConnected) || !viewModel.isTranslationReady)
                Text("进入后收起电脑上的字幕、历史和设置窗口。手机断线不会恢复电脑字幕。退出请点菜单栏字幕图标。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(24)
        }
        .frame(width: 460, height: 650)
        .confirmationDialog("解除配对后，这部手机不能再接收字幕。", isPresented: $confirmRevoke) {
            Button("解除配对", role: .destructive) { server.revokePairing() }
        }
        .confirmationDialog("电脑将隐藏字幕和设置窗口；请确认手机已能看到字幕。", isPresented: $confirmPrivate) {
            Button("仅在手机显示") { settings.phoneOnlyDisplay = true }
        }
    }

    private func qrImage(_ string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: .init(scaleX: 8, y: 8)),
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: image, size: .init(width: image.width, height: image.height))
    }
}
