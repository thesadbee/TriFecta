//
//  界面状态与核心库桥接：加载有效配置、编辑快照、保存并部署。
//
import SwiftUI
import TriFectaSettingsCore

@MainActor
final class AppState: ObservableObject {
  enum Status: Equatable {
    case idle
    case deploying
    case saved(String)
    case failed(String)
  }

  let repo = SettingsRepository()

  /// 载入时的有效快照（保存时逐键 diff，避免把未改动的键"冻结"进用户文件）
  @Published private(set) var loaded: EffectiveModel?

  @Published var style = StyleValues.defaults
  @Published var groupColors = GroupColorsValues.defaults
  @Published var schemaList: [String] = []
  @Published var customizedResets: [String: [Int: Int]] = [:]
  /// 自定义短语（custom_phrase.txt 内容）
  @Published var customPhrases: [CustomPhrase] = []
  /// 载入时的短语快照（用于 diff）
  private(set) var loadedCustomPhrases: [CustomPhrase] = []
  /// 用户在界面明确切换过的简繁状态（推荐默认未落盘时强制写入用）
  private(set) var userResetOverrides: [String: [Int: Int]] = [:]
  @Published var status: Status = .idle
  @Published var lastError: String?
  @Published var showingError = false

  var schemas: [SchemaInfo] { loaded?.schemas ?? [] }
  var schemaListCustomized: Bool { loaded?.schemaListCustomized ?? false }
  var colorSchemes: [(id: String, name: String)] { loaded?.colorSchemes ?? [] }
  var defaultSchema: SchemaInfo? { schemas.first { $0.id == schemaList.first } }

  var isDirty: Bool {
    guard let loaded = loaded else { return false }
    if style != loaded.style { return true }
    if groupColors != loaded.groupColors { return true }
    if schemaList != loaded.schemaList { return true }
    if customPhrases != loadedCustomPhrases { return true }
    if !userResetOverrides.isEmpty { return true }
    return !diffResets(customizedResets, vs: loaded.switchResets).isEmpty
  }

  func reload() {
    do {
      let model = try RimeModel.effectiveModel(paths: repo.paths)
      loaded = model
      style = model.style
      groupColors = model.groupColors
      schemaList = model.schemaList
      customizedResets = model.switchResets
      userResetOverrides = [:]
      customPhrases = CustomPhraseStore.load(from: repo.paths.userDir)
      loadedCustomPhrases = customPhrases
      status = .idle
    } catch {
      lastError = "加载配置失败：\(error.localizedDescription)"
      showingError = true
    }
  }

  func discardChanges() {
    if let loaded = loaded {
      style = loaded.style
      groupColors = loaded.groupColors
      schemaList = loaded.schemaList
      customizedResets = loaded.switchResets
      userResetOverrides = [:]
      customPhrases = loadedCustomPhrases
      status = .idle
    }
  }

  /// 保存：与载入快照逐键 diff，只提交发生变化的键；随后触发重新部署
  func save() {
    guard let loaded = loaded else { return }
    var changeSet = ChangeSet()
    if style != loaded.style { changeSet.style = style }
    if groupColors != loaded.groupColors { changeSet.groupColors = groupColors }
    if schemaList != loaded.schemaList { changeSet.schemaList = schemaList }
    if customPhrases != loadedCustomPhrases { changeSet.customPhrases = customPhrases }
    var resetDiff = diffResets(customizedResets, vs: loaded.switchResets)
    // 推荐默认（未自定义方案列表）：默认仅留推荐方案且默认简体（reset=1）。
    // 仅当用户从未显式保存过该开关时推荐才生效；已保存（custom 文件含键）以用户值为准。
    if !loaded.schemaListCustomized,
       let schemaID = RimeModel.recommendedSchemaList.first,
       let schema = schemas.first(where: { $0.id == schemaID }),
       let sw = schema.simplifiedSwitch,
       loaded.userResetPatchKeys[schemaID]?.contains(sw.index) != true {
      let v = userResetOverrides[schemaID]?[sw.index] ?? 1
      resetDiff[schemaID, default: [:]][sw.index] = v
    }
    if !resetDiff.isEmpty { changeSet.switchResets = resetDiff }

    guard changeSet != ChangeSet() else {
      status = .saved("没有需要保存的更改")
      return
    }

    status = .deploying
    do {
      let outcome = try repo.apply(changeSet, deploy: true)
      reload()
      let files = outcome.filesWritten.map { $0.lastPathComponent }.joined(separator: "、")
      let deployNote = outcome.imeRunning
        ? "已触发输入法重新部署（立即生效）"
        : "输入法未运行，已后台重建数据（下次启用输入法生效）"
      status = .saved("已保存 \(files)。\(deployNote)")
    } catch {
      lastError = "保存失败：\(error.localizedDescription)"
      showingError = true
      status = .failed(error.localizedDescription)
    }
  }

