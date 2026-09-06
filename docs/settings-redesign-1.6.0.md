# 中文深色设置页（1.6.0 / build 20）

本次重新实现 macOS SettingsView，未修改音频、识别和翻译算法或手机网页。

## 设计

- 近黑背景、灰白文字与少量朱红选中标记，跟随「声渡」图标的颜色体系。
- 固定左侧分类导航，右侧独立滚动；声音与语言、字幕外观、识别与翻译、隐私与诊断四页。
- 无英文功能标题或混杂的英文提示句。模型/产品/技术名称可保留英文。
- 820×650 默认内容尺寸，720×540 最小尺寸，可以拖动窗口边缘调整。
- 音频来源卡片、可直接看到选项的语言选择；常用项与增强/诊断分开。
- 字号使用无密集刻度的滑杆，以示例中文预览实际字号（原文字号与译文字号减 1）。
  预览不使用当前字幕，不启动录音。
- 现有模型、语言、词汇、灵敏度、增强、译文中文版本、窗口尺寸及诊断设置全部保留。
  仍即时持久化，不添加多余的保存按钮。
- 菜单栏的设置入口、字幕记录、开始/停止、状态说明同步中文化。

## 安全与行为

- 不更改偏好存储键、模型 ID 或枚举 rawValue，不重置已有用户选择。
- 保留模型/语言绑定与切换守卫，录音、启动和收尾期间禁用相关设置。
- 仅手机显示时仍不能打开设置；设置窗口在字幕浮层上方，离开 App 时隐藏。
- 诊断默认值不变，明确警告包含原始音频与磁盘占用；本次未启动真实录音。
- Mac 窗口尺寸与字号仍作用于原有浮层，不改手机阅读偏好。

## 检查入口

- --settings-preview NEW_DIRECTORY：隔离 UserDefaults 的四页/两个尺寸原生离屏截图，
  不启动模型、监听器或音频。build/settings-preview-1.6/ 为第一轮，最终结果另存。
- Tools/SettingsInteractionProbe.swift：只检查已安装 App 的「设置」窗口；
  Command-comma 打开、分类导航、字号修改后恢复原值，不访问字幕内容或开启诊断。
- settingsInterfaceUsesConsistentChineseLabels：中文文案与持久化标识不变的回归。
- 核心测试记录：build/settings-redesign-tests.log。
- 安装记录：build/install-1.6.0-settings.log。

仅更新现有 App；旧安装按既有脚本保留用于回退。未重新发布 DMG。

## 本次验证结果

- 274 项可移植核心测试、0 失败（不是完整 Xcode Swift Testing runner）。
- 8 张最终原生截图：build/settings-preview-1.6-final/。
- 已安装 App 实际操作通过：四个分类、字号修改/原值恢复、Command-comma、
  窗口缩小/原尺寸恢复。记录在 build/settings-native-interaction.log。
- 系统原生控件的弹出选择框在初版离屏截图中出现黑字对比度问题，最终改为可直接
  看见全部选项的分段选择；真实安装截图确认白字与朱红选中态清晰。
- 实际安装窗口截图：build/settings-installed-1.6.0.png。
- 仅手机模式检查：visible=0、independentTranslationReady=true、pass=true；
  安装包 1.6.0/20 严格签名验证通过。
