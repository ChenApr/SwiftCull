# 第三方素材说明

`SwiftCull/Resources/WatermarkLogos` 中的相机品牌图像复制自
[leslievan/semi-utils](https://github.com/leslievan/semi-utils) 的 `config/logos`。
semi-utils 仓库以 Apache License 2.0 发布；许可全文随素材保存在
`SwiftCull/Resources/WatermarkLogos/LICENSE.semi-utils`。

内置水印预设的尺寸、布局与处理顺序参考该项目的 `config/templates` 和 `processor` 实现，
由 SwiftCull 使用 macOS 原生框架重新实现。相机品牌名称与标志归各自权利人所有。

实况照片的 HEIC/MOV 配对元数据写入方式参考并改编自
[GavinHarbus/Video2Live](https://github.com/GavinHarbus/Video2Live) 的实现。
原项目以 MIT License 发布；许可全文见
`SwiftCull/Resources/LivePhoto/LICENSE.Video2Live`。

水印编辑器随应用打包的 Roboto、Merriweather、Noto Sans SC、Noto Serif SC、
Allura、Caveat、Dancing Script、Great Vibes、Liu Jian Mao Cao、Long Cang、
Ma Shan Zheng、Pacifico、Parisienne、Sacramento 和 Zhi Mang Xing 来自
[Google Fonts](https://github.com/google/fonts) 提交
`954e256c4277419b5e48bffa51be069b2bd01bde`；LXGW WenKai 来自
[lxgw/LxgwWenKai](https://github.com/lxgw/LxgwWenKai) 提交
`a06dd23142e82758f23f792f4060bbf1613286e8`；LXGW Marker Gothic 来自
[lxgw/LxgwMarkerGothic](https://github.com/lxgw/LxgwMarkerGothic) 的 `v1.004` 发布包；
KN Maiyuan 来自 [maoken-fonts/KNMaiyuan](https://github.com/maoken-fonts/KNMaiyuan)
的 `v1.20` 发布包。这些字体按各自的 SIL Open Font License 1.1 分发；
各字体的许可和版权声明保存在 `SwiftCull/Fonts/Licenses`。
Times New Roman、Georgia、Arial、macOS 宋体和苹方仅调用用户本机已安装的字体，
不随应用分发。
