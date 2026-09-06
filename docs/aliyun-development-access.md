# 阿里云开发连接准备（2026-09-06）

仓库版本已将账号、实例及现有业务名称替换为示例值。策略 JSON 中的
YOUR_ACCOUNT_ID / YOUR_INSTANCE_ID 必须替换后才能使用，地域也应与实例一致。
真实部署原件仅保留在本机忽略的 build/github-local-config-20260906/ 中。

用户提供杭州 ECS 配置和官方 Workbench CLI 安装命令，允许尝试建立开发连接。2026-09-06 15:34（Asia/Shanghai）已成功登录并完成初步只读检查。随后用户授权自主选择便捷方案，已完成公网字幕中转部署和本机 1.5.0 更新；见 `docs/remote-companion-1.5.0.md`。Workbench 只是开发运维通道，不是手机字幕运行时链路。下文保留此前权限排查的时间顺序。

## 已完成

- 核对阿里云官方安装与连接文档，下载后完整阅读安装脚本，再执行保存的同一份脚本。
- 脚本副本：`build/workbench-install-reviewed.sh`；SHA-256：`f84181df07db78635e828acc37c027dbf97eb01ca052c2154b6b5e866bc2f0ca`。
- 通过官方脚本的 SHA-256 校验后安装 macOS arm64 Workbench v1.0.1（commit 86c0aff）到 `/Users/xxx/.local/bin/workbench`，没有使用 sudo、改 shell 配置或覆盖现有 workbench。
- 安装日志：`build/workbench-install.log`。`version`、`config --help`、`exec --help` 正常。
- 使用专用 profile `streamtranslate` 对截图指定实例尝试执行只读 `uname -s`，CLI 在本地以退出码 4 拒绝：缺少 `/Users/xxx/.workbench/config.json`。没有成功登录或执行任何远程命令，没有修改服务器。

## 后续实测：凭据已配置，云端权限阻塞

用户明确授权使用其开发凭据后，通过 CLI 交互输入配置了专用
`streamtranslate` profile；未把密钥写入项目或 shell 命令参数。
已检查本地凭据文件权限为 0600，目录为 0700，不输出凭据内容。

Workbench v1.0.1 存在此次环境可复现的启动问题：只有专用 profile 时，
`exec` 报 daemon 启动超时；前台 `daemon start --profile streamtranslate`
明确报 `profile "default" not found in config`。在此前没有默认 profile 的
配置中增加相同开发凭据的 `default` profile 后，后台进程正常启动。
该兼容配置只在本机 Workbench 中，未修改系统服务或项目设置。

两项云端实测结果：

- 按截图实例名过滤的 `list ecs` 返回 HTTP 403 `Forbidden.RAM`，
  `AuthAction=ecs:DescribeInstances`、`AuthPrincipalType=SubUser`、
  `NoPermissionType=ImplicitDeny`。CLI 实际要求 `--limit` 最少为 10，
  与文档写的 1 不一致；查询仍限定精确实例名，没有列举其他实例。
- 对指定实例执行只读 `uname -s` 的登录步骤返回 HTTP 403
  `NoPermission.CreateWorkbenchSLR`，明确缺少
  `ram:CreateServiceLinkedRole`，服务为 `workbench.ecs.aliyuncs.com`，
  角色为 `AliyunServiceRoleForECSWorkbench`。远程命令没有执行。

当时需要账号管理员完成 Workbench 服务关联角色的首次授权，并补充
查询实例权限。可由主账号/有权限的管理员在 Workbench 控制台完成服务
关联角色授权，无需把管理整个 RAM 的权限授予开发子账号。另提供
`docs/aliyun-workbench-bootstrap-policy.json` 的初版仅包含当时已证实缺失的两项
操作；角色创建以服务名条件限制。此文件只是待管理员审核的策略，
没有调用 RAM API 创建/绑定策略，也不保证它覆盖后续所有连接步骤。
`DescribeInstances` 使用官方示例的资源 `*`，意味着它不是仅限一台
实例的查询权限；不能把它描述成实例级最小授权。

没有授予 `AdministratorAccess`、`ecs-workbench:*` 或 AI 助手的
`ChatMessages` 权限，没有读取远程业务数据、部署文件或更改服务器配置。
公网字幕中转仍未实现、未部署，Mac 已安装的局域网版本未被替换。

权限补齐后，先重试相同实例的只读检查，核实身份、内存/磁盘余量、
监听端口、已有服务与域名。不要直接停服务、重启、改安全组、覆盖站点
配置或把已有 HTTP 字幕端口暴露到公网。字幕中转独立部署，并在任何
与现有业务冲突的修改前确认。

## 用户绑定策略后的复测

用户创建并绑定 `translate` 策略后，精确实例名过滤的查询已成功：
`YOUR_INSTANCE_NAME`，`YOUR_INSTANCE_ID`，杭州，Running，
公网地址与截图一致。查询权限已生效，不再要求重新绑定初版策略。

