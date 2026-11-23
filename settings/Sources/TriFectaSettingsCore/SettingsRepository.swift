//
//  把设置变更集写入用户配置文件（保留其它行原字节）。
//
import Foundation
import Yams

public struct ChangeSet: Equatable {
  public var style: StyleValues?
  public var groupColors: GroupColorsValues?
  public var schemaList: [String]?
  public var switchResets: [String: [Int: Int]]?
  /// 自定义短语（custom_phrase.txt）整表快照；非 nil 时覆盖写文件
  public var customPhrases: [CustomPhrase]?

  public init(style: StyleValues? = nil,
              groupColors: GroupColorsValues? = nil,
              schemaList: [String]? = nil,
              switchResets: [String: [Int: Int]]? = nil,
              customPhrases: [CustomPhrase]? = nil) {
    self.style = style
    self.groupColors = groupColors
    self.schemaList = schemaList
    self.switchResets = switchResets
    self.customPhrases = customPhrases
  }
}

public struct ApplyOutcome: Equatable {
  public let filesWritten: [URL]
  public let squirrelYamlCreated: Bool
  public let imeRunning: Bool
}

public final class SettingsRepository {
  public let paths: ConfigPaths
  private let fm = FileManager.default

  public init(paths: ConfigPaths) {
    self.paths = paths
  }

  public convenience init() {
    self.init(paths: .autodetect())
  }

  // MARK: 应用变更

  public func apply(_ changes: ChangeSet, deploy: Bool = true) throws -> ApplyOutcome {
    try fm.createDirectory(at: paths.userDir, withIntermediateDirectories: true)
    var written: [URL] = []
    var created = false

    // 1. squirrel.yaml（style / group_colors）
    if changes.style != nil || changes.groupColors != nil {
      let url = paths.userSquirrelYaml
      // 首次写入：从 SharedSupport 拷贝基线（created 标记用于提示"基线已拷贝"）
      let (text, isNew) = try readOrCreate(url, baseline: paths.sharedSquirrelYaml)
      created = isNew
      let effective = try RimeModel.loadSquirrelYaml(paths: paths).node
      var editor = YamlLineEditor(text: text)
      if let style = changes.style {
        let cur = RimeModel.readStyle(effective)
        if cur.colorScheme != style.colorScheme {
          try editor.setScalar(section: "style", keyText: "color_scheme", value: .string(style.colorScheme))
        }
        if cur.candidateListLayout != style.candidateListLayout {
          try editor.setScalar(section: "style", keyText: "candidate_list_layout", value: .string(style.candidateListLayout))
        }
        if cur.textOrientation != style.textOrientation {
          try editor.setScalar(section: "style", keyText: "text_orientation", value: .string(style.textOrientation))
        }
        if cur.fontFace != style.fontFace {
          try editor.setScalar(section: "style", keyText: "font_face", value: .string(style.fontFace))
        }
        if cur.fontPoint != style.fontPoint {
          try editor.setScalar(section: "style", keyText: "font_point", value: .number(formatNumber(style.fontPoint)))
        }
        if cur.candidateFormat != style.candidateFormat {
          try editor.setScalar(section: "style", keyText: "candidate_format", value: .string(style.candidateFormat))
        }
        if cur.glassOpacity != style.glassOpacity {
          try editor.setScalar(section: "style", keyText: "glass_opacity", value: .number(formatNumber(style.glassOpacity)))
        }
      }
      if let gc = changes.groupColors {
        let cur = RimeModel.readGroupColors(effective)
        var vals: [(String, YamlScalar)] = []
        if cur.enabled != gc.enabled { vals.append(("enabled", .bool(gc.enabled))) }
        if cur.red != gc.red { vals.append(("red", .hexColor(gc.red))) }
        if cur.yellow != gc.yellow { vals.append(("yellow", .hexColor(gc.yellow))) }
        if cur.green != gc.green { vals.append(("green", .hexColor(gc.green))) }
        if cur.triggerKey != gc.triggerKey { vals.append(("trigger_key", .number(String(gc.triggerKey)))) }
        if cur.mode != gc.mode { vals.append(("mode", .string(gc.mode.rawValue))) }
        if cur.dwellSecondKey != gc.dwellSecondKey { vals.append(("dwell_second_key", .number(String(gc.dwellSecondKey)))) }
        if cur.dwellThirdKey != gc.dwellThirdKey { vals.append(("dwell_third_key", .number(String(gc.dwellThirdKey)))) }
        if cur.dwellUseDefaultKeysInGroup != gc.dwellUseDefaultKeysInGroup { vals.append(("dwell_use_default_keys_in_group", .bool(gc.dwellUseDefaultKeysInGroup))) }
        if cur.sliderTriggerKey != gc.sliderTriggerKey { vals.append(("slider_trigger_key", .number(String(gc.sliderTriggerKey)))) }
        if cur.sliderBackKey != gc.sliderBackKey { vals.append(("slider_back_key", .number(String(gc.sliderBackKey)))) }
        if !vals.isEmpty {
          try editor.setSectionValues(section: "group_colors", values: vals)
        }
      }
      let newText = editor.text
      try validateSquirrelText(newText, changes: changes, effective: effective)
      try atomicWrite(url, text: newText)
      written.append(url)
    }

    // 2. default.custom.yaml（schema_list）
    if changes.schemaList != nil {
      let url = paths.userDefaultCustomYaml
      let (text, _) = try readOrCreate(url)
      var editor = YamlLineEditor(text: text)
      if let list = changes.schemaList {
        try editor.replaceBlockList(
          path: ["patch", "schema_list"],
          items: list.map { "- schema: \($0)" }
        )
      }
      let newText = editor.text
      try validateCustomText(newText, fileName: "default.custom.yaml", changes: changes)
      try atomicWrite(url, text: newText)
      written.append(url)
    }

    // 3. <schema>.custom.yaml（switches/@N/reset）
    for (schemaID, resets) in (changes.switchResets ?? [:]).sorted(by: { $0.key < $1.key }) where !resets.isEmpty {
      let url = paths.userSchemaCustomYaml(schemaID)
      let (text, _) = try readOrCreate(url)
      var editor = YamlLineEditor(text: text)
      for (idx, reset) in resets.sorted(by: { $0.key < $1.key }) {
        try editor.setScalar(section: "patch", keyText: "\"switches/@\(idx)/reset\"", value: .number("\(reset)"))
      }
      let newText = editor.text
      try validateCustomText(newText, fileName: "\(schemaID).custom.yaml", changes: nil)
      try atomicWrite(url, text: newText)
      written.append(url)
    }

    // 4. custom_phrase.txt（自定义短语）
    if let phrases = changes.customPhrases {
      let url = try CustomPhraseStore.save(phrases, to: paths.userDir)
      // 旧短语用户词典会让「修改/删除」不生效，先清掉，便于 Rime 依 txt 重建
      CustomPhraseStore.resetUserDict(in: paths.userDir)
      written.append(url)
    }

    let imeRunning: Bool
    if deploy && !written.isEmpty {
      imeRunning = Deployer.reload()
    } else {
      imeRunning = Deployer.isIMERunning
    }
    return ApplyOutcome(filesWritten: written, squirrelYamlCreated: created, imeRunning: imeRunning)
  }

