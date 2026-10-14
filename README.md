# ⚡ SwiftCull - 照片快筛

<div align="center">
  <div>
    <a href="https://github.com/SAN-SHIa/SwiftCull/releases"><img alt="GitHub Release" src="https://img.shields.io/github/v/release/SAN-SHIa/SwiftCull?style=flat-square" /></a>
    <a href="https://github.com/SAN-SHIa/SwiftCull"><img alt="Platform: macOS 14.0+" src="https://img.shields.io/badge/macOS-14.0%2B-blue?style=flat-square" /></a>
    <a href="https://github.com/SAN-SHIa/SwiftCull/blob/main/LICENSE"><img alt="License: MIT" src="https://img.shields.io/github/license/SAN-SHIa/SwiftCull?style=flat-square" /></a>
    <a href="https://github.com/SAN-SHIa/SwiftCull"><img alt="GitHub Stars" src="https://img.shields.io/github/stars/SAN-SHIa/SwiftCull?style=flat-square" /></a>
    <a href="https://github.com/SAN-SHIa/SwiftCull"><img alt="项目访问量" src="https://komarev.com/ghpvc/?username=SAN-SHIa-SwiftCull&color=brightgreen&label=views&style=flat-square" /></a>
  </div>
  <br>
</div>

<p align="center">
  <img src="./imgs/post.png" alt="SwiftCull" />
</p>

> 一款为摄影师打造的 macOS 原生照片快速筛选工具。从 SD 卡里的数千张照片中，用最少的操作挑出该留的、删掉该删的。纯 SwiftUI + 系统原生框架，无第三方依赖。

---

## 📥 下载安装

前往 [Releases](https://github.com/SAN-SHIa/SwiftCull/releases) 页面下载最新版 `SwiftCull.dmg`，打开后将 SwiftCull 拖入 Applications 即可完成安装。

> [!IMPORTANT]
> 由于应用未经过 Apple 公证（Notarization），macOS 可能会阻止打开。请前往「系统设置 → 隐私与安全性」，点击「仍要打开」即可。

---

## 🎯 功能特性

- 🚀 **多维筛选** — 文件类型、评分、Finder 标签、文件名、拍摄日期，支持按月/日分组浏览
- 🔍 **大图审片** — 单图模式下捏合/双击/按钮缩放（最高 6×），放大后拖拽平移，切图自动复位
- 🏷️ **原生标签与评分** — 读取 Finder 标签并双向同步，批量编辑后「完成」才写入、「取消」即还原
- 🗑️ **配对删除与导出** — 自动关联 RAW+JPG+MOV，删除同步移入废纸篓
- 🖼️ **水印导出** — 15 种横拍、竖拍水印预设，可视化创建与编辑自定义预设，实时预览后输出到指定目录

### 水印导出

在筛选侧栏点击「加水印并导出…」，选取预设并查看当前照片的预览，选择输出目录后导出筛选结果。内置预设参照 [semi-utils](https://github.com/leslievan/semi-utils) 的 15 个模板：7 个横拍、7 个对应竖拍，以及独立的「尼康竖拍」。默认按每张照片的方向自动匹配对应模板；关闭自动匹配可固定使用选中的横拍或竖拍模板。SwiftCull 原生渲染器按其画布尺寸、文字位置、圆角、阴影与模糊布局绘制，并随应用打包了相机品牌 Logo（包括 Nikon）。模板中的字体由 macOS 系统字体替代，可能有轻微字形差异；素材来源与许可见 [第三方说明](THIRD_PARTY_NOTICES.md)。

水印输出为 JPEG。仅 RAW 筛选时使用 RAW 图像，其余模式优先使用 JPG；视频不参与水印导出。原始照片保持不变，已有同名输出会追加数字序号。普通「导出筛选结果」仍复制原文件。

点击「新建预设…」可从当前预设创建自定义布局；点击「编辑预设…」可修改已有的自定义预设。编辑内置预设时会另存为自定义副本。编辑器支持画布纯色或模糊背景、留白、底栏、照片圆角与阴影，以及相机、镜头、拍摄参数、日期、文件夹和自定义文字组件。每个组件可设置位置、字号、颜色、加粗与顺序，修改后即在当前照片上预览。自定义预设以 JSON 保存在用户的 Application Support/SwiftCull/WatermarkPresets 目录；删除预设不会删除已导出的照片。界面布局参考 [ExifShot](https://exifshot.com/about.html) 的画布与元数据标签编辑方式。

可用 `bash Tests/run-watermark-smoke.sh` 验证 15 种预设在横拍、竖拍上的渲染，以及自定义布局、持久化与 JPEG 输出。

---

## 📸 界面预览

<table>
  <tr>
    <td align="center" width="50%">
      <img src="./imgs/dark.jpeg" width="400" /><br/>
      <sub><b>深色模式</b></sub>
    </td>
    <td align="center" width="50%">
      <img src="./imgs/light.jpeg" width="400" /><br/>
      <sub><b>浅色模式</b></sub>
    </td>
  </tr>
</table>

---

## 🛠 系统要求

- macOS 14.0 (Sonoma) 或更高版本
- Xcode 16.0 或更高版本（仅源码构建时需要）

---

## 🏗 构建与运行

**方式一：直接下载 DMG（推荐）**

前往 [Releases](https://github.com/SAN-SHIa/SwiftCull/releases) 下载 `SwiftCull.dmg`。

<details>
<summary><strong>方式二：源码构建</strong></summary>

1. 克隆仓库：
   ```bash
   git clone git@github.com:SAN-SHIa/SwiftCull.git
   cd SwiftCull
   ```

2. 生成 Xcode 项目（需要 [XcodeGen](https://github.com/yonaskolb/XcodeGen)）：
   ```bash
   brew install xcodegen
   xcodegen generate
   ```

3. 构建并运行：
   ```bash
   # 使用快捷脚本（推荐）
   ./run.sh           # Debug 构建并启动
   ./run.sh release   # Release 构建
   ./run.sh dmg       # 打包 DMG 安装包
   ./run.sh clean     # 清理构建产物
   ./run.sh help      # 查看所有命令
   ```

   或在 Xcode 中打开：
   ```bash
   open SwiftCull.xcodeproj
   ```

> 修改、增删源文件后，记得重新运行 `xcodegen generate`（或 `./run.sh gen`）同步工程。

</details>

---

## ⌨️ 快捷键指南

<div align="center">

| 快捷键 | 说明 |
|:---|:---|
| `↑` `↓` `←` `→` | 按网格位置选择照片 |
| 拖拽框选 | 鼠标框选多张照片 |
| `Space` | Quick Look 预览 |
| `E` | 网格 / 大图切换 |
| `Q` | 完成并退出多选 |
| 双指捏合 | 缩放网格缩略图 |
| 大图缩放 | 捏合 / 双击 / `＋` `－` 缩放，拖拽平移 |
| `Tab` | 切换侧边栏 |
| `1`–`5` | 设置评分 |
| `0` | 清除评分 |
| `Delete` | 删除所选照片 |
| `A` | 全选当前筛选结果 |
| `Esc` | 退出多选 / 取消输入焦点 |
| `⌘O` | 打开文件夹 |

</div>

---

## 📄 许可证

SwiftCull 基于 [MIT License](./LICENSE) 开源。
