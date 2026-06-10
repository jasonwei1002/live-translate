import SwiftUI

/// Compact updater control for the header's top-right cluster. Renders the
/// current `updateState` with a visible label and exposes "检查更新" /
/// "下载并安装" inline.
struct UpdateSectionView: View {
  @EnvironmentObject private var appState: AppState

  var body: some View {
    switch appState.updateState {
    case .idle:
      checkButton(title: "检查更新", icon: "arrow.triangle.2.circlepath")
    case .upToDate:
      checkButton(title: "已是最新", icon: "checkmark.seal.fill", tint: .green,
                  help: "当前已是最新版本 v\(appState.appVersion)")
    case .failed(let message):
      checkButton(title: "检查更新", icon: "exclamationmark.triangle.fill",
                  tint: .red, help: message)
    case .checking:
      labelRow("检查中…")
    case .available(let info):
      Button {
        appState.installUpdate()
      } label: {
        Label("下载新版 v\(info.version)", systemImage: "arrow.down.circle.fill")
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.small)
      .help("下载并安装 v\(info.version)")
    case .downloading(let fraction):
      HStack(spacing: 4) {
        ProgressView(value: fraction).frame(width: 56)
        Text("\(Int(fraction * 100))%")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      .help("正在下载更新")
    case .installing:
      labelRow("安装中…", help: "正在安装，应用即将重启")
    }
  }

  private func checkButton(
    title: String, icon: String, tint: Color? = nil, help: String = "检查更新"
  ) -> some View {
    Button {
      appState.checkForUpdates(manual: true)
    } label: {
      Label(title, systemImage: icon)
    }
    .buttonStyle(.bordered)
    .controlSize(.small)
    .tint(tint ?? Theme.accent)
    .help(help)
  }

  private func labelRow(_ text: String, help: String = "正在检查更新") -> some View {
    HStack(spacing: 5) {
      ProgressView().controlSize(.small)
      Text(text).font(.callout).foregroundStyle(.secondary)
    }
    .help(help)
  }
}