  // MARK: 校验

  private func validateSquirrelText(_ text: String, changes: ChangeSet, effective: Node) throws {
    let node = try RimeModel.compose(text)
    if let style = changes.style {
      let before = RimeModel.readStyle(effective)
      let after = RimeModel.readStyle(node)
      try assertWritten("style/color_scheme", before: before.colorScheme, expected: style.colorScheme, after: after.colorScheme)
      try assertWritten("style/candidate_list_layout", before: before.candidateListLayout, expected: style.candidateListLayout, after: after.candidateListLayout)
      try assertWritten("style/text_orientation", before: before.textOrientation, expected: style.textOrientation, after: after.textOrientation)
      try assertWritten("style/font_face", before: before.fontFace, expected: style.fontFace, after: after.fontFace)
      try assertWritten("style/font_point", before: before.fontPoint, expected: style.fontPoint, after: after.fontPoint)
      try assertWritten("style/candidate_format", before: before.candidateFormat, expected: style.candidateFormat, after: after.candidateFormat)
      try assertWritten("style/glass_opacity", before: before.glassOpacity, expected: style.glassOpacity, after: after.glassOpacity)
    }
    if let gc = changes.groupColors {
      let before = RimeModel.readGroupColors(effective)
      let after = RimeModel.readGroupColors(node)
      try assertWritten("group_colors/enabled", before: before.enabled, expected: gc.enabled, after: after.enabled)
      try assertWritten("group_colors/red", before: before.red, expected: gc.red, after: after.red)
      try assertWritten("group_colors/yellow", before: before.yellow, expected: gc.yellow, after: after.yellow)
      try assertWritten("group_colors/green", before: before.green, expected: gc.green, after: after.green)
      try assertWritten("group_colors/trigger_key", before: before.triggerKey, expected: gc.triggerKey, after: after.triggerKey)
      try assertWritten("group_colors/mode", before: before.mode, expected: gc.mode, after: after.mode)
      try assertWritten("group_colors/dwell_second_key", before: before.dwellSecondKey, expected: gc.dwellSecondKey, after: after.dwellSecondKey)
      try assertWritten("group_colors/dwell_third_key", before: before.dwellThirdKey, expected: gc.dwellThirdKey, after: after.dwellThirdKey)
      try assertWritten("group_colors/dwell_use_default_keys_in_group", before: before.dwellUseDefaultKeysInGroup, expected: gc.dwellUseDefaultKeysInGroup, after: after.dwellUseDefaultKeysInGroup)
      try assertWritten("group_colors/slider_trigger_key", before: before.sliderTriggerKey, expected: gc.sliderTriggerKey, after: after.sliderTriggerKey)
      try assertWritten("group_colors/slider_back_key", before: before.sliderBackKey, expected: gc.sliderBackKey, after: after.sliderBackKey)
    }
  }

