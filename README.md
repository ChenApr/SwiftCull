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

在筛选侧栏点击「加水印并导出…」，可以逐张浏览当前筛选结果的水印预览。每张照片可独立选择内置或自定义预设、决定是否按方向匹配，并勾选是否导出；也可将当前预设应用到全部照片。右侧照片详情的「操作」区提供单张水印导出入口。选定输出目录后仅处理已勾选的照片。内置预设参照 [semi-utils](https://github.com/leslievan/semi-utils) 的 15 个模板：7 个横拍、7 个对应竖拍，以及独立的「尼康竖拍」。SwiftCull 原生渲染器按其画布尺寸、文字位置、圆角、阴影与模糊布局绘制，并随应用打包了相机品牌 Logo（包括 Nikon）。模板中的字体由 macOS 系统字体替代，可能有轻微字形差异；素材来源与许可见 [第三方说明](THIRD_PARTY_NOTICES.md)。

水印输出为 JPEG。仅 RAW 筛选时使用 RAW 图像，其余模式优先使用 JPG；视频不参与水印导出。原始照片保持不变，已有同名输出会追加数字序号。普通「导出筛选结果」仍复制原文件。

点击「新建预设…」可从当前预设创建自定义布局；点击「编辑预设…」可修改已有的自定义预设。编辑内置预设时会另存为自定义副本。编辑器支持画布纯色或模糊背景、留白、底栏、照片圆角与阴影，以及相机、镜头、拍摄参数、日期、文件夹和自定义文字组件。每个组件可设置位置、字号、颜色、加粗与顺序，修改后即在当前照片上预览。自定义预设以 JSON 保存在用户的 Application Support/SwiftCull/WatermarkPresets 目录；删除预设不会删除已导出的照片。界面布局参考 [ExifShot](https://exifshot.com/about.html) 的画布与元数据标签编辑方式。

在网格照片、右侧详情缩略图或单张大图上右键，可以设置评分与 Finder 标签、复制原文件、在 Finder 中显示源文件、导出该照片的所有原始格式文件、单张加水印导出或将照片移至废纸篓。单张大图缩放和平移后仍可右键操作。在网格中选中一张或多张照片后按 ⌘C，也会复制选中照片的 JPG、RAW、MOV 原文件，可在 Finder 中粘贴；右键未选中的照片只复制该张。搜索框等文字输入区域仍使用系统的文字复制。

可用 `bash Tests/run-watermark-smoke.sh` 验证 15 种预设在横拍、竖拍上的渲染，以及自定义布局、持久化与 JPEG 输出。

---

## 🧭 维护方式与路线图

这是基于上游 SwiftCull 的个人 fork。个人 fork 可以先在自己的 `main` 分支上整合多个功能分支、构建和发布版本，再按功能拆分提交上游 PR。为了方便同步和审查，功能分支应保持边界清晰，合并到个人 `main` 前完成本地构建与回归测试；提交上游时优先从对应功能分支或从个人 `main` 中拆出的独立提交发起 PR。

当前维护中的功能包括：

- `feature/watermark-presets-gui`：水印预设、逐张预览、自定义预设编辑与水印导出。
- `feature/photo-context-menu`：网格多选范围、右键操作、原文件复制、所选照片导出与布局裁切修复。

后续目标：

1. **（P0）预览裁剪**：在保留原片的前提下支持裁剪；裁剪结果可随时恢复为原片，也可以在首次裁剪范围的基础上向外扩展。所有导出、加水印导出和复制默认基于裁剪后的照片；需要原片时由用户先撤回或取消裁剪。
2. **（P1）视频播放**：在应用内直接播放视频。
3. **（P1）从视频截取实况照片**：支持从视频中截取并保存实况照片。
4. **（P2）自定义文字字体**：水印自定义文字支持更多美观字体。
5. **（P2）水印配置叠加**：允许同时应用多个水印配置，例如将照片内签名与带 EXIF 信息的照片边框叠加。
6. **（待确定和设计）Finder 风格导航**：在软件内支持前进、后退和文件夹打开。由于这会影响当前工作区、评分和标签筛选的生效范围，并可能引入较大的破坏性和冗余设计，暂不排期。

路线图中的优先级表示维护顺序，具体实现方式和发布时间会在功能设计与验证后调整。

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

MIT 许可允许你在自己的 fork 中使用、修改、合并、构建、发布和分发 SwiftCull，也允许发布自行修改后的版本。发布源码或包含原项目实质代码的分发包时，请保留原项目的版权声明和 MIT 许可文本；水印素材及其他第三方内容还需要同时遵守 [第三方说明](THIRD_PARTY_NOTICES.md) 中列出的许可。建议在 release 说明中明确列出你的修改，并不要暗示上游项目或其作者为你的版本背书。
