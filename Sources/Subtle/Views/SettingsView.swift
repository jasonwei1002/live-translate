import ServiceManagement
import SwiftUI

/// Shared height for all three tabs so the window does not jump when the
/// user switches tabs; sized to the tallest content (字幕样式).
private let settingsTabHeight: CGFloat = 420

/// The app's only standalone window (⌘,), per the Subtle design handoff:
/// three tabs — 通用 / 翻译服务 / 字幕样式. Defaults to the service tab since
/// the API key is the one mandatory setting.
struct SettingsView: View {
  private enum Tab {
    case general, service, style
  }

  @EnvironmentObject private var appState: AppState
  @State private var selectedTab: Tab = .service

  var body: some View {
    TabView(selection: $selectedTab) {
      GeneralSettingsTab()
        .tabItem { Label("通用", systemImage: "gearshape") }
        .tag(Tab.general)
      ServiceSettingsTab()
        .tabItem { Label("翻译服务", systemImage: "waveform") }
        .tag(Tab.service)
      SubtitleStyleSettingsTab()
        .tabItem { Label("字幕样式", systemImage: "captions.bubble") }
        .tag(Tab.style)
    }
    .frame(width: 560)
    .navigationTitle("Subtle 设置")
    .tint(Theme.accent)
  }
}

// MARK: - 翻译服务

private struct ServiceSettingsTab: View {
  @EnvironmentObject private var appState: AppState
  @State private var showKey = false
  @State private var keyJustSaved = false
  @FocusState private var apiKeyFocused: Bool

