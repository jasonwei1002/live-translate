import Foundation

/// The selectable realtime-translation backend. Each provider keeps its own
/// API key under its own UserDefaults key, so switching providers never
/// clobbers the other credential.
enum TranslationProvider: String, CaseIterable, Identifiable {
  case volcano
  case qwen

  /// UserDefaults key holding the selected provider.
  static let defaultsKey = "translationProvider"

  /// Providers offered in the UI. Qwen stays implemented but is pulled from
  /// the lineup for now (2026-06-10 user decision) — add it back here to
  /// restore the picker option.
  static let selectable: [TranslationProvider] = [.volcano]

  var id: String { rawValue }

  /// UserDefaults key for this provider's API key. The volcano key keeps its
  /// historical name so existing installs retain their saved key.
  var apiKeyDefaultsKey: String {
    switch self {
    case .volcano: "astAPIKey"
    case .qwen: "qwenAPIKey"
    }
  }

  var title: String {
    switch self {
    case .volcano: "豆包同声传译2.0"
    case .qwen: "Qwen3.5-LiveTranslate"
    }
  }

  var shortTitle: String {
    switch self {
    case .volcano: "AST"
    case .qwen: "Qwen"
    }
  }

  var apiKeyFootnote: String {
    switch self {
    case .volcano: "火山引擎 API Key，仅保存在本机，不会上传。"
    case .qwen: "阿里云百炼 DashScope API Key，仅保存在本机，不会上传。"
    }
  }

  /// Vendor console page where the user creates/copies this provider's API key.
  var apiKeyConsoleURL: URL {
    switch self {
    case .volcano:
      URL(string: "https://console.volcengine.com/speech/new/setting/apikeys?projectName=default")!
    case .qwen:
      URL(
        string:
          "https://bailian.console.aliyun.com/cn-beijing?spm=5176.29619931.J_egCN4Yq1EkFrYZT7V5X0j.6.3ceb10d7YvvsUu&tab=model#/api-key"
      )!
    }
  }

  /// Languages accepted as 源语种, per the provider's protocol doc.
  var sourceLanguages: [LanguageOption] {
    switch self {
    case .volcano: LanguageOption.volcanoSourceLanguages
    case .qwen: LanguageOption.qwenLanguages
    }
  }

  /// Languages accepted as 目标语种 (AST dialects are source-only).
  var targetLanguages: [LanguageOption] {
    switch self {
    case .volcano: LanguageOption.volcanoLang20
    case .qwen: LanguageOption.qwenLanguages
    }
  }

  var sourceLanguageIDs: Set<String> { Set(sourceLanguages.map(\.id)) }
  var targetLanguageIDs: Set<String> { Set(targetLanguages.map(\.id)) }

  /// AST only accepts language pairs where at least one side is zh or en;
  /// Qwen has no such constraint for the languages the app offers.
  var requiresChineseOrEnglishLeg: Bool {
    self == .volcano
  }

  /// User-facing reason this pair cannot start a session, nil when valid.
  /// Owned by the provider so AppState stays free of provider-specific rules.
  func languagePairError(source: String, target: String) -> String? {
    if source == target {
      return "源语言与目标语言不能相同。"
    }
    let chineseOrEnglish: Set<String> = ["zh", "en"]
    if requiresChineseOrEnglishLeg,
      !chineseOrEnglish.contains(source), !chineseOrEnglish.contains(target) {
      return "AST 要求源语言或目标语言至少有一个为中文或英语。"
    }
    return nil
  }

  static func loadSelected(from defaults: UserDefaults) -> TranslationProvider {
    let stored = defaults.string(forKey: defaultsKey)
      .flatMap(TranslationProvider.init(rawValue:)) ?? .volcano
    // A persisted choice that is no longer offered falls back to the default.
    return selectable.contains(stored) ? stored : .volcano
  }
}
