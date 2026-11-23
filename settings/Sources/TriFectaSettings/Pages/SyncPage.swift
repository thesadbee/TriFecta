//
//  同步：Rime 内置同步 + 输入状态整包备份/还原。
//  备份内容：用户词典（*.userdb，含词典内词频与词典外学习词）+ 自定义短语（custom_phrase.txt）。
//
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import TriFectaSettingsCore

struct SyncPage: View {
  @EnvironmentObject private var state: AppState
  @State private var syncing = false
  @State private var busy = false
  @State private var message: String?
  @State private var messageIsError = false

  var body: some View {
    PageScroll(title: "同步",
               footer: "「同步用户数据」需先在 Rime 配置中启用 Git 仓库；「导出/导入输入状态」为本地整包备份，换机或重装后可原样还原。") {
      SettingCard {
        SettingRow("同步用户数据",
                   subtitle: "备份词频与使用习惯（Rime 内置 Git 同步）", divider: true) {
          if syncing {
            ProgressView().controlSize(.small)
          } else {
            Button("同步用户数据") {
              syncing = true
              message = nil
              DispatchQueue.main.async {
                Deployer.syncUserData()
                setMessage("已投递同步请求（输入法进程后台执行）")
                syncing = false
              }
            }
          }
        }

        SettingRow("导出输入状态",
                   subtitle: "打包用户词典（词频、学习到的词）与自定义短语，便于换机备份") {
          Button(busy ? "处理中…" : "导出…") { exportState() }
            .disabled(busy)
        }

        SettingRow("导入输入状态",
                   subtitle: "从备份包还原输入习惯（会覆盖当前用户词典）", divider: false) {
          Button(busy ? "处理中…" : "导入…") { importState() }
            .disabled(busy)
        }

        if let message = message {
          Text(message)
            .font(.system(size: 11))
            .foregroundColor(messageIsError ? .red : .secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
      }
    }
  }

  private func setMessage(_ text: String, isError: Bool = false) {
    message = text
    messageIsError = isError
  }

  // MARK: - 导出

  private func exportState() {
    guard !busy else { return }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.zip]
    panel.canCreateDirectories = true
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd"
    panel.nameFieldStringValue = "TriFecta-输入状态-\(formatter.string(from: Date())).zip"
    guard panel.runModal() == .OK, let dest = panel.url else { return }

    let paths = state.repo.paths
    busy = true
    message = nil
    messageIsError = false
    DispatchQueue.global(qos: .userInitiated).async {
      // 导出前结束输入法进程，避免复制到写入中的用户词典
      Deployer.stopIME()
      let outcome: Result<[String], Error>
      do {
        outcome = .success(try InputStateBackup.export(to: dest, userDir: paths.userDir))
      } catch {
        outcome = .failure(error)
      }
      DispatchQueue.main.async {
        busy = false
        switch outcome {
        case .success(let items):
          setMessage("已导出 \(items.count) 项（\(items.joined(separator: "、"))）→ \(dest.lastPathComponent)")
        case .failure(let error):
          setMessage("导出失败：\(error.localizedDescription)", isError: true)
        }
        Deployer.reload(paths: paths)
      }
    }
  }

  // MARK: - 导入

  private func importState() {
    guard !busy else { return }
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.zip]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    guard panel.runModal() == .OK, let src = panel.url else { return }

    let paths = state.repo.paths
    busy = true
    message = nil
    messageIsError = false
    DispatchQueue.global(qos: .userInitiated).async {
      // 还原会替换用户词典目录，必须先结束输入法进程
      Deployer.stopIME()
      let outcome: Result<[String], Error>
      do {
        outcome = .success(try InputStateBackup.restore(from: src, userDir: paths.userDir))
      } catch {
        outcome = .failure(error)
      }
      DispatchQueue.main.async {
        busy = false
        switch outcome {
        case .success(let items):
          setMessage("已还原 \(items.count) 项（\(items.joined(separator: "、"))），正在重新部署…")
        case .failure(let error):
          setMessage("导入失败：\(error.localizedDescription)", isError: true)
        }
        Deployer.reload(paths: paths)
      }
    }
  }
}
