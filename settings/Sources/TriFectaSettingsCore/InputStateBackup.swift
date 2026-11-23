//
//  输入状态备份 / 还原。
//  打包内容涵盖三类「权重」数据：
//    1) 用户自定义短语（custom_phrase.txt）
//    2) 词典内固有词的词频/权重（<dict>.userdb 内的用户词典条目）
//    3) 词典外学习到的词（encode_commit_history 写入同一 userdb）
//  这些数据在 Rime 里均落在 ~/Library/Rime/ 的 *.userdb 目录与 custom_phrase.txt，
//  因此直接整包复制即可完整保留，换机/重装后可原样还原。
//

import Foundation

public enum InputStateBackup {
  public static let manifestName = "TriFecta-输入状态备份.txt"
  public static let userDictSuffix = ".userdb"

  public enum BackupError: LocalizedError {
    case nothingToExport
    case archiveFailed
    case extractFailed
    case nothingToRestore

    public var errorDescription: String? {
      switch self {
      case .nothingToExport: return "没有可导出的输入状态（未找到用户词典）"
      case .archiveFailed: return "打包失败"
      case .extractFailed: return "解包失败"
      case .nothingToRestore: return "备份包中没有可还原的输入状态"
      }
    }
  }

  /// 扫描用户目录，列出需要备份的条目（*.userdb 目录 + custom_phrase.txt）
  public static func collectItems(in userDir: URL) -> [String] {
    let fm = FileManager.default
    guard let entries = try? fm.contentsOfDirectory(
      at: userDir, includingPropertiesForKeys: [.isDirectoryKey]
    ) else { return [] }

    var names: [String] = []
    for url in entries {
      let name = url.lastPathComponent
      if name.hasSuffix(userDictSuffix) {
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
          names.append(name)
        }
      } else if name == CustomPhraseStore.fileName {
        names.append(name)
      }
    }
    return names.sorted()
  }

  /// 导出为 zip 备份包，返回已打包的条目名
  public static func export(to zipURL: URL, userDir: URL) throws -> [String] {
    let fm = FileManager.default
    let items = collectItems(in: userDir)
    guard !items.isEmpty else { throw BackupError.nothingToExport }

    let temp = fm.temporaryDirectory.appendingPathComponent("TriFectaStateExport-\(UUID().uuidString)")
    try fm.createDirectory(at: temp, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: temp) }

    for name in items {
      let src = userDir.appendingPathComponent(name)
      let dst = temp.appendingPathComponent(name)
      if fm.fileExists(atPath: dst.path) { try? fm.removeItem(at: dst) }
      try fm.copyItem(at: src, to: dst)
    }

    let manifest = """
    TriFecta 输入状态备份
    =====================
    导出时间: \(ISO8601DateFormatter().string(from: Date()))
    条目数: \(items.count)
    条目:
    \(items.map { "  - \($0)" }.joined(separator: "\n"))

    说明:
    - *.userdb 为用户词典（含词典内词的词频、以及词典外上屏历史学习到的词）
    - custom_phrase.txt 为用户自定义短语
    在新设备/重装后，于「设置 → 同步 → 导入输入状态」选择本备份包即可还原。
    """
    if let data = manifest.data(using: .utf8) {
      try? data.write(to: temp.appendingPathComponent(manifestName))
    }

    try? fm.removeItem(at: zipURL)
    guard runZip(["-c", "-k", "--norsrc", "--noextattr", temp.path, zipURL.path]) else {
      throw BackupError.archiveFailed
    }
    return items
  }

  /// 从 zip 备份包还原，返回已还原的条目名
  public static func restore(from zipURL: URL, userDir: URL) throws -> [String] {
    let fm = FileManager.default
    let temp = fm.temporaryDirectory.appendingPathComponent("TriFectaStateRestore-\(UUID().uuidString)")
    try fm.createDirectory(at: temp, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: temp) }

    guard runZip(["-x", "-k", zipURL.path, temp.path]) else {
      throw BackupError.extractFailed
    }

    guard let entries = try? fm.contentsOfDirectory(
      at: temp, includingPropertiesForKeys: [.isDirectoryKey]
    ) else { throw BackupError.nothingToRestore }

    var restored: [String] = []
    for url in entries {
      let name = url.lastPathComponent
      let isUserDict = name.hasSuffix(userDictSuffix)
      let isPhraseFile = name == CustomPhraseStore.fileName
      guard isUserDict || isPhraseFile else { continue }

      let dest = userDir.appendingPathComponent(name)
      if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }
      try fm.copyItem(at: url, to: dest)
      restored.append(name)
    }

    guard !restored.isEmpty else { throw BackupError.nothingToRestore }
    return restored.sorted()
  }

  @discardableResult
  private static func runZip(_ args: [String]) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    process.arguments = args
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
      process.waitUntilExit()
      return process.terminationStatus == 0
    } catch {
      return false
    }
  }
}
