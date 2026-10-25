# QuickShot

A tiny macOS menu bar screenshot tool. Press the hotkey (or click the icon), **drag to select, release to capture** — no resizing a selection box afterwards. Right-click captures the window under the cursor.

一个极简的 macOS 菜单栏截图工具：按快捷键（或点图标）就出十字光标，**直接拖动框选，松手即截图**，不用再调整选框；右键单击截取鼠标下的窗口。

## Features / 功能

- **Left-drag** selects a region, **right-click** captures the whole window under the cursor, `Esc` cancels
  左键拖动框选区域，右键单击截取整个窗口，Esc 取消
- A Liquid Glass hint follows the cursor; the window under the cursor gets a Liquid Glass outline that glides between windows (macOS 26+). The rest of the screen is left untouched.
  光标旁跟随液态玻璃提示；鼠标下的窗口用一整圈液态玻璃轮廓标出，切换窗口时轮廓滑过去（macOS 26+），屏幕其他地方不变暗
- Global hotkey, default `⌘⇧2`, customizable in Settings (no Accessibility permission needed)
  全局快捷键，默认 `⌘⇧2`，可在「设置…」里自定义（不需要辅助功能权限）
- Saved to `~/Pictures/Screenshots/` and copied to the clipboard (PNG)
  保存到 `~/Pictures/Screenshots/` 并复制到剪贴板（PNG）
- Floating thumbnail in the bottom-right: drag it into any app, right-click to delete, click to annotate
  右下角缩略图：可直接拖进其他 App，右键删除，单击打开标注
- Annotation window: pen / rectangle / ellipse / arrow, 6 colors, 3 widths, `⌘Z` undo — every stroke is synced to the clipboard and the file immediately; `⌘⌫` moves the screenshot to the Trash
  标注窗口：画笔 / 矩形 / 椭圆 / 箭头，6 种颜色、3 种粗细，⌘Z 撤销，每一笔实时同步到剪贴板和文件；⌘⌫ 删除（移到废纸篓）
- Launch at login (toggle in the menu)
  开机自动启动（菜单里勾选）

## Build / 安装

Requires the Xcode command line tools (`xcode-select --install`). Liquid Glass effects need macOS 26 or later; older systems fall back to a blur material.

需要 Xcode 命令行工具。液态玻璃效果需要 macOS 26 及以上，旧系统会退回毛玻璃。

```bash
./setup-signing.sh   # once: creates a local code-signing certificate in your login keychain
                     # 只需一次：在登录钥匙串里生成本机签名证书
./build.sh
```

`setup-signing.sh` keeps the app's code signature identical across rebuilds, so the Screen Recording permission survives every rebuild. Without it the build is ad-hoc signed, and macOS asks for the permission again after each rebuild.

`setup-signing.sh` 让每次编译出来的签名身份保持不变，屏幕录制权限授权一次就一直有效；不运行的话会用临时签名，每次重新编译都要重新授权。

This builds and installs `~/Applications/QuickShot.app` and launches it. On the first capture, allow QuickShot under **System Settings → Privacy & Security → Screen & System Audio Recording**.

会编译并安装到 `~/Applications/QuickShot.app` 并启动。首次截图时按提示在「系统设置 → 隐私与安全性 → 屏幕与系统录音」中允许 QuickShot。

## Performance notes / 性能说明

The selection overlay is built once at launch and reused, all moving parts are plain `CALayer`s composited on the GPU, and the glass outline is animated with layer transforms (the glass shape is recomputed once it settles). Settings has an option to recompute the glass shape on every frame instead — more accurate highlights, more CPU.

选区遮罩启动时建好并复用；动画全部用 GPU 合成的普通图层；玻璃轮廓移动时用图层变换，停稳后再按真实尺寸重算。设置里可以打开“移动时实时重算玻璃形状”，边缘高光更准，但更耗 CPU。

## License

MIT
