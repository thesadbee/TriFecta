//
//  同步个人配置：迁移/备份 Rime 个人词库与配置。
//    - 导出：把用户个人词库/配置打包成 zip（Rime 可移植格式）。
//    - 导入：从其它 Rime 系输入法导入（.zip / custom_phrase.txt / *.dict.yaml）。
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

  private var userDir: URL { state.repo.paths.userDir }

  var body: some View {
    PageScroll(title: "同步",
               footer: "支持从其它 Rime 系输入法（如薄荷输入法）迁移个人词库与配置。") {
      SettingCard {
        SettingRow("同步用户数据",
                   subtitle: "备份词频与使用习惯", divider: true) {
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

        // —— 导出个人配置 ——
        SettingRow("导出个人配置（词库/配置）",
                   subtitle: "选择路径保存为 Rime 个人词库与配置包（.zip）",
                   divider: true) {
          Button(busy ? "处理中…" : "导出个人配置…") { exportPersonal() }
        }

        // —— 导入个人配置 ——
        SettingRow("导入个人配置（词库/配置）",
                   subtitle: "从其它 Rime 输入法导入（.zip / custom_phrase.txt / *.dict.yaml）",
                   divider: false) {
          Button(busy ? "处理中…" : "导入个人配置…") { importPersonal() }
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

  // MARK: - 统计可导出的个人配置文件

  private func personalFiles() -> [(name: String, url: URL)] {
    let fm = FileManager.default
    var result: [(String, URL)] = []

    guard let contents = try? fm.contentsOfDirectory(at: userDir, includingPropertiesForKeys: [.isRegularFileKey]) else {
      return result
    }
    for url in contents {
      let name = url.lastPathComponent
      guard url.pathExtension != "bak" else { continue }        // 跳过备份
      let isCustomYaml = name.hasSuffix(".custom.yaml")
      let isDictYaml = name.hasSuffix(".dict.yaml")              // 用户自定义词典
      let isCustomPhrase = name == "custom_phrase.txt" || name.hasSuffix("_phrases.txt")
      let isUserSettings = name == "user.yaml" || name == "user.custom.yaml"
      if isCustomYaml || isDictYaml || isCustomPhrase || isUserSettings {
        if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
          result.append((name, url))
        }
      }
    }
    return result
  }

  // MARK: - 导出

  private func exportPersonal() {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.zip]
    panel.nameFieldStringValue = "TriFecta-Rime个人配置.zip"
    panel.canCreateDirectories = true
    guard panel.runModal() == .OK, let dest = panel.url else { return }

    let files = personalFiles()
    guard !files.isEmpty else {
      setMessage("未找到可导出的个人词库/配置文件", isError: true)
      return
    }

    busy = true
    DispatchQueue.global(qos: .userInitiated).async {
      let fm = FileManager.default
      let tmp = fm.temporaryDirectory.appendingPathComponent("TriFecta-export-\(UUID().uuidString)")
      do {
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        for (name, url) in files {
          let destURL = tmp.appendingPathComponent(name)
          if fm.fileExists(atPath: destURL.path) { try? fm.removeItem(at: destURL) }
          try fm.copyItem(at: url, to: destURL)
        }
        try? fm.removeItem(at: dest)
        let ok = Self.run(["ditto", "-c", "-k", tmp.path, dest.path])
        try? fm.removeItem(at: tmp)
        DispatchQueue.main.async {
          busy = false
          if ok { setMessage("已导出：\(dest.path)") }
          else { setMessage("导出失败", isError: true) }
        }
      } catch {
        try? fm.removeItem(at: tmp)
        DispatchQueue.main.async {
          busy = false
          setMessage("导出失败：\(error.localizedDescription)", isError: true)
        }
      }
    }
  }

  // MARK: - 导入

  private func importPersonal() {
    let panel = NSOpenPanel()
    var types: [UTType] = [.zip, .plainText]
    if let yaml = UTType(filenameExtension: "yaml") { types.append(yaml) }
    panel.allowedContentTypes = types
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    guard panel.runModal() == .OK, let src = panel.url else { return }

    busy = true
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let ext = src.pathExtension.lowercased()
        let fm = FileManager.default
        var ok = true
        if ext == "zip" {
          try? fm.createDirectory(at: userDir, withIntermediateDirectories: true)
          ok = Self.run(["ditto", "-x", "-k", src.path, userDir.path])
          if ok { try self.wireCustomPhraseIfNeeded() }
        } else if ext == "txt" {
          try fm.copyItem(at: src, to: userDir.appendingPathComponent("custom_phrase.txt"))
          try self.wireCustomPhraseIfNeeded()
        } else if ext == "yaml" {
          try fm.copyItem(at: src, to: userDir.appendingPathComponent(src.lastPathComponent))
        } else {
          ok = false
          DispatchQueue.main.async {
            busy = false
            setMessage("不支持的格式（请使用 .zip / .txt / .yaml）", isError: true)
          }
          return
        }
        DispatchQueue.main.async {
          busy = false
          if ok {
            setMessage("已导入。正在重新部署…")
            Deployer.reload(paths: state.repo.paths)
          } else {
            setMessage("导入失败", isError: true)
          }
        }
      } catch {
        DispatchQueue.main.async {
          busy = false
          setMessage("导入失败：\(error.localizedDescription)", isError: true)
        }
      }
    }
  }

  /// 若导入了 custom_phrase.txt，为常用拼音方案启用 custom_phrase 翻译器（若尚未启用）。
  private func wireCustomPhraseIfNeeded() throws {
    let fm = FileManager.default
    guard fm.fileExists(atPath: userDir.appendingPathComponent("custom_phrase.txt").path) else { return }

    let schemas = ["luna_pinyin_simp", "luna_pinyin"]
    for schema in schemas {
      let url = userDir.appendingPathComponent("\(schema).custom.yaml")
      var content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
      if content.contains("table_translator@custom_phrase") { continue }

      let lines = """
        engine/translators/+:
          - table_translator@custom_phrase
        custom_phrase:
          dictionary: ""
          user_dict: custom_phrase

        """
      if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        content = "patch:\n" + lines
      } else if content.contains("patch:") {
        if !content.hasSuffix("\n") { content += "\n" }
        content += lines
      } else {
        content += "\npatch:\n" + lines
      }
      try content.write(to: url, atomically: true, encoding: .utf8)
    }
  }

  // MARK: - 工具

  @discardableResult
  private static func run(_ args: [String]) -> Bool {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    proc.arguments = Array(args.dropFirst())
    proc.standardOutput = FileHandle.nullDevice
    proc.standardError = FileHandle.nullDevice
    do {
      try proc.run()
      proc.waitUntilExit()
      return proc.terminationStatus == 0
    } catch {
      return false
    }
  }
}
