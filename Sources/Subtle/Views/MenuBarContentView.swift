import AppKit
import SwiftUI

/// The app's single control hub (window-style MenuBarExtra), per the Subtle
/// design handoff: header (name + status + master switch), audio level meter,
/// language direction, subtitle mode, then 设置…/退出 menu rows. The floating
/// subtitle follows the service automatically — there is no overlay switch.
struct MenuBarContentView: View {
  @EnvironmentObject private var appState: AppState
  @Environment(\.openSettings) private var openSettings
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      levelRow
      hairline
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
      if TranslationProvider.selectable.count > 1 {
        providerRow
      }
      languageSection
      subtitleModeRow
      if let lastError = appState.lastError {
        errorRow(lastError)
      }
      hairline
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
      // No explicit .keyboardShortcut: the Settings scene already owns ⌘,
      // globally; the trailing text is just the conventional hint.
      MenuPanelRow(title: "设置…", shortcut: "⌘,") {
        dismiss()
        openSettings()
        NSApp.activate(ignoringOtherApps: true)
      }
      MenuPanelRow(title: "退出", shortcut: "⌘Q") {
        NSApplication.shared.terminate(nil)
      }
    }
    .padding(.bottom, 6)
    .frame(width: 300)
    .tint(Theme.accent)
  }

  // MARK: - Header

  private var statusLine: String {
    guard appState.isRunning else { return "服务已停止 · 字幕已隐藏" }
    // The steady capturing state reads as the design's listening line; the
    // transient connection states keep their more specific wording.
    return appState.statusText == "正在捕获系统音频" ? "正在监听 · 字幕显示中" : appState.statusText
  }

  private var header: some View {
    HStack(spacing: 10) {
      VStack(alignment: .leading, spacing: 1) {
        Text("Subtle")
          .font(.system(size: 13.5, weight: .semibold))
        Text(statusLine)
          .font(.system(size: 11.5))
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
      Toggle("", isOn: Binding(
        get: { appState.isRunning },
        set: { $0 ? appState.start() : appState.stop() }
      ))
      .toggleStyle(.switch)
      .labelsHidden()
      .controlSize(.small)
    }
    .padding(EdgeInsets(top: 13, leading: 16, bottom: 11, trailing: 16))
  }

  // MARK: - Audio level

  private var levelRow: some View {
    HStack(spacing: 10) {
      Text("音频电平")
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
      LevelMeter(level: appState.isRunning ? appState.audioLevel : 0)
    }
    .padding(EdgeInsets(top: 0, leading: 16, bottom: 10, trailing: 16))
  }

  // MARK: - Provider

  private var providerRow: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text("服务商")
          .font(.system(size: 11.5))
          .foregroundStyle(.secondary)
        Spacer()
        Picker("", selection: $appState.provider) {
          ForEach(TranslationProvider.selectable) { provider in
            Text(provider.title).tag(provider)
          }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
      }
      if appState.isRunning {
        Text("切换服务商会立即重启服务")
          .font(.system(size: 10.5))
          .foregroundStyle(.tertiary)
      }
    }
    .padding(EdgeInsets(top: 0, leading: 16, bottom: 10, trailing: 16))
  }

  // MARK: - Language direction

  private var languageSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("语言方向")
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
      HStack(spacing: 8) {
        languagePicker(
          selection: $appState.sourceLanguage,
          options: appState.provider.sourceLanguages
        )
        Button {
          appState.swapLanguages()
        } label: {
          Image(systemName: "arrow.left.arrow.right")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("交换源语言与目标语言")
        languagePicker(
          selection: $appState.targetLanguage,
          options: appState.provider.targetLanguages
        )
      }
    }
    .padding(EdgeInsets(top: 0, leading: 16, bottom: 10, trailing: 16))
  }

  private func languagePicker(
    selection: Binding<String>,
    options: [LanguageOption]
  ) -> some View {
    Picker("", selection: selection) {
      ForEach(options) { language in
        Text(language.title).tag(language.id)
      }
    }
    .pickerStyle(.menu)
    .labelsHidden()
    .frame(maxWidth: .infinity)
  }

  // MARK: - Subtitle mode

  private var subtitleModeRow: some View {
    HStack {
      Text("字幕模式")
        .font(.system(size: 13))
      Spacer()
      Picker("", selection: Binding(
        get: { appState.showSourceText },
        set: { appState.setShowSourceText($0) }
      )) {
        Text("双语").tag(true)
        Text("仅译文").tag(false)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .frame(width: 140)
    }
    .padding(EdgeInsets(top: 0, leading: 16, bottom: 12, trailing: 16))
  }

  // MARK: - Error / chrome

  private func errorRow(_ message: String) -> some View {
    Label(message, systemImage: "exclamationmark.triangle.fill")
      .font(.footnote)
      .foregroundStyle(Theme.danger)
      .textSelection(.enabled)
      .padding(EdgeInsets(top: 0, leading: 16, bottom: 10, trailing: 16))
  }

  private var hairline: some View {
    Rectangle()
      .fill(.primary.opacity(0.1))
      .frame(height: 0.5)
  }
}

/// Segmented input-level meter, lit proportionally to `level` with a slight
/// fade toward the loud end (mirrors the design's LevelMeter).
private struct LevelMeter: View {
  let level: Double
  private let segments = 18

  var body: some View {
    HStack(spacing: 2) {
      ForEach(0..<segments, id: \.self) { index in
        let lit = Double(index) / Double(segments) < level
        RoundedRectangle(cornerRadius: 2, style: .continuous)
          .fill(lit ? Theme.accent : Color.primary.opacity(0.1))
          .opacity(lit ? 1 - Double(index) / Double(segments) * 0.25 : 1)
          .frame(height: 6)
          .frame(maxWidth: .infinity)
      }
    }
    .animation(.linear(duration: 0.12), value: level)
  }
}

/// Hover-highlighted menu row with a trailing shortcut hint (设置… / 退出).
private struct MenuPanelRow: View {
  let title: String
  let shortcut: String
  let action: () -> Void

  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      HStack {
        Text(title)
          .font(.system(size: 13))
          .foregroundStyle(.primary.opacity(0.75))
        Spacer()
        Text(shortcut)
          .font(.system(size: 12))
          .foregroundStyle(.tertiary)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 7)
      .background(
        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .fill(hovering ? Color.primary.opacity(0.06) : .clear)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .padding(.horizontal, 6)
  }
}
