# ChenApr PR 集成与数据完整性修复

## 集成范围

集成 #9–#19：水印预设、右键与多选操作、无损裁剪版本、侧栏布局、视频播放、Live Photo 导出、内置字体、多层水印、空目录提示、性能重构及旧协作规则清理。保留各 PR 的提交历史，按依赖顺序合并；处理字体、水印、裁剪及性能分支的冲突。README 下载与源码链接继续指向 SAN-SHIa/SwiftCull。

## 行为修复

- 删除按实际文件操作结果更新。失败文件保持可见，部分成功时只移除已成功处理的路径，错误会显示在“操作结果”中；磁盘操作期间避免重复确认。切换目录后，旧删除任务不会修改新目录的同名照片。
- 裁剪目录在移入废纸篓时保留。恢复原文件到原目录、保持原文件名并刷新后，可以恢复裁剪版本。明确删除虚拟版本仍会移除对应记录。
- 评分缓存按标准化目录路径及源照片名隔离。原有 `.swiftcull/metadata.json` 是可信的目录级数据，加载时自动写入新版缓存，显式 0 星同样有效。
- 旧版仅按文件名保存的 UserDefaults 键不再自动套用：无法确认它属于哪个目录。旧键保留不删除；有 sidecar 的评分会自动恢复，只有旧全局缓存而没有 sidecar 的评分需要用户重新确认，不能安全自动迁移。
- 每个目录单独延迟保存 sidecar；切换目录、刷新及正常退出时 flush。写入失败的快照保留待重试，读取时优先返回该快照，避免用旧磁盘数据覆盖最近编辑。
- Finder 标签同步覆盖 JPG、RAW 和 MOV，纯视频也可写入。空路径不报告成功；失败时显示受影响文件名并重新读取磁盘实际标签。

## 验证

在 macOS 上执行：

```bash
xcodegen generate
bash run.sh build
bash run.sh release
bash Tests/run-watermark-smoke.sh
bash Tests/run-photo-action-scope-smoke.sh
bash Tests/run-crop-smoke.sh
bash Tests/run-thumbnail-pipeline-smoke.sh
bash Tests/run-live-photo-smoke.sh
bash Tests/run-data-integrity-smoke.sh
```

Live Photo 测试需要 ffmpeg。数据完整性测试使用生成的临时文件、隔离的 UserDefaults 和裁剪目录；成功删除通过临时目录内移动模拟，不操作用户照片或系统废纸篓。实际 MOV 标签测试读写临时文件的扩展属性。

CI 包含以上六组冒烟测试。真实 SD 卡、大型 RAW 照片库和完整 GUI 交互仍需实际场景验收。
