# Third-Party Notices

SwiftCull 使用以下第三方素材、字体及改编代码。各组件适用其原始许可证；项目根目录的 [MIT License](LICENSE) 不替代这些许可。原始版权声明与许可全文保存在下列文件中。

## 水印素材与布局

| 项目 | 说明 |
| --- | --- |
| 来源 | [leslievan/semi-utils](https://github.com/leslievan/semi-utils) |
| 使用内容 | `config/logos` 中的品牌图像；参考 `config/templates` 与 `processor` 的预设布局及处理顺序 |
| SwiftCull 实现 | 品牌图像位于 `SwiftCull/Resources/WatermarkLogos/`；布局与渲染使用 macOS 原生框架重新实现 |
| 许可证 | Apache License 2.0 |
| 许可全文 | [LICENSE.semi-utils](SwiftCull/Resources/WatermarkLogos/LICENSE.semi-utils) |

现有素材来源记录未包含固定的上游提交号。品牌名称与标志归各自权利人所有；项目许可证不构成品牌方对 SwiftCull 的认可或背书。

## 实况照片代码

| 项目 | 说明 |
| --- | --- |
| 来源 | [GavinHarbus/Video2Live](https://github.com/GavinHarbus/Video2Live) |
| 使用内容 | 参考并改编 HEIC/MOV 配对元数据写入实现 |
| SwiftCull 实现 | `SwiftCull/Services/LivePhotoService.swift`、`SwiftCull/Services/LivePhotoMOVWriter.swift` |
| 版权声明 | Copyright (c) 2026 Gavin Schnee |
| 许可证 | MIT License |
| 许可全文 | [LICENSE.Video2Live](SwiftCull/Resources/LivePhoto/LICENSE.Video2Live) |

现有代码来源记录未包含固定的上游提交号。

## 随应用分发的字体

以下 18 款字体以 SIL Open Font License 1.1 分发。字体文件位于 `SwiftCull/Fonts/`；各自的原始版权声明、保留字体名称及许可全文见对应文件。

| 字体 | 字体文件 | 版权与许可 |
| --- | --- | --- |
| Allura | `Allura.ttf` | [allura-OFL.txt](SwiftCull/Fonts/Licenses/allura-OFL.txt) |
| Caveat | `Caveat.ttf` | [caveat-OFL.txt](SwiftCull/Fonts/Licenses/caveat-OFL.txt) |
| Dancing Script | `DancingScript.ttf` | [dancingscript-OFL.txt](SwiftCull/Fonts/Licenses/dancingscript-OFL.txt) |
| Great Vibes | `GreatVibes.ttf` | [greatvibes-OFL.txt](SwiftCull/Fonts/Licenses/greatvibes-OFL.txt) |
| KN Maiyuan（荆南麦圆体） | `KNMaiyuan.ttf` | [knmaiyuan-OFL.txt](SwiftCull/Fonts/Licenses/knmaiyuan-OFL.txt) |
| Liu Jian Mao Cao（刘建毛草） | `LiuJianMaoCao.ttf` | [liujianmaocao-OFL.txt](SwiftCull/Fonts/Licenses/liujianmaocao-OFL.txt) |
| Long Cang（龙藏体） | `LongCang.ttf` | [longcang-OFL.txt](SwiftCull/Fonts/Licenses/longcang-OFL.txt) |
| LXGW Marker Gothic（霞鹜漫黑） | `LXGWMarkerGothic.ttf` | [lxgwmarkergothic-OFL.txt](SwiftCull/Fonts/Licenses/lxgwmarkergothic-OFL.txt) |
| LXGW WenKai（霞鹜文楷） | `LXGWWenKai.ttf` | [lxgwwenkai-OFL.txt](SwiftCull/Fonts/Licenses/lxgwwenkai-OFL.txt) |
| Ma Shan Zheng（马善政毛笔楷书） | `MaShanZheng.ttf` | [mashanzheng-OFL.txt](SwiftCull/Fonts/Licenses/mashanzheng-OFL.txt) |
| Merriweather | `Merriweather.ttf` | [merriweather-OFL.txt](SwiftCull/Fonts/Licenses/merriweather-OFL.txt) |
| Noto Sans SC | `NotoSansSC.ttf` | [notosanssc-OFL.txt](SwiftCull/Fonts/Licenses/notosanssc-OFL.txt) |
| Noto Serif SC | `NotoSerifSC.ttf` | [notoserifsc-OFL.txt](SwiftCull/Fonts/Licenses/notoserifsc-OFL.txt) |
| Pacifico | `Pacifico.ttf` | [pacifico-OFL.txt](SwiftCull/Fonts/Licenses/pacifico-OFL.txt) |
| Parisienne | `Parisienne.ttf` | [parisienne-OFL.txt](SwiftCull/Fonts/Licenses/parisienne-OFL.txt) |
| Roboto | `Roboto.ttf` | [roboto-OFL.txt](SwiftCull/Fonts/Licenses/roboto-OFL.txt) |
| Sacramento | `Sacramento.ttf` | [sacramento-OFL.txt](SwiftCull/Fonts/Licenses/sacramento-OFL.txt) |
| Zhi Mang Xing（志莽行书） | `ZhiMangXing.ttf` | [zhimangxing-OFL.txt](SwiftCull/Fonts/Licenses/zhimangxing-OFL.txt) |

### 来源版本

| 字体来源 | 本项目记录的版本 |
| --- | --- |
| [Google Fonts](https://github.com/google/fonts)（除下列三款外的 15 款字体） | 提交 `954e256c4277419b5e48bffa51be069b2bd01bde` |
| [LXGW WenKai](https://github.com/lxgw/LxgwWenKai) | 提交 `a06dd23142e82758f23f792f4060bbf1613286e8` |
| [LXGW Marker Gothic](https://github.com/lxgw/LxgwMarkerGothic) | 发布版本 `v1.004` |
| [KN Maiyuan](https://github.com/maoken-fonts/KNMaiyuan) | 发布版本 `v1.20` |

## 系统字体

Times New Roman、Georgia、Arial、宋体（Songti SC）与苹方（PingFang SC）仅在用户设备已安装时调用，不随 SwiftCull 分发。

## 应用包内的声明

构建后的 `SwiftCull.app/Contents/Resources/` 包含项目 `LICENSE`、本文件、`LICENSE.semi-utils`、`LICENSE.Video2Live` 及每款字体的 `*-OFL.txt`。本文件中的相对链接用于浏览源代码仓库；应用包内的许可文件按上述文件名查找。
