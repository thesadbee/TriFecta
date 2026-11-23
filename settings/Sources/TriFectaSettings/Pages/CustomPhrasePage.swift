//
//  自定义短语（custom_phrase.txt）编辑页。
//  词条 / 拼音 / 权重 三列，支持增删改；保存随主「保存并应用」一起写入并部署。
//
import SwiftUI
import TriFectaSettingsCore

struct CustomPhrasePage: View {
  @EnvironmentObject private var state: AppState
  @Environment(\.appTheme) private var theme

  var body: some View {
    PageScroll(title: "自定义短语",
               subtitle: "输入拼音时优先出现的自定义词条（custom_phrase.txt）",
               footer: "格式：词条 ⇥ 拼音 ⇥ 权重（Tab 分隔）。保存并应用后会重写 ~/Library/Rime/custom_phrase.txt，并重建短语词典使其立即生效。拼音可用空格分隔多个音节，例如「zhang san feng」。") {
      SettingCard {
        VStack(spacing: 0) {
          headerRow
          Divider()
          if state.customPhrases.isEmpty {
            emptyHint
          } else {
            ForEach($state.customPhrases) { $phrase in
              phraseRow($phrase)
              Divider()
            }
          }
          addRow
        }
      }

      SettingCard {
        SettingRow("导入/导出", subtitle: "进阶用法：直接编辑 custom_phrase.txt 后重新保存一次即可同步", icon: "arrow.up.arrow.down", divider: false) {
          Button("打开所在文件夹") {
            NSWorkspace.shared.open(state.repo.paths.userDir)
          }
        }
      }
    }
  }

  // MARK: - 行

  private var headerRow: some View {
    HStack(spacing: 8) {
      Text("词条").frame(width: 140, alignment: .leading)
      Text("拼音").frame(maxWidth: .infinity, alignment: .leading)
      Text("权重").frame(width: 56, alignment: .leading)
      Spacer().frame(width: 26)
    }
    .font(.system(size: 11, weight: .medium))
    .foregroundColor(.secondary)
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
  }

  private func phraseRow(_ phrase: Binding<CustomPhrase>) -> some View {
    HStack(spacing: 8) {
      TextField("词条", text: phrase.word)
        .textFieldStyle(.roundedBorder)
        .frame(width: 140)
      TextField("拼音，如 zhang san feng", text: phrase.code)
        .textFieldStyle(.roundedBorder)
        .frame(maxWidth: .infinity)
      TextField("权重", value: phrase.weight, format: .number)
        .textFieldStyle(.roundedBorder)
        .frame(width: 56)
      Button {
        remove(phrase.wrappedValue.id)
      } label: {
        Image(systemName: "trash")
          .font(.system(size: 12))
      }
      .buttonStyle(.borderless)
      .help("删除该词条")
      .frame(width: 26)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 6)
  }

  private var emptyHint: some View {
    VStack(spacing: 6) {
      Text("还没有自定义短语")
        .font(.system(size: 12, weight: .medium))
        .foregroundColor(.secondary)
      Text("点击下方「添加词条」，填入词条、拼音与权重后「保存并应用」即可。\n适合添加人名、专业术语等词典里没有的词。")
        .font(.system(size: 11))
        .foregroundColor(.secondary)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 22)
  }

  private var addRow: some View {
    HStack {
      Button {
        state.customPhrases.append(CustomPhrase(word: "", code: "", weight: 1))
      } label: {
        Label("添加词条", systemImage: "plus.circle.fill")
          .font(.system(size: 12, weight: .medium))
      }
      .buttonStyle(.borderless)
      .foregroundColor(theme.accent)
      Spacer()
      if !state.customPhrases.isEmpty {
        Text("共 \(state.customPhrases.count) 条，其中 \(validCount) 条有效")
          .font(.system(size: 11))
          .foregroundColor(.secondary)
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
  }

  private var validCount: Int {
    state.customPhrases.filter { $0.isValid }.count
  }

  private func remove(_ id: UUID) {
    state.customPhrases.removeAll { $0.id == id }
  }
}
