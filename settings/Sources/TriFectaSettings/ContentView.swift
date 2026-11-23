//
//  主界面：左导航 + 右面板，底部保存操作条。
//
import SwiftUI
import AppKit

/// 窗口最小尺寸（App.swift 的 SwiftUI frame 与 ContentView 的 NSWindow.minSize 共用）
enum WindowMetrics {
  static let minWidth: CGFloat = 860
  static let minHeight: CGFloat = 600
}

enum SettingsPage: String, CaseIterable, Identifiable {
  case input = "输入"
  case customPhrase = "自定义短语"   // custom_phrase.txt 编辑
  case appearance = "外观"          // 输入法候选框外观
  case guiAppearance = "界面"        // 设置窗口外观
  case shortcuts = "快捷键"
  case sync = "同步"
  case about = "关于"

  var id: String { rawValue }

  var icon: String {
    switch self {
    case .input: return "keyboard"
    case .customPhrase: return "text.badge.plus"
    case .appearance: return "paintbrush"
    case .guiAppearance: return "circle.lefthalf.filled"
    case .shortcuts: return "command"
    case .sync: return "arrow.triangle.2.circlepath"
    case .about: return "info.circle"
    }
  }
}

struct ContentView: View {
  @EnvironmentObject private var state: AppState
  @Environment(\.appTheme) private var theme
  @State private var selection: SettingsPage = .input

  var body: some View {
    HStack(spacing: 0) {
      sidebar
        .frame(width: 186)
      Divider()
      Group {
        switch selection {
        case .input: InputPage()
        case .customPhrase: CustomPhrasePage()
        case .appearance: AppearancePage()
        case .guiAppearance: GuiAppearancePage()
        case .shortcuts: ShortcutsPage()
        case .sync: SyncPage()
        case .about: AboutPage()
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .ignoresSafeArea(edges: .top)
    .preferredColorScheme(theme.isDark ? .dark : .light)
    .background(theme.canvas.ignoresSafeArea())
    .safeAreaInset(edge: .bottom) { bottomBar }
    .onAppear {
      enlargeTrafficLights()
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      enlargeTrafficLights()   // 幂等：激活时再次校正
    }
    .alert("出错了", isPresented: $state.showingError) {
      Button("好", role: .cancel) {}
    } message: {
      Text(state.lastError ?? "")
    }
  }

  /// 放大红绿灯（大屏友好）：把三个窗口按钮放大到 17pt、间距 6pt，并保持垂直居中。
  /// SwiftUI 无 API 时直接操作 NSWindow.standardWindowButton；窗口未就绪时稍后重试。
  private func enlargeTrafficLights() {
    guard let window = NSApp.windows.last(where: { $0.isVisible || $0.contentView != nil }) else {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.enlargeTrafficLights() }
      return
    }
    // 硬性最小尺寸（SwiftUI minWidth/minHeight 在无窗口约束时可被绕过）
    window.minSize = NSSize(width: WindowMetrics.minWidth, height: WindowMetrics.minHeight)
    guard let close = window.standardWindowButton(.closeButton),
          let mini = window.standardWindowButton(.miniaturizeButton),
          let zoom = window.standardWindowButton(.zoomButton) else { return }
    let size: CGFloat = 17
    let gap: CGFloat = 6
    let centerY = close.frame.midY
    let x0 = close.frame.minX
    let y = centerY - size / 2
    close.frame = NSRect(x: x0, y: y, width: size, height: size)
    mini.frame = NSRect(x: x0 + size + gap, y: y, width: size, height: size)
    zoom.frame = NSRect(x: x0 + 2 * (size + gap), y: y, width: size, height: size)
  }

  private var sidebar: some View {
    VStack(alignment: .leading, spacing: 3) {
      // 无框窗口：左上留白给红绿灯
      Color.clear.frame(height: 34)
      Spacer().frame(height: 2)
      ForEach(SettingsPage.allCases) { page in
        sidebarItem(page)
      }
      Spacer()
      if state.loaded?.userSquirrelYamlExists == false {
        Text("配置尚未生成：首次保存将\n从安装包拷贝 squirrel.yaml 基线")
          .font(.system(size: 10))
          .foregroundColor(.secondary)
          .padding(.horizontal, 16)
          .padding(.bottom, 12)
      }
    }
    .background(theme.canvas.opacity(0.85))
  }

  private func sidebarItem(_ page: SettingsPage) -> some View {
    let selected = selection == page
    return Button {
      withAnimation(.spring(response: 0.3, dampingFraction: 1.0)) {
        selection = page
      }
    } label: {
      HStack(spacing: 9) {
        Image(systemName: page.icon)
          .font(.system(size: 13, weight: .medium))
          .frame(width: 18, height: 18)
        Text(page.rawValue)
          .font(.system(size: 13))
        Spacer(minLength: 0)
      }
      .padding(.vertical, 8)
      .padding(.horizontal, 10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(selected ? theme.accent : Color.clear)
      )
      .foregroundColor(selected ? .white : .primary)
      .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
    .buttonStyle(.plain)
    .padding(.horizontal, 9)
  }

  private var bottomBar: some View {
    HStack(spacing: 10) {
      if state.isDirty {
        Label("有未保存的更改", systemImage: "circle.fill")
          .font(.system(size: 11))
          .foregroundColor(.orange)
      }
      Spacer()
      statusText
      GlassActionGroup(spacing: 10) {
        GlassActionButton(title: "放弃修改", systemImage: "arrow.uturn.backward") {
          state.discardChanges()
        }
        .disabled(!state.isDirty)
        .opacity(state.isDirty ? 1 : 0.4)
        GlassActionButton(title: "保存并应用", systemImage: "checkmark.circle.fill", prominent: true) {
          state.save()
        }
        .disabled(!state.isDirty || state.status == .deploying)
        .opacity(state.isDirty ? 1 : 0.45)
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 11)
    .background {
      RoundedRectangle(cornerRadius: 0, style: .continuous)
        .fill(.ultraThinMaterial)
    }
  }

  @ViewBuilder
  private var statusText: some View {
    switch state.status {
    case .idle:
      EmptyView()
    case .deploying:
      HStack(spacing: 6) {
        ProgressView().controlSize(.small)
        Text("正在保存并部署…")
          .font(.system(size: 11))
          .foregroundColor(.secondary)
      }
    case .saved(let msg):
      Text(msg)
        .font(.system(size: 11))
        .foregroundColor(.secondary)
        .lineLimit(1)
    case .failed(let msg):
      Text("保存失败：\(msg)")
        .font(.system(size: 11))
        .foregroundColor(.red)
        .lineLimit(1)
    }
  }
}
