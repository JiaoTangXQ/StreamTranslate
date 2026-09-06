import SwiftUI
import UIKit
import CompanionKit

struct CompanionReaderView: View {
    let client: CompanionClient
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("subtitleFontSize") private var fontSize = 27.0
    @AppStorage("showOriginal") private var showOriginal = true
    @AppStorage("keepScreenAwake") private var keepAwake = true
    @AppStorage("allowPeerToPeer") private var peerToPeer = false
    @State private var showSettings = false
    @State private var showScanner = false
    @State private var pairingText = ""
    @State private var pairingError = ""
    @State private var followingLive = true
    @State private var confirmForget = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    Circle().fill(client.state == .live ? .green : .orange).frame(width: 7, height: 7)
                    Text(client.status).font(.caption).accessibilityIdentifier("connection-status")
                    Spacer()
                    if client.state == .live { Image(systemName: "lock.fill").font(.caption) }
                }
                .foregroundStyle(.secondary).padding()
                Divider()
                if client.state == .live, let snapshot = client.snapshot {
                    captions(snapshot)
                } else if !client.hasPairing {
                    pairingView
                } else {
                    ContentUnavailableView {
                        Label("等待电脑字幕", systemImage: "desktopcomputer")
                    } description: {
                        Text("电脑需开启手机字幕服务。恢复连接后会直接显示当前内容，不会重播旧字幕。")
                    } actions: {
                        Button("重新连接") { client.reconnect() }
                    }
                }
            }
            .navigationTitle("私密字幕")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("设置", systemImage: "slider.horizontal.3") { showSettings = true }
                        .accessibilityIdentifier("reader-settings")
                }
            }
            .sheet(isPresented: $showSettings) { settingsView }
            .sheet(isPresented: $showScanner) {
                QRScannerView { value in
                    showScanner = false
                    connect(value)
                }
                .ignoresSafeArea()
                .overlay(alignment: .topTrailing) {
                    Button("关闭") { showScanner = false }.padding().buttonStyle(.borderedProminent)
                }
            }
            .onOpenURL { connect($0.absoluteString) }
            .onAppear { client.peerToPeer = peerToPeer; client.start(); updateIdleTimer() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { client.start() }
                else if phase == .background { client.pause() }
                updateIdleTimer()
            }
            .onChange(of: client.state) { _, _ in updateIdleTimer() }
            .onChange(of: keepAwake) { _, _ in updateIdleTimer() }
            .onChange(of: peerToPeer) { _, value in client.peerToPeer = value; client.reconnect() }
            // Cover captions before the system captures an app-switcher snapshot.
            .overlay {
                if scenePhase != .active {
                    Color(uiColor: .systemBackground).ignoresSafeArea()
                        .overlay(Label("私密字幕", systemImage: "lock.fill").font(.title2))
                        .accessibilityIdentifier("privacy-cover")
                }
            }
        }
    }

    private func captions(_ snapshot: CompanionSnapshot) -> some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        ForEach(snapshot.captions) { row in captionRow(row, live: false) }
                        if let streaming = snapshot.streaming { captionRow(streaming, live: true) }
                        Text(snapshot.status.title).font(.caption).foregroundStyle(.secondary)
                        Color.clear.frame(height: 1).id("live-bottom")
                    }
                    .padding(20).frame(maxWidth: .infinity, alignment: .leading)
                }
                .simultaneousGesture(DragGesture(minimumDistance: 12).onChanged { _ in followingLive = false })
                .accessibilityIdentifier("caption-feed")
                .onChange(of: snapshot.sequence) { _, _ in
                    if followingLive { proxy.scrollTo("live-bottom", anchor: .bottom) }
                }
                .onAppear {
                    // Returning from a disconnect shows current captions, not
                    // the history position from the previous connection.
                    followingLive = true
                    proxy.scrollTo("live-bottom", anchor: .bottom)
                }
                .onChange(of: snapshot.sessionID) { _, _ in
                    followingLive = true
                    proxy.scrollTo("live-bottom", anchor: .bottom)
                }
                if !followingLive {
                    Button("回到实时字幕", systemImage: "arrow.down.to.line") {
                        followingLive = true
                        proxy.scrollTo("live-bottom", anchor: .bottom)
                    }
                    .buttonStyle(.borderedProminent).padding(.bottom, 12)
                    .accessibilityIdentifier("follow-live")
                }
            }
        }
    }

    private func captionRow(_ row: CompanionCaption, live: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if showOriginal, !row.original.isEmpty {
                Text(row.original).font(.system(size: max(15, fontSize * 0.65)))
                    .foregroundStyle(.secondary).textSelection(.enabled)
                    .accessibilityIdentifier("caption-original-\(row.id)")
            }
            Text(row.translation.isEmpty ? (showOriginal ? "翻译中…" : row.original) : row.translation)
                .font(.system(size: fontSize, weight: .medium))
                .foregroundStyle(row.translation.isEmpty ? .secondary : .primary)
                .textSelection(.enabled)
                .accessibilityIdentifier("caption-translation-\(row.id)")
            if live { Text("实时草稿 · 后续可能修订").font(.caption2).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var pairingView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: "iphone.and.arrow.forward").font(.system(size: 44)).foregroundStyle(.tint)
                Text("电脑翻译，手机看字幕").font(.title2.bold())
                    .accessibilityIdentifier("pairing-title")
                Text("在 Mac 菜单栏打开“手机字幕”，开启服务并生成二维码。配对后，下次打开会自动连接。")
                    .foregroundStyle(.secondary)
                Button("扫描电脑二维码", systemImage: "qrcode.viewfinder") { showScanner = true }
                    .buttonStyle(.borderedProminent)
                TextField("或粘贴配对链接", text: $pairingText, axis: .vertical)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .lineLimit(2...4).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("pairing-link")
                Button("使用配对链接") { connect(pairingText) }.disabled(pairingText.isEmpty)
                    .accessibilityIdentifier("pairing-connect")
                if !pairingError.isEmpty {
                    Text(pairingError).foregroundStyle(.red).accessibilityIdentifier("pairing-error")
                }
                Text("不在手机运行模型，不上传音频；字幕默认不在手机永久保存。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(24)
        }
    }

    private var settingsView: some View {
        NavigationStack {
            Form {
                Section("阅读") {
                    Slider(value: $fontSize, in: 18...42, step: 1) { Text("字号") }
                        .accessibilityIdentifier("reader-font-size")
                    Text("字幕字号：\(Int(fontSize))").accessibilityIdentifier("reader-font-label")
                    Toggle("显示原文", isOn: $showOriginal)
                        .accessibilityIdentifier("reader-show-original")
                    Toggle("观看时保持亮屏", isOn: $keepAwake)
                        .accessibilityIdentifier("reader-keep-awake")
                }
                Section("连接") {
                    Toggle("允许苹果近距离直连（试验性）", isOn: $peerToPeer)
                    Text("默认使用局域网。直连需要 Mac 和手机两端都开启，尚需真机性能验证。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("重新连接") { client.reconnect(); showSettings = false }
                    Button("移除本机配对…", role: .destructive) { confirmForget = true }
                        .disabled(!client.hasPairing)
                }
                Section {
                    Text("锁屏或切换 App 后连接可能暂停，重新打开会恢复当前字幕。电脑断线时不会弹出字幕兜底。")
                }
            }
            .navigationTitle("字幕设置")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showSettings = false }.accessibilityIdentifier("reader-settings-done")
                }
            }
            .confirmationDialog("同时需要在 Mac 上解除旧配对，才能绑定新手机。", isPresented: $confirmForget) {
                Button("移除本机配对", role: .destructive) {
                    do { try client.forget(); showSettings = false }
                    catch { pairingError = error.localizedDescription }
                }
            }
        }
    }

    private func connect(_ value: String) {
        do { try client.pair(url: value); pairingError = ""; pairingText = ""; showSettings = false }
        catch { pairingError = error.localizedDescription }
    }

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = keepAwake && scenePhase == .active && client.state == .live
    }
}
