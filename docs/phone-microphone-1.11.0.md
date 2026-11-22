# 手机收音 1.11.0（build 30）

开会时只带手机也能用：手机网页录下会场声音，加密后经你的中转服务器送到
一直开着的 Mac；Mac 照常识别、翻译、整理脑图，字幕和脑图再回到手机。
仍是个人服务器方案，不是公共注册服务。仓库里的地址仍是示例 192.0.2.1。

## 怎么用

1. Mac 打开「手机字幕」，开启跨网络连接，点「显示连接二维码」。
2. iPhone 相机扫码打开网页；建议 Safari「添加到主屏幕」，以后从图标进入。
3. 在网页底部点「用手机收音」，第一次按系统提示允许麦克风。
4. 字幕出现在手机上；底部「脑图」按钮打开 Mac 整理的对话脑图。
5. 再点一次「停止收音」结束。Mac 收尾最后一句后停止识别。

前提与限制：

- Mac 必须开机、联网、保持唤醒。「允许手机远程收音」开启且跨网络连接运行
  时，Mac 持有 `idleSystemSleepDisabled`，不会因闲置睡眠；合盖或手动睡眠
  仍会断开。建议接电源。
- 手机屏幕要亮着、网页在前台。页面隐藏（锁屏、切到别的 App）时网页主动
  停止收音；Mac 8 秒收不到声音也会自行结束这一段。
- 只能用手机的麦克风启动识别。手机不能远程打开 Mac 自己的麦克风或电脑
  音频。Mac 正在用自己的音源收音、正在收尾或识别还没准备好时，手机的
  请求被拒绝，并在手机上说明原因，不会打断 Mac 上的会话。
- Mac 上可以随时停止，或改用 Mac 的音源；之后手机会显示「电脑上已停止收音」。
  手机收音期间在 Mac 上切换识别语言，会结束这段手机收音，需要在手机上重新开始。

麦克风被拒绝时，网页会显示错误名（如 `NotAllowedError`）。Safari 在同一个
页面里被拒绝过一次后，会直接拒绝之后不是由点按直接发出的麦克风请求，改了
设置也一样。网页因此在点按的同一时刻请求麦克风，排在任何等待之前（早期
版本先派生密钥再请求，在 iPhone 上会一直被拒绝）。仍被拒绝时：在 Safari 地址栏
点「大小」→ 网站设置 → 麦克风，选「允许」，关掉页面重新打开再点。

## 配对

- 扫码一次可用 90 天，剩余不足 80 天时打开页面会自动续期。最多 5 个手机入口。
- Mac 在登录钥匙串（`CompanionVault`，账号 `remote-relay-room`）保存固定的
  房间号、加密密钥和已授权浏览器 Cookie 的哈希。中转服务器只在内存里保存
  这些哈希；Mac 每次连上中转时重新登记，所以中转或 Mac 重启后不必重新扫码。
- 关闭跨网络连接只让手机看到「电脑离线」，配对保留。「撤销所有手机」更换
  房间和密钥，所有手机和主屏幕图标都要重新扫码；手机丢失时使用。
- 从 1.10.0 升级后需要重新扫码一次：旧版没有保存长期配对，部署新中转时
  内存中的旧授权已清空。

## 数据与安全边界

链路：手机麦克风 → AudioWorklet 低通并重采样为 16 kHz 单声道 Int16，每帧
100 ms → WebCrypto AES-256-GCM → HTTPS POST `/api/audio` → 中转（只存密文）→
Mac 长轮询 `/publisher/audio` → CryptoKit 解密 → 与本机麦克风相同的识别管线 →
字幕和脑图照旧加密后经 SSE 回到手机。

- 上行密钥由房间密钥经 HKDF-SHA256 派生（salt 为房间号，info
  `StreamTranslate phone audio v1`），与字幕下行密钥分开。
- 明文格式：`STA1`、首帧编号（UInt32 大端）、标志（bit 0 表示结束）、保留
  字节、Int16 小端样本。AAD 为 `房间:流:序号:audio`，序号和录音流 ID 都被
  认证：中转改不了序号，也无法把声音混进另一段录音；重复送达的帧被 Mac 丢弃。
- 中转不保存音频到磁盘，不能解密。每个房间最多排队最新 40 个上传（约 40 秒）；
  Mac 跟不上时丢最旧的。每个浏览器上传上限约 192 KiB/s（约 4 倍实时码率，
  足够网络恢复后补传），单次上传不超过 60,000 个 base64 字符。Mac 离线时
  返回 503，手机保留声音并提示。