随后相同 `uname -s` 登录测试返回 HTTP 403 `Forbidden.Unauthorized`，
`AuthAction=ecs-workbench:LoginECSInstance`。首次角色创建权限的错误不再出现，
但尚未进入远程 shell，也未验证远程资源和服务。

已按 Workbench 官方 CLI 文档更新上述 JSON 文件，待用户编辑已绑定的
`translate` 策略并设为默认版本后再测试；没有自行操作 RAM 权限。
修订加入登录、云助手状态、终端连接和会话关闭四项权限，不再仅逐项
补充报错。登录及终端连接限定此账号的杭州目标实例，不使用
`ecs-workbench:*`、`ecs:*`、ChatMessages 或管理员策略。

此前依据国际站 CLI 文档为 `LoginECSInstance` 写了 `:ecs/<instance>`，
但用户提供的实际鉴权诊断已证明这一格式不匹配当前接口（见下面的更正）。
不要再复制这个已被实测否定的格式，也不要与老网页 `LoginInstance` 的
`acs:ecs-workbench:...:workbench/...` 混用。

`DescribeInstances` 仍允许账号范围的实例查询，`EndSessions` 按官方
示例保留 `Resource: *`，具有范围更广的会话关闭权限；不是所有操作都
限定单实例。运维时只关闭本次创建的会话，不调用 close --all。

## 鉴权资源已定位：修正登录 Resource

用户截图确认 v2 已是当前版本，策略包含提供的登录 Action，因此不是
用户遗漏版本切换。复测仍返回 `LoginECSInstance` 的隐式拒绝。
只读调用 `ram:DecodeDiagnosticMessage` 同样返回 403 `NoPermission`；
没有为诊断自行扩大 RAM 权限，转由用户用主账号打开官方问题诊断。

用户展开「更多信息」后的诊断截图显示，这次请求的实际鉴权资源为：

```text
acs:ecs:cn-hangzhou:YOUR_ACCOUNT_ID:instance/YOUR_INSTANCE_ID
```

这与原先登录语句中的 `:ecs/` 不同。现已将本地 JSON 中
`ecs-workbench:LoginECSInstance` 的 Resource 改为上述 `:instance/` 地址，
其他语句不变，没有增加通配符或授权动作。以实际诊断为准：本次登录、
云助手状态及终端连接都使用同一个 `:instance/` ARN。

这是提供策略时的配置错误，不应再归因于用户操作。云端策略仍需用户
保存该单行修正并设为默认后复测；本地 JSON 校验成功不代表远程登录成功。
截至此次定位，仍未进入服务器 shell，未部署公网中转或修改现有业务。

## 修正后的连接成功与只读检查（15:34）

用户应用修正后的完整策略后，对目标实例执行 `uname -s` 成功，退出码 0、
输出 `Linux`。随后检查的结果如下（均为检查时快照，不代表长期负载）：

- 登录身份为 root；后续运行字幕服务应使用独立的低权限运行身份。
- `free -h`：系统可见内存 1.6 GiB，可用约 1.2 GiB；Swap 4.0 GiB，
  已用约 291 MiB，不能声称机器从未发生内存压力。
- 根盘 40 GiB，已用 32 GiB，可用 5.3 GiB，使用率 86%。不清理现有业务
  文件，不在该机下载识别/翻译模型或引入不必要的大型镜像。
- Node v22.22.1、Docker、Nginx 已存在。
- 已有其他业务的 API 和 worker 容器；API 绑定回环地址 8765。
- Nginx 已有其他业务站点，监听 80、8080；只筛选读取
  listen/server_name/证书配置指令，没有输出完整配置或读取应用环境密钥。
- 当前监听检查没有 443；启用站点的 server_name 仅看到 `_` 和公网 IP，
  没有看到域名或 SSL 证书配置。不能据此断言用户没有其他域名或证书。
- 预期的 `/opt/streamtranslate-relay`、`/srv/streamtranslate-relay` 尚不存在。

权限阻塞已解决，不再要求用户修改 Key 或扩大 RAM 权限。下一步需确定
手机访问的 HTTPS 地址及证书方案，并将中转服务与现有站点隔离。尚未
安装依赖、上传服务、重启/重载 Nginx、改安全组或开启公网字幕传输。

官方参考：

- [安装和凭据配置](https://help.aliyun.com/en/ecs/user-guide/install-and-configure-workbench-cli-credentials)
- [远程命令与文件传输](https://help.aliyun.com/zh/ecs/user-guide/use-workbench-cli-to-manage-ecs-instances)
- [CLI 权限动作和不同资源 ARN](https://www.alibabacloud.com/help/en/ecs/user-guide/install-and-configure-workbench-cli-credentials)
- [云助手状态接口授权资源](https://help.aliyun.com/zh/ecs/api-describecloudassistantstatus)
- [终端连接接口授权资源](https://help.aliyun.com/en/ecs/developer-reference/api-ecs-2014-05-26-startterminalsession)
