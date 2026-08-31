//
//  关于：版本信息、GitHub 链接、更新检查。
//  更新分为两块，避免混淆：
//   - Squirrel 更新：来自上游 rime/Squirrel 仓库（引擎本体），与 TriFecta 版本无关；
//   - TriFecta 更新：来自 thesadbee/TriFecta 仓库（项目自身的发布版本）。
//
import SwiftUI
import AppKit

struct AboutPage: View {
  @EnvironmentObject private var state: AppState
  @Environment(\.appTheme) private var theme
  @StateObject private var updater = AboutUpdateModel()

  private enum Links {
    static let repo = "https://github.com/thesadbee/TriFecta"
    static let releases = "https://github.com/thesadbee/TriFecta/releases"
    static let squirrelReleases = "https://github.com/rime/squirrel/releases"
    static let squirrelFeed = "https://rime.github.io/release/squirrel/appcast.xml"
  }

  private var imeVersion: String {
    let plist = NSDictionary(contentsOf: state.repo.paths.imeInfoPlist) as? [String: Any]
    let short = plist?["CFBundleShortVersionString"] as? String
    let build = plist?["CFBundleVersion"] as? String ?? "—"
    if let s = short, !s.isEmpty { return "\(s) (\(build))" }
    return build
  }

  /// TriFecta 当前版本（对应发布 tag 的 v 前缀形式）
  private var trifectaCurrent: String { "v" + imeVersion }

  private var settingsVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
  }

  private func open(_ url: String) {
    if let u = URL(string: url) {
      NSWorkspace.shared.open(u)
    }
  }

  // 上游 Squirrel 版本行：当前 → 最新
  private var squirrelLine: String {
    let latest = updater.squirrelLatest ?? "获取中…"
    return "当前 \(imeVersion) → 上游最新 \(latest)"
  }

  // TriFecta 版本行：当前 → 最新（含“有新版本”提示）
  private var trifectaLine: String {
    if let lt = updater.trifectaLatest {
      let hasNew = AboutUpdateModel.isNewer(current: trifectaCurrent, latest: lt)
      return "当前 \(trifectaCurrent) → 最新 \(lt)\(hasNew ? "（有新版本）" : "")"
    }
    return "当前 \(trifectaCurrent) → 最新 获取中…"
  }

  var body: some View {
    PageScroll(title: "关于", footer: "TriFecta：基于 Rime/Squirrel 的 macOS 中文输入法（GPL-3.0）") {
      SettingCard {
        VStack(spacing: 10) {
          Group {
            if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
               let appIcon = NSImage(contentsOf: iconURL) {
              Image(nsImage: appIcon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 64, height: 64)
            } else {
              Image(systemName: "character.book.closed.fill")
                .font(.system(size: 44))
                .foregroundColor(theme.accent)
            }
          }
          Text("TriFecta")
            .font(.system(size: 22, weight: .semibold))
            .foregroundColor(theme.accent)
          Text("输入法 \(imeVersion) · 设置 \(settingsVersion)")
            .font(.system(size: 12))
            .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
      }

      SettingCard {
        // —— 上游 Squirrel 引擎更新（与 TriFecta 版本无关）——
        SettingRow("Squirrel 更新（上游）",
                   subtitle: "上游 rime / 鼠鬚管 引擎版本，非 TriFecta 版本更新",
                   icon: "arrow.triangle.2.circlepath",
                   divider: false) {
          VStack(alignment: .trailing, spacing: 4) {
            Text(squirrelLine)
              .font(.system(size: 11))
              .foregroundColor(.secondary)
            Button("打开上游 Releases") { open(Links.squirrelReleases) }
          }
        }
      }

      SettingCard {
        // —— TriFecta 项目自身更新 ——
        SettingRow("TriFecta 更新",
                   subtitle: "来自 thesadbee/TriFecta 仓库的项目版本",
                   icon: "arrow.triangle.2.circlepath",
                   divider: false) {
          VStack(alignment: .trailing, spacing: 4) {
            Text(trifectaLine)
              .font(.system(size: 11))
              .foregroundColor(.secondary)
            Button(updater.loading ? "检查中…" : "检查 TriFecta 更新") { updater.refresh() }
          }
        }
      }

      SettingCard {
        SettingRow("GitHub 仓库", icon: "arrow.up.right.square") {
          Button("打开") { open(Links.repo) }
        }
        SettingRow("Rime Wiki（上游文档）", icon: "book", divider: false) {
          Button("打开") { open("https://github.com/rime/home/wiki") }
        }
      }
    }
    .task { updater.refresh() }
  }
}

/// 拉取两个仓库的最新 release 版本号（tag_name）。
@MainActor
final class AboutUpdateModel: ObservableObject {
  @Published var squirrelLatest: String?
  @Published var trifectaLatest: String?
  @Published var loading = false
  @Published var error: String?

  func refresh() {
    loading = true
    let group = DispatchGroup()

    var s: String?, t: String?, e: String?

    group.enter()
    fetchLatest("https://api.github.com/repos/rime/squirrel/releases/latest") { tag, err in
      s = tag; if err != nil { e = e ?? err }; group.leave()
    }

    group.enter()
    fetchLatest("https://api.github.com/repos/thesadbee/TriFecta/releases/latest") { tag, err in
      t = tag; if err != nil { e = e ?? err }; group.leave()
    }

    group.notify(queue: .main) {
      self.squirrelLatest = s
      self.trifectaLatest = t
      self.error = e
      self.loading = false
    }
  }

  private func fetchLatest(_ urlString: String, _ completion: @escaping (String?, String?) -> Void) {
    guard let url = URL(string: urlString) else { completion(nil, "invalid url"); return }
    var req = URLRequest(url: url)
    req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    URLSession.shared.dataTask(with: req) { data, resp, err in
      if let err = err { completion(nil, err.localizedDescription); return }
      guard let data = data,
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tag = obj["tag_name"] as? String else {
        completion(nil, "no tag_name"); return
      }
      completion(tag, nil)
    }.resume()
  }

  /// 轻量版本比较（"v1.1.1" 式）：latest 是否比 current 更新
  static func isNewer(current: String, latest: String) -> Bool {
    let c = current.lowercased().replacingOccurrences(of: "v", with: "")
    let l = latest.lowercased().replacingOccurrences(of: "v", with: "")
    let cp = c.split(separator: ".").compactMap { Int($0) }
    let lp = l.split(separator: ".").compactMap { Int($0) }
    let n = max(cp.count, lp.count)
    for i in 0..<n {
      let a = i < cp.count ? cp[i] : 0
      let b = i < lp.count ? lp[i] : 0
      if b != a { return b > a }
    }
    return false
  }
}