- 网页代码仍由这台服务器提供；服务器被攻破可以替换网页脚本。中转的页面
  权限策略只允许本站使用麦克风：`microphone=(self)`，摄像头和定位关闭。
- 会议模式请求 `echoCancellation`、`noiseSuppression`、`autoGainControl`。

## 断网与丢帧

- 手机最多缓存 5 秒未送达的声音。上传失败（断网、503、429）时保留这批声音，
  稍后按原帧号重发；超出 5 秒时丢弃最旧的帧。
- 每帧带采集编号。Mac 把缺失的帧补成等长静音（最多 2 秒），保持识别器时间轴
  和停顿检测正确；重复送达的帧被丢弃。
- 停止时，手机先发出仍在队列里的声音，再发结束标记。

## 未压缩码率

原始 PCM 每秒约 32 KB，加密和 base64 后每秒约 43 KB（约 340 kbit/s），一小时
约 150 MB 流量。这一版不压缩，先保证延迟和兼容性；是否压缩等真机测过蜂窝
流量和延迟后再定。

## 验证

- `python3 Tools/run_portable_tests.py`：348 个测试体，0 个失败断言。新增
  `StreamTranslateTests/PhoneMicrophoneTests.swift`：浏览器 WebCrypto 生成的
  向量由 CryptoKit 逐字节解开；篡改、错序号、错流、错密钥都被拒绝；丢帧补
  静音、重复帧丢弃、长时间中断封顶；识别开始前到达的第一批声音不丢；
  设备列表只在中转报告变化时写回钥匙串；脑图只在变化时随增量下发；旧版
  快照仍可解码；手机音源不会被保存为 Mac 的默认音源。
- `cd Relay && node --test server.test.mjs audio.test.mjs`：7 项通过（鉴权、
  Origin、格式校验、长轮询、队列上限、限速、离线 503、权限策略）。
- `node Relay/microphone.e2e.mjs build/remote-relay/public <48k.wav> <out.wav>`：
  无头 Chrome 把 WAV 当作麦克风输入真实网页。先拒绝麦克风权限，网页显示
  「麦克风被拒绝（NotAllowedError）」；改为允许后再点即可开始，两次请求都
  在点按事件内同步发出。12.1 秒内收到 12.2 秒 16 kHz
  音频；第 4–7 秒模拟手机断网，网页显示「网络不稳定，正在重试…」，恢复后
  补传，帧号连续、没有丢帧，没有 429。收到的 WAV 经 Apple 识别与原文逐词一致。
- `node Relay/phone-mac.e2e.mjs build/remote-relay/public build/phone-mic/PhoneMicrophoneProbe <48k.wav> [--public]`：
  网页 → 中转 → Mac 端真实的协调器、双语 Apple 识别、Apple 翻译和发布器 →
  手机字幕。本地中转和已部署的公网中转都通过：点「用手机收音」后
  4.2–5.4 秒手机上出现第一条中文译文；修复首批丢失后第一句
  "So the most important thing…" 完整；手机停止后 Mac 结束识别。
  `--public` 使用本机真实的中转配置和隔离的钥匙串，不影响已保存的房间。

## 部署

中转协议升为 2（`/healthz` 返回 `{"ok":true,"protocol":2}`），新增
`/publisher/offline`、`/publisher/audio`、`/api/audio`，`/api/state` 返回
`online` 并续期 Cookie。最多两间房；Mac 离开超过 10 分钟的房间清空密文，
并在有新房间需要时让位（Mac 回来后重新登记）；7 天没有 Mac 连接的房间被丢弃。

1. `node Relay/export-assets.mjs build/remote-relay/public`（现在也导出 `mic-worklet.js`）。
2. 把 `Relay/server.mjs` 和导出的 `public/` 打包上传到服务器。
3. 在 `/opt/streamtranslate-relay` 先备份为 `backup-<日期时间>/`，解包，
   `node --check server.mjs`，覆盖文件，`root:root` 0644，
   `systemctl restart streamtranslate-relay`，检查 `/healthz`。
4. Nginx 的 `client_max_body_size 256k` 和 `proxy_read_timeout 30s` 不需改动。

回滚：把备份目录里的 `server.mjs` 和 `public/` 复制回去并重启服务。

## 未验证

- 真实 iPhone：Safari 与主屏幕图标里的麦克风权限、iOS 对 AudioWorklet 的
  处理、通话或其他 App 抢占麦克风、蜂窝网络下的延迟和流量。
- 真实会议室的远场声音和多人交谈。测试音频是清晰的合成语音。
- `Relay/browser.test.mjs` 依赖未安装的 `agent-browser` 工具，这次没有运行；
  配对和页面行为由上面两个 Chrome 端到端测试覆盖。
