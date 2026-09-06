# 声渡 · StreamTranslate 图标设计 v1

设计稿：[streamtranslate-icon-v1.png](./streamtranslate-icon-v1.png)。

以两道相向流动的引号构成一个抽象的 S：声音被接住，越过语言的间隙，成为另一端的字幕。
黑底、暖白主体、大面积留白；右下的小朱红方点像一句话的落款。
无字标，避免语言和小尺寸排版限制。

使用内置 image_gen 生成并修订，未使用 CLI/API fallback。此 PNG 为未改动的设计母稿。
macOS 1.5.2 / build 19 已接入原生图标资源；菜单栏模板图标、网页和 iPhone 主屏幕
图标不在本次 Mac 图标安装的修改范围。

## macOS 资源构建

`Tools/BuildAppIcon.swift` 为批准后的母稿添加原生圆角蒙版与透明边距，输出 10 个
16–1024 像素的标准 iconset 资源。通过系统 iconutil 编译为
`StreamTranslate/Resources/StreamTranslate.icns`，由 Info.plist 的 CFBundleIconFile 引用。
CLI 打包脚本和 Xcode 工程都包含该资源；之后构建 DMG 也会沿用。

```sh
swift Tools/BuildAppIcon.swift design/app-icon/streamtranslate-icon-v1.png build/StreamTranslate.iconset
iconutil -c icns build/StreamTranslate.iconset -o StreamTranslate/Resources/StreamTranslate.icns
```

安装后使用 NSWorkspace 的系统图标解析路径输出预览，并检查朱红点，避免只检查源文件：

```sh
swift Tools/BuildAppIcon.swift --verify /Applications/StreamTranslate.app build/installed-app-icon.png
```

## 最终修订提示词

输入参考：本轮生成的两道相向引号、S 形流动轮廓和朱红点的初稿。

```text
Edit this logo into a pristine FLAT 2D app icon. Keep the recognizable two interlocking flowing quotation ribbon shapes, their overall arrangement, and one tiny red rounded-square punctuation accent. CRITICAL correction: completely remove ALL gray halos, ALL cast shadows, ALL noisy speckles and glow, ALL yellow or orange fringes, ALL bevels, ALL gradients and 3D lighting. Every pixel of the background must be uniform opaque near-black #111111; every pixel INSIDE the two main shapes must be uniform opaque ivory-white #F5F3EE; the one tiny red square must be uniform cinnabar #D63832. The ONLY intermediate colors permitted are clean edge antialiasing between these three flat fills. NO transparency anywhere. Make the main two white shapes a little smaller, combined silhouette occupies 58% of canvas width and 44% of canvas height, centered optically, leaving generous quiet black negative space on all sides. Refine the pointed folds to elegant softly rounded tapered terminals rather than knife points. Make the red square just 3% of canvas width, lightly rounded corners, aligned just to the lower right of the flowing white glyph with a small clear gap; no red outside this square. A contemplative black-and-white minimalist designer app identity, precision curves, flat graphic poster quality, extremely simple, no words or letters. Output one square finished icon, full bleed solid near-black to the edges, no surrounding presentation board or device or extra border.
```