  var body: some View {
    Form {
      Section("识别引擎") {
        if TranslationProvider.selectable.count > 1 {
          Picker("服务商", selection: $appState.provider) {
            ForEach(TranslationProvider.selectable) { provider in
              Text(provider.title).tag(provider)
            }
          }
          if appState.isRunning {
            Text("服务正在运行，切换服务商会立即重启翻译服务。")
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
        } else {
          LabeledContent("服务商", value: appState.provider.title)
        }
        LabeledContent("API Key") {
          HStack(spacing: 8) {
            Group {
              if showKey {
                TextField("", text: apiKeyBinding)
              } else {
                SecureField("", text: apiKeyBinding)
              }
            }
            .textFieldStyle(.roundedBorder)
            .font(.system(.caption, design: .monospaced))
            .frame(maxWidth: .infinity)
            .focused($apiKeyFocused)
            .onSubmit { appState.commitAPIKey() }
            .onChange(of: apiKeyFocused) { _, focused in
              // Persist only when editing ends, not per keystroke.
              if !focused { appState.commitAPIKey() }
            }
            Button(showKey ? "隐藏" : "显示") { showKey.toggle() }
              .buttonStyle(.borderless)
              .font(.caption)
            Button(keyJustSaved ? "已保存" : "保存") { saveAPIKey() }
              .buttonStyle(.borderless)
              .font(.caption)
              .disabled(keyJustSaved)
          }
        }
        HStack {
          Text(appState.provider.apiKeyFootnote)
            .font(.footnote)
            .foregroundStyle(.secondary)
          Spacer()
          Link("获取 API Key", destination: appState.provider.apiKeyConsoleURL)
            .font(.footnote)
        }
      }

      Section {
        LabeledContent {
          HStack(spacing: 10) {
            testResultBadge
            Button(isTesting ? "测试中…" : "测试连接") {
              appState.testConnection()
            }
            .disabled(isTesting)
          }
        } label: {
          Text("连接状态")
          Text("验证 API Key 是否可用")
        }
      }

      Section("语言") {
        languagePicker(
          "源语言",
          selection: $appState.sourceLanguage,
          options: appState.provider.sourceLanguages
        )
        languagePicker(
          "目标语言",
          selection: $appState.targetLanguage,
          options: appState.provider.targetLanguages
        )
        if appState.provider.requiresChineseOrEnglishLeg {
          Text("AST 要求源语言或目标语言至少有一个为中文或英语；粤语、上海话仅可作为源语言。")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }
    }
    .formStyle(.grouped)
    .frame(height: settingsTabHeight)
  }

  /// Persists the key immediately and flashes a brief "已保存" confirmation.
  /// Commit-on-blur stays as a safety net; this is the explicit affordance.
  private func saveAPIKey() {
    appState.commitAPIKey()
    apiKeyFocused = false
    keyJustSaved = true
    Task {
      try? await Task.sleep(nanoseconds: 1_500_000_000)
      keyJustSaved = false
    }
  }

  /// Binds the API key field to the selected provider's own key.
  private var apiKeyBinding: Binding<String> {
    switch appState.provider {
    case .volcano: $appState.volcanoAPIKey
    case .qwen: $appState.qwenAPIKey
    }
  }

  private var isTesting: Bool {
    appState.connectionTestState == .testing
  }

  @ViewBuilder private var testResultBadge: some View {
    switch appState.connectionTestState {
    case .success(let latencyMS):
      Label("连接成功 · 延迟 \(latencyMS) ms", systemImage: "checkmark")
        .font(.caption.weight(.medium))
        .foregroundStyle(.green)
    case .failed(let message):
      Text(message)
        .font(.caption)
        .foregroundStyle(Theme.danger)
        .lineLimit(2)
        .multilineTextAlignment(.trailing)
    case .idle, .testing:
      EmptyView()
    }
  }

  private func languagePicker(
    _ title: String,
    selection: Binding<String>,
    options: [LanguageOption]
  ) -> some View {
    Picker(title, selection: selection) {
      ForEach(options) { language in
        Text(language.title).tag(language.id)
      }
    }
  }
}

// MARK: - 通用

private struct GeneralSettingsTab: View {
  @EnvironmentObject private var appState: AppState
  @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

  var body: some View {
    Form {
      Section {
        Toggle("开机自动启动", isOn: $launchAtLogin)
          .onChange(of: launchAtLogin) { _, enable in
            do {
              if enable {
                try SMAppService.mainApp.register()
              } else {
                try SMAppService.mainApp.unregister()
              }
            } catch {
              // Registration can fail for ad-hoc builds; reflect reality.
              launchAtLogin = SMAppService.mainApp.status == .enabled
            }
          }
      }

      Section("音频") {
        LabeledContent {
          Text("系统音频")
        } label: {
          Text("音频来源")
          Text("默认捕捉系统输出音频")
        }
        Picker("无声音自动停止", selection: $appState.autoStopSilenceSeconds) {
          Text("30 秒").tag(30.0)
          Text("1 分钟").tag(60.0)
          Text("5 分钟").tag(300.0)
          Text("永不").tag(0.0)
        }
        Text("检测到持续无声后自动停止翻译服务，避免连接空耗。首次捕获系统音频时，macOS 可能要求在系统设置中授予屏幕录制权限。")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }

      Section("更新") {
        LabeledContent("当前版本 v\(appState.appVersion)") {
          UpdateSectionView()
        }
      }
    }
    .formStyle(.grouped)
    .frame(height: settingsTabHeight)
  }
}

// MARK: - 字幕样式

private struct SubtitleStyleSettingsTab: View {
  @EnvironmentObject private var appState: AppState

  private static let sampleSubtitle = SubtitleState(
    sourceText: "Welcome back to the stream.",
    translatedLines: ["欢迎回到直播间。"]
  )

  var body: some View {
    Form {
      Section {
        Picker("字幕样式", selection: $appState.subtitleStyle) {
          ForEach(SubtitleStyle.allCases) { style in
            Text(style.title).tag(style)
          }
        }
        .pickerStyle(.segmented)
        sliderRow(
          title: "字号",
          value: $appState.subtitleFontSize,
          range: 16...72,
          display: "\(Int(appState.subtitleFontSize)) px"
        )
        sliderRow(
          title: "背景不透明度",
          value: $appState.subtitleOpacity,
          range: 0.10...0.95,
          display: "\(Int(appState.subtitleOpacity * 100))%"
        )
      }

      Section("预览") {
        preview
      }
    }
    .formStyle(.grouped)
    .frame(height: settingsTabHeight)
  }

  private func sliderRow(
    title: String,
    value: Binding<Double>,
    range: ClosedRange<Double>,
    display: String
  ) -> some View {
    LabeledContent(title) {
      HStack(spacing: 10) {
        Text(display)
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
          .frame(width: 42, alignment: .trailing)
        Slider(value: value, in: range)
          .frame(width: 180)
      }
    }
  }

  /// Static sample over a dark mock frame, rendered with the real overlay view
  /// at a reduced scale so style/size/opacity edits preview live.
  private var preview: some View {
    ZStack(alignment: .bottom) {
      LinearGradient(
        colors: [
          Color(red: 0.17, green: 0.19, blue: 0.22),
          Color(red: 0.09, green: 0.10, blue: 0.13),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      SubtitleOverlayView(
        subtitle: previewSubtitle,
        appearance: previewAppearance
      )
      .padding(.bottom, 12)
    }
    .frame(height: 150)
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
  }

  private var previewSubtitle: SubtitleState {
    var sample = Self.sampleSubtitle
    if !appState.showSourceText {
      sample.sourceText = ""
    }
    return sample
  }

  private var previewAppearance: SubtitleAppearance {
    var appearance = appState.subtitleAppearance
    appearance.fontSize = max(13, appearance.fontSize * 0.62)
    return appearance
  }
}