  /// 与载入快照对比 reset 差异（仅关注暴露的简繁/全角开关索引）
  func diffResets(_ a: [String: [Int: Int]], vs b: [String: [Int: Int]]) -> [String: [Int: Int]] {
    var diff: [String: [Int: Int]] = [:]
    for schema in schemas {
      let relevant = Set([schema.simplifiedSwitch?.index, schema.fullShapeSwitch?.index].compactMap { $0 })
      for idx in relevant {
        let av = a[schema.id]?[idx] ?? 0
        let bv = b[schema.id]?[idx] ?? 0
        if av != bv {
          diff[schema.id, default: [:]][idx] = av
        }
      }
    }
    return diff
  }

  // MARK: 便捷读写：简繁 / 全角（作用于当前默认方案）

  var simplifiedDefault: Bool {
    get {
      guard let schema = defaultSchema, let sw = schema.simplifiedSwitch else { return false }
      if let v = userResetOverrides[schema.id]?[sw.index] { return v == 1 }
      // 用户已显式保存过该开关（custom 文件含键）：以文件值为准，推荐默认不再覆盖显示
      if loaded?.userResetPatchKeys[schema.id]?.contains(sw.index) == true {
        return customizedResets[schema.id]?[sw.index] == 1
      }
      if loaded?.schemaListCustomized == false, schema.id == RimeModel.recommendedSchemaList.first { return true }   // 推荐默认=简体
      return customizedResets[schema.id]?[sw.index] == 1
    }
    set {
      guard let schema = defaultSchema, let sw = schema.simplifiedSwitch else { return }
      customizedResets[schema.id, default: [:]][sw.index] = newValue ? 1 : 0
      userResetOverrides[schema.id, default: [:]][sw.index] = newValue ? 1 : 0
    }
  }

  var fullShapeDefault: Bool {
    get { customizedResets[defaultSchema?.id ?? ""]?[defaultSchema?.fullShapeSwitch?.index ?? -1] == 1 }
    set {
      guard let schema = defaultSchema, let sw = schema.fullShapeSwitch else { return }
      customizedResets[schema.id, default: [:]][sw.index] = newValue ? 1 : 0
    }
  }

  // MARK: 方案列表操作

  func setDefaultSchema(_ schemaID: String) {
    var list = schemaList
    guard let idx = list.firstIndex(of: schemaID) else { return }
    list.remove(at: idx)
    list.insert(schemaID, at: 0)
    schemaList = list
  }

  /// 拖拽重排：把 schemaID 移到 targetID 的原位置（目标项及之后顺延）。
  func moveSchema(_ schemaID: String, onto targetID: String) {
    var list = schemaList
    guard let from = list.firstIndex(of: schemaID),
          let target = list.firstIndex(of: targetID),
          from != target else { return }
    let item = list.remove(at: from)
    // 用移除前的目标索引：拖到哪行就顶替其位置（向下拖也在目标之后）
    list.insert(item, at: target)
    schemaList = list
  }

  func toggleSchema(_ schemaID: String) {
    var list = schemaList
    if let idx = list.firstIndex(of: schemaID) {
      list.remove(at: idx)
    } else {
      list.append(schemaID)
    }
    schemaList = list
  }
}