  /// 写入校验：某键写入前与预期不同、写入后仍与预期不同，说明该键没写进去。
  private func assertWritten<T: Equatable>(_ path: String, before: T, expected: T, after: T) throws {
    if before != expected, after != expected {
      throw YamlLineEditor.EditorError.malformed("写入校验失败：\(path)")
    }
  }

  private func validateCustomText(_ text: String, fileName: String, changes: ChangeSet?) throws {
    let node = try RimeModel.compose(text)
    guard node["patch"] != nil else {
      throw YamlLineEditor.EditorError.malformed("写入校验失败：\(fileName) 缺少 patch:")
    }
    if fileName == "default.custom.yaml", let changes = changes {
      if let list = changes.schemaList {
        let parsed = node["patch"]?["schema_list"]?.seqNodes?.compactMap { $0["schema"]?.string } ?? []
        if parsed != list {
          throw YamlLineEditor.EditorError.malformed("写入校验失败：\(fileName) schema_list 与预期不符")
        }
      }
    }
  }

  // MARK: 原子写

  /// 读取已存在的用户文件；不存在时用模板创建：
  /// `baseline` ≠ nil 时拷贝 SharedSupport 基线（squirrel.yaml 首写），否则用 `patch:\n` 骨架（custom 文件）。
  private func readOrCreate(_ url: URL, baseline: URL? = nil) throws -> (text: String, created: Bool) {
    if fm.fileExists(atPath: url.path) {
      return (try String(contentsOf: url, encoding: .utf8), false)
    }
    let text: String
    if let baseline = baseline {
      text = try String(contentsOf: baseline, encoding: .utf8)
    } else {
      text = "patch:\n"
    }
    return (text, true)
  }

  private func atomicWrite(_ url: URL, text: String) throws {
    if fm.fileExists(atPath: url.path) {
      let bak = backupURL(for: url)
      try? fm.removeItem(at: bak)
      try fm.copyItem(at: url, to: bak)
    }
    let tmp = url.deletingLastPathComponent().appendingPathComponent(".tri-\(url.lastPathComponent).tmp")
    try text.write(to: tmp, atomically: true, encoding: .utf8)
    if fm.fileExists(atPath: url.path) {
      _ = try fm.replaceItemAt(url, withItemAt: tmp)
    } else {
      try fm.moveItem(at: tmp, to: url)
    }
  }

  private func backupURL(for url: URL) -> URL {
    URL(fileURLWithPath: url.path + ".bak")
  }

  private func formatNumber(_ v: Double) -> String {
    if v.rounded() == v {
      return String(Int(v))
    }
    return String(v)
  }

  // MARK: 回退到基线（还原出厂外观配置）

  /// 移除用户级 squirrel.yaml 与设置 app 生成的 custom 文件（先备份 .bak），
  /// 手改 YAML 的用户文件保持原样不删。
  public func resetToBaseline() throws -> [URL] {
    var moved: [URL] = []
    let candidates = [
      paths.userSquirrelYaml,
      paths.userDefaultCustomYaml,
    ]
    for url in candidates where fm.fileExists(atPath: url.path) {
      let bak = backupURL(for: url)
      try? fm.removeItem(at: bak)
      try fm.moveItem(at: url, to: bak)
      moved.append(url)
    }
    return moved
  }
}
