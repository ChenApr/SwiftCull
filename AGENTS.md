# SwiftCull 协作规范

本文件是项目协作规范的统一来源。`.agent/` 与 `.claude/` 中的入口引用本文件，通用规则只在此处维护。

## 产品原则

- 保持轻量、简洁、高效，优先保障浏览、标记、筛选与导出这一核心流程。
- 优先复用 SwiftUI、AppKit 与 macOS 系统框架；引入依赖时说明必要性及对体积、启动速度、维护成本的影响。
- 界面沿用现有组件、间距和交互约定；高级选项按需展开，避免增加默认界面的操作负担。
- 不因无关操作自动展开侧栏或改变用户布局；有意变更交互时说明触发条件。

## 开发约定

| 位置 | 职责 |
| --- | --- |
| `SwiftCull/Models/` | 数据模型与配置 |
| `SwiftCull/ViewModels/` | 界面状态与操作编排 |
| `SwiftCull/Services/` | 文件、元数据、图像、视频及持久化逻辑 |
| `SwiftCull/Views/` | SwiftUI 界面；共享控件放在 `Components/` |
| `Tests/` | 独立 Swift 冒烟测试及运行脚本 |
| `project.yml` | XcodeGen 工程配置来源 |

- 修改前检查 `git status` 与相关实现，保留其他协作者的改动；不覆盖、回退或顺带提交无关文件。
- 遵循邻近代码的命名与格式；避免为小改动引入无关重构或额外抽象。
- 主线程负责界面状态更新；文件扫描、图像解码及批量处理避免阻塞界面。异步结果应校验当前请求，支持取消过期工作。
- 缩略图与预览优先复用现有缓存及降采样管线，避免滚动时重复全量计算或解码原图。
- 裁剪保持非破坏性；评分、Finder 标签、关联文件及虚拟版本的写入范围必须明确。测试使用临时文件与隔离存储，不操作个人照片。
- 增删源文件或修改 `project.yml` 后运行 `bash run.sh gen`；不要直接维护生成的 `.xcodeproj`。
- 功能、快捷键、支持格式或构建方式变化时同步更新 README；新增第三方字体、素材或代码时补充许可声明。

## 构建与验证

运行环境为 macOS 14.0 及以上；开发需要完整 Xcode 与 XcodeGen。详细安装步骤见 [README](README.md#开发指南)。

```bash
bash run.sh gen     # 生成工程
bash run.sh build   # 构建 Debug
bash run.sh run     # 构建并打开应用
```

代码改动执行构建和与改动相关的检查；仅文档变更检查链接、格式与差异即可。

| 改动范围 | 验证命令 |
| --- | --- |
| 水印与边框 | `bash Tests/run-watermark-smoke.sh` |
| 文件操作范围 | `bash Tests/run-photo-action-scope-smoke.sh` |
| 裁剪与版本 | `bash Tests/run-crop-smoke.sh` |
| 缩略图管线 | `bash Tests/run-thumbnail-pipeline-smoke.sh` |
| 网格选择与导航 | `bash Tests/run-grid-interaction-smoke.sh` |
| 实况照片 | `bash Tests/run-live-photo-smoke.sh` |
| 数据完整性 | `bash Tests/run-data-integrity-smoke.sh` |

网格交互测试需要已登录的 macOS 桌面，会短暂打开窗口；实况照片测试需要 `ffmpeg`。界面变更还应检查相关交互、深浅色外观与布局。性能结论需说明测试场景和证据，不能用“构建通过”替代流畅度验证。

## Git 提交规则

- 每次 commit 前，先展示拟用的完整 commit message（标题及正文，如有），等待用户明确确认后再提交，无论是否推送远端。
- 用户要求提交代码，不等同于确认 commit message；确认后的 message 如有修改，须重新确认。
- 标题和正文均使用英文，简洁、专业、具体；标题使用祈使语气，格式为 `<前缀>: <简要描述>`。
- 正文仅在必要时添加，与标题空一行，每项使用 `- ` 开头。
- 前缀按用途选择：`feat`、`fix`、`perf`、`refactor`、`docs`、`style`、`test`、`chore`、`ci`、`revert`。
- 提交前检查暂存内容，只提交本次任务相关文件；推送与发布需有用户授权。

首次克隆后运行 `bash .agent/setup-git-hooks.sh`，在当前仓库启用 `.githooks/commit-msg`。脚本遇到已有自定义 hooks 时会保留配置并提示手动集成。

Hook 自动检查允许的前缀、标题描述、标题与正文间的空行，以及 `- ` 正文列表；标题和正文使用 ASCII 英文文本。它不能判断语义、祈使语气或用户是否确认，仍需人工遵守上述规则。Git 自动生成的合并、回滚信息也需整理为本项目格式。运行 `bash Tests/run-commit-message-smoke.sh` 可验证校验与安装行为（需要 Python 3）。

```text
perf: optimize photo preview loading

- Downsample previews, reuse cached images, and cancel stale requests.
- Validate with the app build and related tests.
```

## 沟通与交付

- 默认用中文，结论先行，精简、客观；必要时使用加粗、列表或表格。
- 推断说明依据；无法确认的行为或未执行的验证主动说明，不将预期写成已验证结果。
- 交付说明具体改动、验证结果及必要限制，避免冗长的过程记录。
