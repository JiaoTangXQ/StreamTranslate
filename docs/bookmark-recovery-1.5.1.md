# 书签 / 主屏幕连接恢复修复（1.5.1 / build 18）

## 故障与复现

用户反馈普通浏览器页面刷新正常，保存后重新打开无法连接，点「重新连接」没有效果。
独立浏览器测试保留配对 Cookie、删除 `streamtranslate.remote.v1` 后刷新，稳定复现
无法进入 live。原实现直接把缺少 localStorage 判为未配对，而且隐藏了公网配对表单。

[WebKit 的 Safari 17.2 说明](https://webkit.org/blog/14787/webkit-features-in-safari-17-2/)
确认：添加到主屏幕复制 Cookie，但不复制其他本地存储；两个容器随后独立。
这解释了为什么普通刷新通过不能证明主屏幕首启可用。尚未对用户那台真实 iPhone
抓取存储或运行自动化，不能把容器模拟称为实体设备实测。

还确认两个相关缺陷：保存旧二维码 fragment 会重复消费已失效邀请；同一 Cookie
只能有一条 SSE，Safari 和复制该 Cookie 的主屏幕入口可能互相挤掉。

## 修复

- GET `/api/state` 先检查 Cookie，返回其所属 room。已有授权而缺少本地密钥时自动恢复。
- 浏览器生成临时 P-256 ECDH 密钥，只向 `/api/restore` 提交公钥与随机请求 ID。
  此接口仍需有效 HttpOnly Cookie、相同 Origin；不开放匿名密钥恢复。
- Mac 在发布/心跳回复中读取待恢复请求，使用临时 ECDH + HKDF-SHA256 导出包装密钥，
  AES-256-GCM 封装当前 32-byte 字幕密钥。浏览器解封后只保存连接信息，不保存字幕。
  salt 为 room 的 UTF-8；HKDF info 与 GCM AAD 都为
  `StreamTranslate recovery v1:ROOM:REQUEST_ID`。封装结果和公钥经过服务端转发，
  字幕密钥不以明文发送给中转。真实 CryptoKit ↔ WebCrypto 互通已通过公网测试。
- 恢复请求绑定授权 Cookie/room，60 秒过期，每 Cookie 每分钟至多 3 个新请求；
  同 ID/公钥轮询幂等。最多每个已授权 Cookie 一个在途恢复请求，不延长 12 小时授权。
- 信任边界：持有有效 Cookie 可请求 Mac 重新封装密钥；不要求另一个本地存储因子。
  服务器仍是受信任的网页交付与授权判断端，不能宣称抵抗服务器主动伪造恢复请求
  或替换网页脚本。恢复协议防止被动中转拿到明文密钥，不改变该信任边界。
- 同 Cookie 最多 3 个并行流，避免两个入口互相踢掉；撤销时全部关闭。
- 已授权 room 的旧 QR 书签复用授权，不重复消费邀请、不延长有效期。
- 「重新连接」关闭覆盖内容的设置面板；无授权时明确显示重新配对表单。
  公网表单允许粘贴同源、新的完整连接链接（不自动读取剪贴板）；Mac 二维码下增加
  「复制连接链接」。链接两分钟/一次有效、包含私密信息，不可转发。
- 不使用 query 传密钥、不延长二维码寿命、不恢复 Mac 私密模式窗口。
- `AbortSignal.timeout` 改为已有兼容性更好的 AbortController + finally 清理计时器。

## 这次更新后怎么恢复

服务器与 Mac 更新会撤销旧连接，需要重新配对一次。

- Safari 普通书签：先用 Mac 新二维码连接，旧书签仍可使用同一网站的新授权。
- 已有桌面图标：可在图标内粘贴 Mac 新生成的连接链接直接配对，不必删除图标。
  也可在 Safari 扫码连接后重新添加到主屏幕一次，使系统复制新的 Cookie。
- 有效授权下，之后打开图标会自动恢复；Mac/服务重启、关闭连接或超过 12 小时仍需配对。
  不承诺无期限连接。若系统不复制 Cookie，使用页面中的粘贴配对入口。

## 验证与回退

- `build/remote-bookmark-before.log`：增加真实存储分离边界的回归后，修复前失败。
- `Relay/browser.test.mjs` / `build/remote-bookmark-after.log`：17 项通过，模拟主屏幕首启、重开、
  旧 QR 书签、授权失效后的重连按钮和在原窗口粘贴配对；兼顾原阅读/篡改清屏用例。
- `Relay/server.test.mjs`：恢复接口 Cookie/Origin/发布鉴权、密文恢复互通、撤销；
  两个同 Cookie 的真实 HTTP/SSE 流同时接收下一帧，不互相关闭。
- `Relay/public.test.mjs` / `build/bookmark-public-tests-final.log`：10 项通过，包括真实 Mac
  CryptoKit、公开 HTTPS、浏览器 WebCrypto 恢复与随后更新/重开/撤销。只用合成字幕。
- 局域网阅读回归：`build/bookmark-lan-regression.log`，37 项通过。
- 核心可移植测试：`build/remote-bookmark-core-tests.log`，273 项、0 失败，不是完整 Xcode runner。
- 安装记录：`build/install-1.5.1.log`。旧 Mac 包按既有安装脚本保留备份。
- 服务器只更新 `/opt/streamtranslate-relay/server.mjs` 与 `public/`，只重启字幕服务，
  不改 Nginx/证书/其他应用。更新前源码资产备份在
  `/tmp/streamtranslate-151.2ZSmgY/previous.tar.gz`（临时目录，不作为长期备份）。

防止复发：新增浏览器容器必须单独测试 Cookie、本地存储和窗口生命周期的组合，
不能再用同一页面 reload 代替安装到主屏幕的验收。
