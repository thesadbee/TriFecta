//
//  输入：方案列表（默认简繁、全角标点）。
//
import SwiftUI
import TriFectaSettingsCore

struct InputPage: View {
  @EnvironmentObject private var state: AppState
  @Environment(\.appTheme) private var theme
  @State private var selectedSchema: String?
  @State private var showAddSheet = false
  @State private var dragTarget: String?

  var body: some View {
    PageScroll(title: "输入") {
      SettingCard {
        if !state.schemaListCustomized {
          SettingRow("推荐默认（朙月拼音 · 默认简体）") {
            Text("简体")
              .font(.system(size: 11, weight: .semibold))
              .foregroundColor(theme.accent)
          }
        }

        ForEach(Array(state.schemaList.enumerated()), id: \.element) { index, id in
          schemaRow(id, isDefault: id == state.schemaList.first,
                    showLine: index < state.schemaList.count - 1,
                    dropTargeted: dragTarget == id)
            .onDrag {
              NSItemProvider(object: id as NSString)
            }
            .dropDestination(for: String.self) { items, _ in
              guard let dragged = items.first, dragged != id else { return false }
              withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                state.moveSchema(dragged, onto: id)
              }
              return true
            } isTargeted: { targeted in
              dragTarget = targeted ? id : nil
            }
        }

        // 底部工具条 + / −
        HStack(spacing: 0) {
          Button {
            if let selected = selectedSchema, state.schemaList.count > 1 {
              let wasDefault = selected == state.schemaList.first
              let index = state.schemaList.firstIndex(of: selected) ?? 0
              state.toggleSchema(selected)
              // 移除后 selectedSchema 必须指向存活方案：默认被删 → 重选新第一项；
              // 否则就近重选（不处理的话二次点击会把刚删的方案 append 回列表尾）
              if wasDefault {
                selectedSchema = state.schemaList.first
              } else {
                selectedSchema = state.schemaList[min(index, state.schemaList.count - 1)]
              }
            }
          } label: {
            Image(systemName: "minus")
              .font(.system(size: 13, weight: .semibold))
              .frame(width: 28, height: 24)
          }
          .buttonStyle(.borderless)
          .disabled(selectedSchema == nil || state.schemaList.count <= 1)
          .help("移除选中方案（至少保留一个）")

          Divider().frame(height: 14).padding(.horizontal, 4)

          Button {
            showAddSheet = true
          } label: {
            Image(systemName: "plus")
              .font(.system(size: 13, weight: .semibold))
              .frame(width: 28, height: 24)
          }
          .buttonStyle(.borderless)
          .disabled(availableToAdd.isEmpty)
          .help("添加方案")

          Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
      }

      SettingCard {
        Group {
          if let schema = state.defaultSchema, schema.simplifiedSwitch != nil {
            SettingRow("默认简繁", divider: false) {
              Picker("", selection: Binding(
                get: { state.simplifiedDefault },
                set: { state.simplifiedDefault = $0 }
              )) {
                Text("简体").tag(true)
                Text("繁體").tag(false)
              }
              .pickerStyle(.segmented)
              .frame(width: 150)
            }
          } else {
            SettingRow("默认简繁", subtitle: "当前方案不支持", divider: false) {
              Text("不可用").foregroundColor(.secondary).font(.system(size: 12))
            }
          }
        }
      }

      SettingCard {
        Group {
          if state.defaultSchema?.fullShapeSwitch != nil {
            SettingRow("全角标点", divider: false) {
              Toggle("", isOn: Binding(
                get: { state.fullShapeDefault },
                set: { state.fullShapeDefault = $0 }
              ))
              .toggleStyle(.switch)
              .labelsHidden()
            }
          } else {
            SettingRow("全角标点", subtitle: "当前方案不支持", divider: false) {
              Text("不可用").foregroundColor(.secondary).font(.system(size: 12))
            }
          }
        }
      }
    }
    .onAppear {
      if selectedSchema == nil || !state.schemaList.contains(selectedSchema ?? "") {
        selectedSchema = state.schemaList.first
      }
    }
    .sheet(isPresented: $showAddSheet) {
      AddSchemaSheet(selection: $selectedSchema)
        .environmentObject(state)
    }
  }

  /// 系统设置"所有输入法"式方案行：绿点 = 默认；点击行选中（绿色高亮）
  private func schemaRow(_ id: String, isDefault: Bool, showLine: Bool, dropTargeted: Bool = false) -> some View {
    let isSelected = selectedSchema == id
    return HStack(spacing: 10) {
      Button {
        if !isDefault { state.setDefaultSchema(id) }
        selectedSchema = id
      } label: {
        ZStack {
          Circle()
            .strokeBorder(isDefault ? theme.accent : Color.secondary.opacity(0.45), lineWidth: 1.5)
          if isDefault {
            Circle().fill(theme.accent).padding(2.5)
          }
        }
        .frame(width: 16, height: 16)
        .contentShape(Circle())
      }
      .buttonStyle(.plain)
      .help(isDefault ? "当前默认方案" : "设为默认方案")

      Image(systemName: "keyboard")
        .font(.system(size: 12, weight: .medium))
        .foregroundColor(.secondary)
        .frame(width: 26, height: 26)
        .background(
          RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Color.primary.opacity(0.06))
        )

      VStack(alignment: .leading, spacing: 1) {
        Text(schemaName(id))
          .font(.system(size: 13, weight: isDefault ? .semibold : .regular))
      }
      Spacer()
      if isDefault {
        Text("默认")
          .font(.system(size: 10, weight: .semibold))
          .foregroundColor(theme.accent)
      } else if isSelected {
        Button {
          state.setDefaultSchema(id)
        } label: {
          Text("设为默认")
            .font(.system(size: 10))
            .foregroundColor(theme.accent)
        }
        .buttonStyle(.borderless)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 7)
    .contentShape(Rectangle())
    .background(
      dropTargeted ? theme.accent.opacity(0.12)
        : (isSelected ? theme.accent.opacity(0.07) : Color.clear)
    )
    .onTapGesture {
      selectedSchema = id
    }
    .overlay(alignment: .bottom) {
      if showLine {
        Divider().padding(.leading, 48)
      }
    }
  }

