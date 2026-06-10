import Foundation

struct LanguageOption: Identifiable, Hashable {
  let id: String
  let title: String

  init(_ id: String, _ title: String) {
    self.id = id
    self.title = title
  }
}

// Per-provider language sets, mirroring each vendor's protocol doc. Keep in
// sync with vendor-docs/doubao-api-readme.md (语种说明) and vendor-docs/qwen-api-readme.md (支持的语种).
extension LanguageOption {
  /// AST lang_20: valid as both 源语种 and 目标语种 in S2T mode. The zh/en
  /// constraint (one side must be Chinese or English) is enforced at start().
  static let volcanoLang20: [LanguageOption] = [
    .init("zh", "中文"),
    .init("en", "英语"),
    .init("de", "德语"),
    .init("fr", "法语"),
    .init("es", "西班牙语"),
    .init("id", "印尼语"),
    .init("ja", "日语"),
    .init("pt", "葡萄牙语"),
    .init("ko", "韩语"),
    .init("tr", "土耳其语"),
    .init("ms", "马来语"),
    .init("nl", "荷兰语"),
    .init("ro", "罗马尼亚语"),
    .init("pl", "波兰语"),
    .init("cs", "捷克语"),
    .init("ar", "阿拉伯语"),
    .init("th", "泰语"),
    .init("vi", "越南语"),
    .init("ru", "俄语"),
    .init("it", "意大利语"),
  ]

  /// AST dialects: 仅支持作为源语种.
  static let volcanoDialects: [LanguageOption] = [
    .init("yue-CN", "粤语"),
    .init("sh-CN", "上海话"),
  ]

  /// lang_20 + dialects, concatenated once — the source picker re-reads this
  /// on every SwiftUI body evaluation.
  static let volcanoSourceLanguages: [LanguageOption] = volcanoLang20 + volcanoDialects

  /// Qwen3.5-livetranslate full set (29 audio+text + 31 text-only). The app
  /// requests text-only output, so every entry is valid as source and target.
  static let qwenLanguages: [LanguageOption] = [
    .init("zh", "中文"),
    .init("en", "英语"),
    .init("ar", "阿拉伯语"),
    .init("de", "德语"),
    .init("fr", "法语"),
    .init("es", "西班牙语"),
    .init("pt", "葡萄牙语"),
    .init("id", "印度尼西亚语"),
    .init("it", "意大利语"),
    .init("ko", "韩语"),
    .init("ru", "俄语"),
    .init("th", "泰语"),
    .init("vi", "越南语"),
    .init("ja", "日语"),
    .init("tr", "土耳其语"),
    .init("hi", "印地语"),
    .init("ms", "马来语"),
    .init("nl", "荷兰语"),
    .init("ur", "乌尔都语"),
    .init("nb", "挪威语"),
    .init("sv", "瑞典语"),
    .init("da", "丹麦语"),
    .init("he", "希伯来语"),
    .init("fi", "芬兰语"),
    .init("pl", "波兰语"),
    .init("is", "冰岛语"),
    .init("cs", "捷克语"),
    .init("fil", "菲律宾语"),
    .init("fa", "波斯语"),
    .init("yue", "粤语"),
    .init("el", "希腊语"),
    .init("af", "南非荷兰语"),
    .init("ast", "阿斯图里亚斯语"),
    .init("be", "白俄罗斯语"),
    .init("bg", "保加利亚语"),
    .init("bn", "孟加拉语"),
    .init("bs", "波斯尼亚语"),
    .init("ca", "加泰罗尼亚语"),
    .init("ceb", "宿务语"),
    .init("et", "爱沙尼亚语"),
    .init("gl", "加利西亚语"),
    .init("gu", "古吉拉特语"),
    .init("hr", "克罗地亚语"),
    .init("hu", "匈牙利语"),
    .init("jv", "爪哇语"),
    .init("kk", "哈萨克语"),
    .init("kn", "卡纳达语"),
    .init("ky", "柯尔克孜语"),
    .init("lv", "拉脱维亚语"),
    .init("mk", "马其顿语"),
    .init("ml", "马拉雅拉姆语"),
    .init("mr", "马拉地语"),
    .init("pa", "旁遮普语"),
    .init("ro", "罗马尼亚语"),
    .init("sk", "斯洛伐克语"),
    .init("sl", "斯洛文尼亚语"),
    .init("sw", "斯瓦希里语"),
    .init("tg", "塔吉克语"),
    .init("az", "阿塞拜疆语"),
    .init("uk", "乌克兰语"),
  ]
}
