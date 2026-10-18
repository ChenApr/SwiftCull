import Foundation

struct WatermarkFontDownload: Sendable {
    let url: URL
    let sha256: String
    let bytes: Int

    // Immutable upstream versions; checksums also protect cached files.
    static let catalog: [String: WatermarkFontDownload] = [
        "Merriweather": .init(url: URL(string: "https://raw.githubusercontent.com/google/fonts/954e256c4277419b5e48bffa51be069b2bd01bde/ofl/merriweather/Merriweather%5Bopsz%2Cwdth%2Cwght%5D.ttf")!, sha256: "d0ed0e359e396af7ad05e73dffd11a3a4c326ea0d0283c56bd9361cb2cc86a96", bytes: 4628080),
        "NotoSansSC": .init(url: URL(string: "https://raw.githubusercontent.com/google/fonts/954e256c4277419b5e48bffa51be069b2bd01bde/ofl/notosanssc/NotoSansSC%5Bwght%5D.ttf")!, sha256: "a3041811a78c361b1de50f953c805e0244951c21c5bd412f7232ef0d899af0da", bytes: 17772300),
        "NotoSerifSC": .init(url: URL(string: "https://raw.githubusercontent.com/google/fonts/954e256c4277419b5e48bffa51be069b2bd01bde/ofl/notoserifsc/NotoSerifSC%5Bwght%5D.ttf")!, sha256: "050080d9255a86808f2945bffac582b31ef32bc36411ce29563b4961670c66f9", bytes: 25125512),
        "Allura": .init(url: URL(string: "https://raw.githubusercontent.com/google/fonts/954e256c4277419b5e48bffa51be069b2bd01bde/ofl/allura/Allura-Regular.ttf")!, sha256: "9c142b2e515832c0dfc4ff8b8ea18f40314943bf937b72e2b23c4661bac14cc6", bytes: 246632),
        "GreatVibes": .init(url: URL(string: "https://raw.githubusercontent.com/google/fonts/954e256c4277419b5e48bffa51be069b2bd01bde/ofl/greatvibes/GreatVibes-Regular.ttf")!, sha256: "8d509802186f1b51572531ecf313e8098f9a5bfdfaca93f0c9b34467f9982d15", bytes: 457588),
        "LiuJianMaoCao": .init(url: URL(string: "https://raw.githubusercontent.com/google/fonts/954e256c4277419b5e48bffa51be069b2bd01bde/ofl/liujianmaocao/LiuJianMaoCao-Regular.ttf")!, sha256: "cab396b91a5b7c0b4005a35891180d06e6751f5ac261fe680aec65c1ae209033", bytes: 4951804),
        "LongCang": .init(url: URL(string: "https://raw.githubusercontent.com/google/fonts/954e256c4277419b5e48bffa51be069b2bd01bde/ofl/longcang/LongCang-Regular.ttf")!, sha256: "e5bf2c3f24ef2327c6f136d8f73e2f9dfdf44896fdbeb35a9515f44777bb91bc", bytes: 5162508),
        "MaShanZheng": .init(url: URL(string: "https://raw.githubusercontent.com/google/fonts/954e256c4277419b5e48bffa51be069b2bd01bde/ofl/mashanzheng/MaShanZheng-Regular.ttf")!, sha256: "6d2546bb189c732a8ca29af9e22457b152387d158aa459e4ac2ce1e51788b7fb", bytes: 5857936),
        "Pacifico": .init(url: URL(string: "https://raw.githubusercontent.com/google/fonts/954e256c4277419b5e48bffa51be069b2bd01bde/ofl/pacifico/Pacifico-Regular.ttf")!, sha256: "5b6c0d5334a7bf77dea52b975c5a0c408878c0f7115ed5b6fb151f634b7bf701", bytes: 329380),
        "Parisienne": .init(url: URL(string: "https://raw.githubusercontent.com/google/fonts/954e256c4277419b5e48bffa51be069b2bd01bde/ofl/parisienne/Parisienne-Regular.ttf")!, sha256: "bc9ee17f022e20bc700797e5f557d14bfa43af0c98d9e6c9c5c1ca4ec7aacd57", bytes: 61248),
        "Sacramento": .init(url: URL(string: "https://raw.githubusercontent.com/google/fonts/954e256c4277419b5e48bffa51be069b2bd01bde/ofl/sacramento/Sacramento-Regular.ttf")!, sha256: "9341fda10adbfeb7efc94302b34507a3e227d7e7f5c432df3f5ac8753ff73d24", bytes: 79696),
        "ZhiMangXing": .init(url: URL(string: "https://raw.githubusercontent.com/google/fonts/954e256c4277419b5e48bffa51be069b2bd01bde/ofl/zhimangxing/ZhiMangXing-Regular.ttf")!, sha256: "644e0cae9b40f0b10ab729a01bd32032e3973bac22be3dccae01bf6ae7fde969", bytes: 4063532),
        "LXGWWenKai": .init(url: URL(string: "https://raw.githubusercontent.com/lxgw/LxgwWenKai/a06dd23142e82758f23f792f4060bbf1613286e8/fonts/TTF/LXGWWenKai-Regular.ttf")!, sha256: "bf73f995c05f3f7baf7840b9d76d8d9678c8b150a020946a394ca63c67ed1350", bytes: 25928940),
        "LXGWMarkerGothic": .init(url: URL(string: "https://raw.githubusercontent.com/lxgw/LxgwMarkerGothic/a40bdefc4c00139ba8c1188ccbee0a29196f3133/fonts/ttf/LXGWMarkerGothic-Regular.ttf")!, sha256: "cfc0facbc1084735596425f91650c0ffef2130f0853556476bdd9f59e164d382", bytes: 3190368),
        "KNMaiyuan": .init(url: URL(string: "https://raw.githubusercontent.com/maoken-fonts/KNMaiyuan/580b2bb873828122f7816f1c5c4caf2667cba62f/fonts/TTF/KNMaiyuan-Regular.ttf")!, sha256: "94ea78c51086b1ea58c1744784b2335dea2c5ef1c5193b80e02c7d46b8e0283f", bytes: 7996068),
    ]
}
