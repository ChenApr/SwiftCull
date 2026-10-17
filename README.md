# SwiftCull · macOS 照片筛选工具

<p align="center">
  <a href="https://github.com/SAN-SHIa/SwiftCull/releases"><img src="https://img.shields.io/github/v/release/SAN-SHIa/SwiftCull?style=flat-square" alt="最新版本" /></a>
  <img src="https://img.shields.io/badge/macOS-14.0%2B-blue?style=flat-square" alt="系统要求：macOS 14.0 及以上" />
  <a href="https://github.com/SAN-SHIa/SwiftCull/actions/workflows/build.yml"><img src="https://github.com/SAN-SHIa/SwiftCull/actions/workflows/build.yml/badge.svg" alt="构建状态" /></a>
  <a href="https://github.com/SAN-SHIa/SwiftCull/blob/main/LICENSE"><img src="https://img.shields.io/github/license/SAN-SHIa/SwiftCull?style=flat-square" alt="项目代码许可证：MIT" /></a>
  <a href="https://github.com/SAN-SHIa/SwiftCull/stargazers"><img src="https://img.shields.io/github/stars/SAN-SHIa/SwiftCull?style=flat-square&amp;label=stars" alt="GitHub Stars" /></a>
  <img src="https://komarev.com/ghpvc/?username=SAN-SHIa-SwiftCull&amp;color=brightgreen&amp;label=views&amp;style=flat-square" alt="项目访问量" />
</p>

<p align="center">
  <img src="./imgs/post.png" alt="SwiftCull 照片筛选界面" />
</p>

SwiftCull 是面向摄影工作流的 macOS 原生应用，提供照片浏览、筛选、评分、Finder 标签、非破坏性裁剪和水印导出，并支持视频播放及实况照片制作。

应用基于 SwiftUI 与 macOS 系统框架构建。第三方字体、素材及改编代码的来源与许可见[第三方声明](THIRD_PARTY_NOTICES.md)。

## 下载与安装

