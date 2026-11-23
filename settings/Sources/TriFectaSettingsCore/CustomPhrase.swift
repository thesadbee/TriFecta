//
//  自定义短语（custom_phrase.txt）的读写。
//  文件格式：每行 `词条<TAB>拼音<TAB>权重`；以 # 开头的行与空行忽略。
//  该文件被 Rime 的 custom_phrase 翻译器使用（luna_pinyin 等方案已启用）。
//

import Foundation

public struct CustomPhrase: Identifiable, Equatable {
  public var id: UUID
  public var word: String
  public var code: String
  public var weight: Double

  public init(id: UUID = UUID(), word: String = "", code: String = "", weight: Double = 1) {
    self.id = id
    self.word = word
    self.code = code
    self.weight = weight
  }

  /// 词条与拼音都非空才算有效行
  public var isValid: Bool {
    !word.trimmingCharacters(in: .whitespaces).isEmpty
      && !code.trimmingCharacters(in: .whitespaces).isEmpty
  }
}

public enum CustomPhraseStore {
  public static let fileName = "custom_phrase.txt"
  /// 短语用户词典目录名（Rime 由 custom_phrase.txt 导入后生成）
  public static let userDictName = "custom_phrase.userdb"

  public static func fileURL(in userDir: URL) -> URL {
    userDir.appendingPathComponent(fileName)
  }

  public static func userDictURL(in userDir: URL) -> URL {
    userDir.appendingPathComponent(userDictName)
  }

  /// 读取；文件不存在或解析不到内容时返回空数组
  public static func load(from userDir: URL) -> [CustomPhrase] {
    let url = fileURL(in: userDir)
    guard let data = try? Data(contentsOf: url),
          let text = String(data: data, encoding: .utf8) else { return [] }
    return parse(text)
  }

  /// 解析文本为词条数组（容错：列数不足/权重非数字时给默认值）
  public static func parse(_ text: String) -> [CustomPhrase] {
    var result: [CustomPhrase] = []
    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
      let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
      if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
      let columns = rawLine.split(separator: "\t", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces) }
      guard columns.count >= 2 else { continue }
      let word = columns[0]
      guard !word.isEmpty else { continue }
      let code = columns[1]
      var weight = 1.0
      if columns.count >= 3, let parsed = Double(columns[2]) { weight = parsed }
      result.append(CustomPhrase(word: word, code: code, weight: weight))
    }
    return result
  }

  /// 序列化为 custom_phrase.txt 内容（带表头注释）
  public static func serialize(_ phrases: [CustomPhrase]) -> String {
    var lines = ["# 词条\t拼音\t权重（由 TriFecta 设置面板生成，可手动编辑）"]
    for phrase in phrases where phrase.isValid {
      let word = phrase.word.trimmingCharacters(in: .whitespaces)
      let code = phrase.code.trimmingCharacters(in: .whitespaces)
      lines.append("\(word)\t\(code)\t\(formatWeight(phrase.weight))")
    }
    return lines.joined(separator: "\n") + "\n"
  }

  /// 写入 custom_phrase.txt；返回写入的文件路径
  @discardableResult
  public static func save(_ phrases: [CustomPhrase], to userDir: URL) throws -> URL {
    let fm = FileManager.default
    try fm.createDirectory(at: userDir, withIntermediateDirectories: true)
    let url = fileURL(in: userDir)
    let text = serialize(phrases)
    guard let data = text.data(using: .utf8) else {
      throw NSError(domain: "CustomPhraseStore", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "文本编码失败"])
    }
    try data.write(to: url, options: .atomic)
    return url
  }

  /// 删除短语用户词典，促使 Rime 依据最新的 custom_phrase.txt 重建，
  /// 从而让“修改/删除词条”也能生效（否则旧词典会继续生效）。
  public static func resetUserDict(in userDir: URL) {
    let fm = FileManager.default
    let dbURL = userDictURL(in: userDir)
    guard fm.fileExists(atPath: dbURL.path) else { return }
    try? fm.removeItem(at: dbURL)
    // LevelDB 可能残留的日志/清单文件一并清理
    for suffix in [".log", ".LOG", ".ldb", ".sst"] {
      let stray = userDir.appendingPathComponent(userDictName + suffix)
      if fm.fileExists(atPath: stray.path) { try? fm.removeItem(at: stray) }
    }
  }

  static func formatWeight(_ weight: Double) -> String {
    if weight == weight.rounded() && abs(weight) < Double(Int.max) {
      return String(Int(weight))
    }
    return String(format: "%g", weight)
  }
}
