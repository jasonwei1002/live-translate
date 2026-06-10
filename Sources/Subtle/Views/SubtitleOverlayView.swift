import SwiftUI

/// Floating subtitle content. Layout mirrors the design prototype: source line
/// (smaller, dimmed) above the translated line, padding scaled by font size,
/// rendered in one of three user-selectable styles.
struct SubtitleOverlayView: View {
  let subtitle: SubtitleState
  let appearance: SubtitleAppearance

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// Background/decoration fades out entirely when there is nothing to show,
  /// so the idle overlay never shows an empty chrome rectangle. The listening
  /// placeholder and error text count as content.
  private var chromeAlpha: Double { subtitle.hasVisibleContent ? 1 : 0 }
  private var size: CGFloat { CGFloat(appearance.fontSize) }

  // No explicit frame: the overlay's hosting view centers the content, and the
  // settings preview pins it to the bottom of its mock frame.
  var body: some View {
    styledContent
  }

  @ViewBuilder private var styledContent: some View {
    switch appearance.style {
    case .darkBar:
      textBlock(
        srcColor: .white.opacity(0.55),
        dstColor: .white.opacity(0.97),
        dstWeight: .semibold,
        dstSize: size
      )
      .padding(.horizontal, size * 1.15)
      .padding(.vertical, size * 0.55)
      .background(
        // Solid translucent near-black, not Material: the panel floats over
        // arbitrary video and white text must stay readable on bright frames.
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(Color(red: 16 / 255, green: 16 / 255, blue: 20 / 255)
            .opacity(appearance.backgroundOpacity * chromeAlpha))
      )
      .shadow(color: .black.opacity(0.35 * chromeAlpha), radius: 14, y: 6)

    case .frosted:
      textBlock(
        srcColor: .black.opacity(0.42),
        dstColor: .black.opacity(0.9),
        dstWeight: .semibold,
        dstSize: size
      )
      .padding(.horizontal, size * 1.15)
      .padding(.vertical, size * 0.55)
      .background(
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .fill(.white.opacity(min(appearance.backgroundOpacity + 0.08, 0.92) * chromeAlpha))
      )
      .overlay(alignment: .top) {
        // Accent notch centered on the top edge, as in the design.
        UnevenRoundedRectangle(bottomLeadingRadius: 3, bottomTrailingRadius: 3)
          .fill(Theme.accent.opacity(0.85 * chromeAlpha))
          .frame(width: 44, height: 3)
      }
      .overlay(
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .strokeBorder(.white.opacity(0.45 * chromeAlpha), lineWidth: 0.5)
      )
      .shadow(color: .black.opacity(0.4 * chromeAlpha), radius: 18, y: 10)

    case .outline:
      textBlock(
        srcColor: .white.opacity(0.72),
        dstColor: .white,
        dstWeight: .bold,
        dstSize: size * 1.08
      )
      // Three stacked shadows approximate the design's halo + drop + edge mix;
      // opacity reuses the background slider so "更不透明" reads as a darker halo.
      .shadow(
        color: .black.opacity(min(0.45 + appearance.backgroundOpacity * 0.4, 0.9)),
        radius: size * 0.35
      )
      .shadow(color: .black.opacity(0.9), radius: 2, y: 2)
      .shadow(color: .black.opacity(0.95), radius: 1)
    }
  }

  private func textBlock(
    srcColor: Color,
    dstColor: Color,
    dstWeight: Font.Weight,
    dstSize: CGFloat
  ) -> some View {
    VStack(spacing: 4) {
      if !subtitle.sourceText.isEmpty {
        Text(subtitle.sourceText)
          .font(.system(size: dstSize * 0.62))
          .multilineTextAlignment(.center)
          .lineLimit(2)
          .minimumScaleFactor(0.75)
          .foregroundStyle(srcColor)
      }
      // Live-caption style rolling lines: each committed sentence keeps its
      // own line (never reflows); only the last, active line grows. Older
      // lines dim so the eye can lock onto the current sentence.
      let lines = subtitle.translatedLines
      ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
        let isActive = index == lines.count - 1
        Text(line)
          .font(.system(size: dstSize, weight: isActive ? dstWeight : .regular))
          .multilineTextAlignment(.center)
          .lineLimit(isActive ? 2 : 1)
          .minimumScaleFactor(isActive ? 0.7 : 1)
          .foregroundStyle(dstColor)
          .opacity(isActive ? 1 : index == lines.count - 2 ? 0.55 : 0.38)
      }
      if !subtitle.hasText {
        statusLine(srcColor: srcColor, size: dstSize)
      }
    }
    .animation(
      reduceMotion ? nil : .easeOut(duration: 0.18),
      value: subtitle.translatedLines
    )
  }

  /// Placeholder / error line shown when no subtitle content exists yet, so
  /// "service running but silent" and "session failed" are both visible
  /// states instead of an invisible overlay.
  @ViewBuilder private func statusLine(srcColor: Color, size: CGFloat) -> some View {
    if !subtitle.errorText.isEmpty {
      Text(subtitle.errorText)
        .font(.system(size: size * 0.62))
        .multilineTextAlignment(.center)
        .lineLimit(2)
        .foregroundStyle(Theme.danger)
    } else if subtitle.isListening {
      Text("正在聆听…")
        .font(.system(size: size * 0.62))
        .foregroundStyle(srcColor)
    }
  }
}