前往 [Releases](https://github.com/SAN-SHIa/SwiftCull/releases) 下载 `SwiftCull.dmg`，打开后将应用拖入“应用程序”文件夹。

> [!NOTE]
> 未经 Apple 公证的构建可能被 macOS 安全检查拦截。确认文件来自本仓库的 Releases 页面后，可前往“系统设置 → 隐私与安全性”查看相关提示。

## 主要功能

| 功能 | 说明 |
| --- | --- |
| 浏览与筛选 | 按文件类型、评分、Finder 标签、文件名及拍摄日期筛选；支持按月或按日分组，以及最高 6 倍的大图缩放。 |
| 评分与标签 | 评分按照片目录保存，Finder 标签同步至关联文件；支持批量标注、确认保存和取消修改。 |
| 多选与文件操作 | 提供右键菜单、框选、复制、导出及移至废纸篓操作；关联同目录下同名的照片与视频文件。 |
| 裁剪与版本 | 支持自由、原始比例、1:1、3:2、4:3 和 16:9 裁剪，可更新当前版本或创建虚拟副本；预览、复制与导出使用所选版本。 |
| 水印导出 | 提供 15 种横竖版预设、内置字体、文字和图片组件；支持自定义布局、多层叠加、逐张预览及批量导出。 |
| 视频与实况照片 | 支持视频播放、跳转、逐帧查看及音量控制；可选取 0.5–3 秒片段和封面，导出 HEIC + MOV，或添加到系统“照片”。 |

裁剪不会修改原始文件。未裁剪时按所选范围复制原文件；裁剪后的 RAW 文件以 TIFF 输出，水印照片以 JPEG 输出。视频及关联视频的照片不参与裁剪。将原文件恢复到原目录并保持原文件名后，刷新即可重新加载保留的裁剪版本。

### 文件格式

| 类型 | 当前扫描支持 |
| --- | --- |
| 常规图像 | JPEG、HEIC、HEIF、TIFF |
| RAW | NEF、CR2、ARW、DNG、RAF |
| 视频 | MOV、MP4、AVI |

RAW 解码和视频播放取决于 macOS 对相应相机格式及编码的支持。PNG、CR3 等格式尚未纳入当前扫描范围。

## 界面预览

<table>
  <tr>
    <td align="center" width="50%">
      <img src="./imgs/dark.jpeg" width="400" alt="SwiftCull 深色模式" /><br />
      <sub><b>深色模式</b></sub>
    </td>
    <td align="center" width="50%">
      <img src="./imgs/light.jpeg" width="400" alt="SwiftCull 浅色模式" /><br />
      <sub><b>浅色模式</b></sub>
    </td>
  </tr>
</table>

## 系统要求

- **运行应用**：macOS 14.0（Sonoma）或更高版本。
- **源码构建**：完整安装的 Xcode，以及 [XcodeGen](https://github.com/yonaskolb/XcodeGen)。当前集成版本已在 Xcode 26.2 下完成构建验证。

## 源码构建

使用 [Homebrew](https://brew.sh/) 安装 XcodeGen 后，生成工程并启动应用：

```bash
git clone https://github.com/SAN-SHIa/SwiftCull.git
cd SwiftCull
brew install xcodegen
xcodegen generate
bash run.sh run
```

也可执行 `open SwiftCull.xcodeproj`，在 Xcode 中构建与调试。

| 命令 | 用途 |
| --- | --- |
| `bash run.sh build` | 构建 Debug 版本 |
| `bash run.sh release` | 构建 Release 版本 |
| `bash run.sh dmg` | 构建并打包 DMG |
| `bash run.sh gen` | 根据 `project.yml` 重新生成 Xcode 工程 |
| `bash run.sh clean` | 清理构建产物 |
| `bash run.sh help` | 查看脚本用法 |

增删源文件或修改 `project.yml` 后，请重新生成 Xcode 工程。

### 开发验证

构建通过后，可运行以下冒烟测试。实况照片测试需要 `ffmpeg`（`brew install ffmpeg`）；数据完整性测试使用临时文件和隔离存储。

```bash
bash Tests/run-watermark-smoke.sh
bash Tests/run-photo-action-scope-smoke.sh
bash Tests/run-crop-smoke.sh
bash Tests/run-thumbnail-pipeline-smoke.sh
bash Tests/run-live-photo-smoke.sh
bash Tests/run-data-integrity-smoke.sh
```

## 快捷键与手势

### 照片浏览

| 操作 | 说明 |
| --- | --- |
| `⌘O` | 打开文件夹 |
| 方向键 | 按网格位置切换当前照片 |
| `E` | 切换网格与大图视图 |
| `Space` | 使用 Quick Look 预览 |
| `C` | 裁剪当前单张照片或编辑所选版本 |
| `1`–`5` / `0` | 设置评分 / 清除评分 |
| `A` 或 `⌘A` | 全选当前筛选结果 |
| `Q` / `Esc` | 确认多选模式中的批量标注 / 取消未提交的批量标注并退出多选；输入框聚焦时，`Esc` 取消输入焦点 |
| `⌘C` | 复制所选版本，可在 Finder 中粘贴；裁剪版本会先生成对应文件 |
| `Delete` | 请求将所选照片的关联文件移至废纸篓，确认后执行 |
| `Tab` | 显示或隐藏侧边栏 |

鼠标拖拽可框选多张照片，双指捏合可调整网格缩略图大小。大图视图支持捏合、双击或使用 `＋` / `－` 缩放，并可拖拽平移。

### 视频与实况照片

以下视频快捷键在视频播放模式下生效；实况照片预览快捷键仅在对应编辑器中生效。

| 操作 | 说明 |
| --- | --- |
| `V` | 进入或退出当前关联视频的播放模式 |
| `Space` | 播放或暂停视频 |
| `←` / `→` | 后退或前进 5 秒 |
| `Shift` + `←` / `→` | 逐帧查看 |
| `↑` / `↓` | 调高或调低音量 |
| `Esc` | 退出视频播放模式 |
| `P` | 在实况照片编辑器中预览或停止所选片段，结束后返回预览前的位置 |

## 后续规划

- **扩展格式支持**：优先考虑 PNG，再逐步验证 CR3、RW2、HIF、NRW、ORF、PEF 等格式的扫描、解码与导出。
- **目录导航**：评估应用内前进、后退及文件夹导航；需先明确目录切换与标注、筛选状态的关系，目前尚未排期。

## 许可证

SwiftCull 的项目代码以 [MIT License](LICENSE) 开源。第三方字体、素材与改编代码适用各自的许可证，来源及许可全文见[第三方声明](THIRD_PARTY_NOTICES.md)。
