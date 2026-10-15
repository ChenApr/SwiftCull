# ⚡ SwiftCull - 照片快筛

<div align="center">
  <div>
    <a href="https://github.com/ChenApr/SwiftCull/releases"><img alt="GitHub Release" src="https://img.shields.io/github/v/release/ChenApr/SwiftCull?style=flat-square" /></a>
    <a href="https://github.com/ChenApr/SwiftCull"><img alt="Platform: macOS 14.0+" src="https://img.shields.io/badge/macOS-14.0%2B-blue?style=flat-square" /></a>
    <a href="https://github.com/ChenApr/SwiftCull/blob/main/LICENSE"><img alt="License: MIT" src="https://img.shields.io/github/license/ChenApr/SwiftCull?style=flat-square" /></a>
    <a href="https://github.com/ChenApr/SwiftCull"><img alt="GitHub Stars" src="https://img.shields.io/github/stars/ChenApr/SwiftCull?style=flat-square" /></a>
    <a href="https://github.com/ChenApr/SwiftCull"><img alt="项目访问量" src="https://komarev.com/ghpvc/?username=ChenApr-SwiftCull&color=brightgreen&label=views&style=flat-square" /></a>
  </div>
  <br>
</div>

<p align="center">
  <img src="./imgs/post.png" alt="SwiftCull" />
</p>

> 一款为摄影师打造的 macOS 原生照片快速筛选工具。从 SD 卡里的数千张照片中，用最少的操作挑出该留的、删掉该删的。纯 SwiftUI + 系统原生框架，无第三方依赖。

---

## 📥 下载安装

前往 [Releases](https://github.com/ChenApr/SwiftCull/releases) 页面下载最新版 `SwiftCull.dmg`，打开后将 SwiftCull 拖入 Applications 即可完成安装。

> [!IMPORTANT]
> 由于应用未经过 Apple 公证（Notarization），macOS 可能会阻止打开。请前往「系统设置 → 隐私与安全性」，点击「仍要打开」即可。

---

## 🎯 功能特性

- 🚀 **多维筛选** — 文件类型、评分、Finder 标签、文件名、拍摄日期，支持按月/日分组浏览
- 🔍 **大图审片** — 单图模式下捏合/双击/按钮缩放（最高 6×），放大后拖拽平移，切图自动复位
- 🏷️ **原生标签与评分** — 读取 Finder 标签并双向同步，批量编辑后「完成」才写入、「取消」即还原
- 🗑️ **配对删除与导出** — 自动关联 RAW+JPG+MOV，删除同步移入废纸篓
- 🖼️ **水印导出** — 15 种横拍与竖拍预设，支持逐张叠加预设并实时预览、指定目录导出，以及可视化创建和编辑自定义预设；文字组件可选内置字体，素材来源见[第三方说明](THIRD_PARTY_NOTICES.md)
- 🖱️ **右键与多选操作** — 评分、Finder 标签、复制原文件、Finder 显示、批量导出和水印导出
- ✂️ **非破坏性裁剪** — 支持自由、原始及常用固定比例，保存到当前版本或另存虚拟版本；预览、复制和导出使用所选版本
- 🎬 **视频播放** — 对含 MOV 的照片按 `V` 进入播放模式，使用原生视频控件；退出后恢复照片浏览快捷键
- 📷 **实况照片** — 从视频选取至多 3 秒片段与封面，导出配对的 HEIC+MOV 或添加到系统“照片”；视频和实况照片不参与裁剪

---

## 🧭 后续目标

1. **（P2）更多照片格式**：优先支持 PNG；随后补齐 CR3、RW2、HIF、NRW、ORF、PEF 的扫描、预览与导出，并逐一验证对应机型的 RAW 能否由 macOS 解码。
2. **（待确定和设计）Finder 风格导航**：在软件内支持前进、后退和文件夹打开。由于这会影响当前工作区、评分和标签筛选的生效范围，并可能引入较大的破坏性和冗余设计，暂不排期。

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

前往 [Releases](https://github.com/ChenApr/SwiftCull/releases) 下载 `SwiftCull.dmg`。

<details>
<summary><strong>方式二：源码构建</strong></summary>

1. 克隆仓库：
   ```bash
   git clone git@github.com:ChenApr/SwiftCull.git
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
| `Space` | 普通浏览时 Quick Look 预览；视频播放模式下播放 / 暂停 |
| `V` | 进入 / 退出当前照片的视频播放模式（照片须包含 MOV） |
| `P` | 在实况照片编辑器预览 / 停止当前选取片段；结束后回到预览前的位置 |
| `←` `→` | 视频播放模式下前后跳转 5 秒；`Shift` + 左右方向键逐帧 |
| `↑` `↓` | 视频播放模式下调节音量 |
| `E` | 网格 / 大图切换 |
| `C` | 裁剪单张照片 / 编辑当前版本（多选时不触发） |
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
| `⌘C` | 复制所选版本；裁剪后的照片可在 Finder 中粘贴 |

</div>

---

## 📄 许可证

SwiftCull 基于 [MIT License](./LICENSE) 开源。

MIT 许可允许你在自己的 fork 中使用、修改、合并、构建、发布和分发 SwiftCull，也允许发布自行修改后的版本。发布源码或包含原项目实质代码的分发包时，请保留原项目的版权声明和 MIT 许可文本；水印素材及其他第三方内容还需要同时遵守 [第三方说明](THIRD_PARTY_NOTICES.md) 中列出的许可。建议在 release 说明中明确列出你的修改，并不要暗示上游项目或其作者为你的版本背书。