  private var availableToAdd: [String] {
    let enabled = Set(state.schemaList)
    return state.schemas.map { $0.id }.filter { !enabled.contains($0) }
  }

  /// 方案分组（仅用于添加面板的二级选择；Tid: 版本不区分语言细节）
  static let schemaGroups = ["拼音", "注音", "五笔 · 形码", "笔画", "其它"]

  static func groupOf(_ id: String) -> String {
    let g = id.lowercased()
    if g.hasPrefix("bopomofo") { return "注音" }
    if g.hasPrefix("cangjie") || g.hasPrefix("quick") { return "五笔 · 形码" }
    if g.hasPrefix("stroke") { return "笔画" }
    if g.hasPrefix("luna") || g.hasPrefix("terra") || g.hasPrefix("double") { return "拼音" }
    return "其它"
  }

  private func schemaName(_ id: String) -> String {
    state.schemas.first { $0.id == id }?.displayName ?? id
  }
}

/// 添加方案弹窗：左分组、右方案多选、底部添加
struct AddSchemaSheet: View {
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var state: AppState
  @Environment(\.appTheme) private var theme
  @Binding var selection: String?
  @State private var currentGroup = InputPage.schemaGroups[0]
  @State private var checked: Set<String> = []

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("添加输入方案")
        .font(.system(size: 15, weight: .semibold))
        .padding(.top, 14)
        .padding(.horizontal, 18)

      HStack(spacing: 0) {
        // 左：分组
        VStack(alignment: .leading, spacing: 2) {
          ForEach(groupsWithItems, id: \.self) { group in
            Button {
              currentGroup = group
            } label: {
              HStack {
                Text(group)
                  .font(.system(size: 12))
                Spacer()
                Text("\(items(in: group).count)")
                  .font(.system(size: 10, design: .monospaced))
                  .foregroundColor(.secondary)
              }
              .padding(.vertical, 7)
              .padding(.horizontal, 10)
              .frame(maxWidth: .infinity, alignment: .leading)
              .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                  .fill(currentGroup == group ? theme.accent.opacity(0.12) : Color.clear)
              )
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundColor(currentGroup == group ? theme.accent : .primary)
          }
          Spacer()
        }
        .padding(10)
        .frame(width: 150)

        Divider()

        // 右：方案多选
        ScrollView {
          VStack(spacing: 0) {
            ForEach(items(in: currentGroup), id: \.id) { schema in
              let enabled = state.schemaList.contains(schema.id)
              buttonRow(schema, enabled: enabled)
            }
          }
        }
        .frame(maxWidth: .infinity)
        .background(EmbeddedScrollerStyler())
      }
      .frame(maxHeight: 330)

      HStack(spacing: 10) {
        if !checked.isEmpty {
          Text("已选择 \(checked.count) 个方案")
            .font(.system(size: 11))
            .foregroundColor(.secondary)
        }
        Spacer()
        GlassActionButton(title: "取消") { dismiss() }
        GlassActionButton(title: "添加\(checked.isEmpty ? "" : "（\(checked.count)）")",
                          systemImage: "plus.circle.fill", prominent: true) {
          for id in checked where !state.schemaList.contains(id) {
            state.toggleSchema(id)
          }
          selection = checked.sorted().last ?? selection
          dismiss()
        }
        .disabled(checked.isEmpty)
        .opacity(checked.isEmpty ? 0.45 : 1)
      }
      .padding(.horizontal, 18)
      .padding(.bottom, 14)
    }
    .frame(width: 560, height: 440)
    .background(Color(nsColor: .windowBackgroundColor))
  }

  private func buttonRow(_ schema: SchemaInfo, enabled: Bool) -> some View {
    let isChecked = checked.contains(schema.id)
    return HStack(spacing: 10) {
      ZStack {
        if enabled {
          Circle().fill(theme.accent.opacity(0.85))
          Image(systemName: "checkmark")
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(.white)
        } else if isChecked {
          Circle().fill(theme.accent)
          Image(systemName: "checkmark")
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(.white)
        } else {
          Circle().strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1.5)
        }
      }
      .frame(width: 16, height: 16)

      Image(systemName: "keyboard")
        .font(.system(size: 12))
        .foregroundColor(.secondary)
        .frame(width: 24, height: 24)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.06)))

      VStack(alignment: .leading, spacing: 1) {
        Text(schema.displayName)
          .font(.system(size: 12, weight: .medium))
          .foregroundColor(enabled ? .secondary : .primary)
      }
      Spacer()
      if enabled {
        Text("已启用")
          .font(.system(size: 9))
          .foregroundColor(.secondary)
      }
    }
    .padding(.vertical, 6)
    .padding(.horizontal, 12)
    .contentShape(Rectangle())
    .onTapGesture {
      guard !enabled else { return }
      if isChecked {
        checked.remove(schema.id)
      } else {
        checked.insert(schema.id)
      }
    }
    .overlay(alignment: .bottom) { Divider().padding(.leading, 52) }
  }

  private var groupsWithItems: [String] {
    InputPage.schemaGroups.filter { !items(in: $0).isEmpty }
  }

  private func items(in group: String) -> [SchemaInfo] {
    let all = state.schemas.filter { InputPage.groupOf($0.id) == group }
    return all.sorted { $0.id < $1.id }
  }
}
