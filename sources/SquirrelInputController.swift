//
//  SquirrelInputController.swift
//  Squirrel
//
//  Created by Leo Liu on 5/7/24.
//

import InputMethodKit

final class SquirrelInputController: IMKInputController {
  private static let keyRollOver = 50
  private static var unknownAppCnt: UInt = 0

  private weak var client: IMKTextInput?
  private let rimeAPI: RimeApi_stdbool = rime_get_api_stdbool().pointee
  private var preedit: String = ""
  private var selRange: NSRange = .empty
  private var caretPos: Int = 0
  private var lastModifiers: NSEvent.ModifierFlags = .init()
  private var session: RimeSessionId = 0
  private var schemaId: String = ""
  private var inlinePreedit = false
  private var inlineCandidate = false
  // 三色分组递进选字：`~` 是否开启（切换，而非长按）、当前选中的组号(0/1/2)
  private var tildeDown = false
  private var tildeGroup: Int?
  // 滑块模式：当前聚焦的三色组号(0/1/2)。候选变化时重置为 0。
  private var sliderGroupIndex = 0
  // 用 Shift+字母 输出大写后，临时屏蔽 Shift 的中英切换一小段，防止松开 Shift 时误切换。
  private var shiftSupressedUntil: Date = .distantPast
  private var chordKeyCodes: [UInt32] = .init(repeating: 0, count: SquirrelInputController.keyRollOver)
  private var chordModifiers: [UInt32] = .init(repeating: 0, count: SquirrelInputController.keyRollOver)
  private var chordKeyCount: Int = 0
  private var chordTimer: Timer?
  private var chordDuration: TimeInterval = 0
  private var currentApp: String = ""

  // swiftlint:disable:next cyclomatic_complexity
  override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
    guard let event = event else { return false }
    let modifiers = event.modifierFlags
    let changes = lastModifiers.symmetricDifference(modifiers)

    // Return true to consume the key event; return false to pass it to the client app.
    var handled = false

    if session == 0 || !rimeAPI.find_session(session) {
      createSession()
      if session == 0 {
        return false
      }
    }

    self.client ?= sender as? IMKTextInput
    if let app = client?.bundleIdentifier(), currentApp != app {
      currentApp = app
      updateAppOptions()
    }

    switch event.type {
    case .flagsChanged:
      if lastModifiers == modifiers {
        handled = true
        break
      }
      var rimeModifiers: UInt32 = SquirrelKeycode.osxModifiersToRime(modifiers: modifiers)
      // Some remote desktop tools send flagsChanged with keyCode 0; infer the real modifier key when needed.
      var keyCode = event.keyCode
      if !SquirrelKeycode.modifierKeycodes.contains(keyCode) {
        guard let inferred = SquirrelKeycode.inferModifierKeycode(from: changes) else {
          lastModifiers = modifiers
          rimeUpdate()
          handled = true
          break
        }
        keyCode = inferred
      }
      let rimeKeycode: UInt32 = SquirrelKeycode.osxKeycodeToRime(keycode: keyCode, keychar: nil, shift: false, caps: false)

      if changes.contains(.capsLock) {
        // Rime expects XK_Caps_Lock before the lock mask changes; NSFlagsChanged has already applied it.
        rimeModifiers ^= kLockMask.rawValue
        _ = processKey(rimeKeycode, modifiers: rimeModifiers)
      }

      // Process releases first because some modifier releases arrive with the next keydown.
      var buffer = [(keycode: UInt32, modifier: UInt32)]()
      for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] where changes.contains(flag) {
        if modifiers.contains(flag) {
          buffer.append((keycode: rimeKeycode, modifier: rimeModifiers))
        } else {
          let isShiftRelease = (flag == .shift)
          // 用 Shift+字母 输出大写后，短暂屏蔽 Shift 的中英切换，避免松开时误切中英。
          if isShiftRelease, Date() < shiftSupressedUntil {
            continue
          }
          buffer.insert((keycode: rimeKeycode, modifier: rimeModifiers | kReleaseMask.rawValue), at: 0)
        }
      }
      for (keycode, modifier) in buffer {
        _ = processKey(keycode, modifiers: modifier)
      }

      lastModifiers = modifiers
      rimeUpdate()

    case .keyDown:
      let keyCode = event.keyCode
      let candidateCount = NSApp.squirrelAppDelegate.panel?.candidateCount ?? 0
      // 三色分组递进选字：交给 handleTriColor 处理，命中则消费该键（跳过后面的 processKey）。
      if handleTriColor(keyCode: keyCode, candidateCount: candidateCount) {
        handled = true   // 关键：标记已消费，否则 IMK 会把键当字符输入
        break
      }

      // Let client apps handle Command shortcuts.
      if modifiers.contains(.command) {
        break
      }

      // 中文状态按住 Shift+字母：直接输出对应大写字母，不进入 Rime 拼音候选，
      // 避免非法拼音无候选框、影响后续汉字输入。仅当 Shift 按下且为字母键时。
      // 仅在空闲（未在拼音组字中）时生效：commit(string:) 只清本地 preedit，不会
      // 同步清空 Rime 引擎内部的组字状态，若在组字过程中触发会导致两边状态错位、
      // 后续输入错乱，因此组字中让这个键正常走 processKey 交给 Rime 处理。
      if preedit.isEmpty,
         modifiers.contains(.shift), !modifiers.contains(.control),
         !modifiers.contains(.option), !modifiers.contains(.command),
         let ch = event.charactersIgnoringModifiers?.first, ch.isLetter {
        let upper = String(ch).uppercased()
        commit(string: upper)
        shiftSupressedUntil = Date().addingTimeInterval(1.0)   // 屏蔽 Shift 切换 1 秒
        handled = true
        break
      }

      var keyChars = event.charactersIgnoringModifiers
      let capitalModifiers = modifiers.isSubset(of: [.shift, .capsLock])
      if let code = keyChars?.first,
         (capitalModifiers && !code.isLetter) || (!capitalModifiers && !code.isASCII) {
        keyChars = event.characters
      }
      if let char = keyChars?.first {
        let rimeKeycode = SquirrelKeycode.osxKeycodeToRime(keycode: keyCode, keychar: char,
                                                           shift: modifiers.contains(.shift),
                                                           caps: modifiers.contains(.capsLock))
        if rimeKeycode != 0 {
          let rimeModifiers = SquirrelKeycode.osxModifiersToRime(modifiers: modifiers)
          handled = processKey(rimeKeycode, modifiers: rimeModifiers)
          rimeUpdate()
        }
      }

    case .keyUp:
      // `~` 用切换逻辑（在 keyDown 里开/关），这里不做处理；keyUp 一般不会送达 IMK
      break

    default:
      break
    }

    return handled
  }


  /// 三色分组递进选字（三模式）。返回 true 表示该键已被三色逻辑消费。
  /// 命中后调用方应跳过后续 processKey，避免触发键/数字被当作字符输入。
  private func handleTriColor(keyCode: UInt16, candidateCount: Int) -> Bool {
    let triEnabled = NSApp.squirrelAppDelegate.config?.getBool("group_colors/enabled") ?? true
    let triMode = NSApp.squirrelAppDelegate.config?.getString("group_colors/mode") ?? "trigger"
    let triTriggerKey = Int(NSApp.squirrelAppDelegate.config?.getString("group_colors/trigger_key") ?? "") ?? 50
    let dwellSecondKey = Int(NSApp.squirrelAppDelegate.config?.getString("group_colors/dwell_second_key") ?? "") ?? 50
    let dwellThirdKey = Int(NSApp.squirrelAppDelegate.config?.getString("group_colors/dwell_third_key") ?? "") ?? 48
    let dwellUseDefault = NSApp.squirrelAppDelegate.config?.getBool("group_colors/dwell_use_default_keys_in_group") ?? false
    let sliderTriggerKey = Int(NSApp.squirrelAppDelegate.config?.getString("group_colors/slider_trigger_key") ?? "") ?? 50
    let sliderBackKey = Int(NSApp.squirrelAppDelegate.config?.getString("group_colors/slider_back_key") ?? "") ?? 48
    let groupSize = max(1, Int((Double(candidateCount) / 3.0).rounded(.up)))
    let groupCount = min(3, (candidateCount + groupSize - 1) / groupSize)
    let isGroupSel = [18, 19, 20].contains(keyCode)   // 1/2/3
    let itemNum = Int(keyCode) - 17                    // 18->1, 19->2, 20->3

    // 仅在有候选时处理三色（数字/触发键才与候选绑定）；无候选时放行数字等键，
    // 避免常驻/滑块模式下无法打出 1/2/3。
    guard triEnabled, candidateCount > 0 else { return false }

    switch triMode {
    case "dwell":
      // ---- 常驻模式：候选出现即开一级菜单，无需触发键 ----
      if !tildeDown {
        tildeDown = true
        tildeGroup = nil
        NSApp.squirrelAppDelegate.panel?.setGroupMode(true)
        NSApp.squirrelAppDelegate.panel?.setSelectedGroup(nil)
      }
      if tildeGroup == nil {
        // 一级菜单：前 3 个候选（第1组）用 1 / dwellSecondKey / dwellThirdKey 直接选
        if keyCode == 18 {
          _ = selectCandidate(0)
          finishTriSelect()
          return true
        } else if keyCode == dwellSecondKey {
          _ = selectCandidate(1)
          finishTriSelect()
          return true
        } else if keyCode == dwellThirdKey {
          _ = selectCandidate(2)
          finishTriSelect()
          return true
        } else if keyCode == 19 || keyCode == 20 {
          tildeGroup = itemNum - 1
          NSApp.squirrelAppDelegate.panel?.setSelectedGroup(tildeGroup)
          return true
        }
      } else {
        // 已进第2/3组二级菜单
        var consumed = false
        if dwellUseDefault {
          if keyCode == 18 {
            _ = selectCandidate(tildeGroup! * groupSize + 0); consumed = true
          } else if keyCode == dwellSecondKey {
            _ = selectCandidate(tildeGroup! * groupSize + 1); consumed = true
          } else if keyCode == dwellThirdKey {
            _ = selectCandidate(tildeGroup! * groupSize + 2); consumed = true
          } else if isGroupSel {
            _ = selectCandidate(tildeGroup! * groupSize + (itemNum - 1)); consumed = true
          }
        } else {
          if isGroupSel {
            _ = selectCandidate(tildeGroup! * groupSize + (itemNum - 1)); consumed = true
          }
        }
        if consumed {
          finishTriSelect()
          return true
        }
        return false
      }
      return false

    case "slider":
      // ---- 滑块模式：常驻显示某组二级菜单，触发键平移组 + 到末尾翻页 ----
      if keyCode == sliderTriggerKey {
        if sliderGroupIndex < groupCount - 1 {
          sliderGroupIndex += 1
        } else {
          _ = page(up: false)   // 向后翻页（Rime change_page: backward=false = 下一页，= 键）
          rimeUpdate()
          sliderGroupIndex = 0
        }
        NSApp.squirrelAppDelegate.panel?.setGroupMode(true)
        NSApp.squirrelAppDelegate.panel?.setSelectedGroup(sliderGroupIndex)
        return true
      }
      // 回退键：滑块返回上一组（到第一组则保持第一组）
      if keyCode == sliderBackKey {
        if sliderGroupIndex > 0 {
          sliderGroupIndex -= 1
        } else {
          _ = page(up: true)   // 已在第一组：回退则向前翻一页（上一组候选）
          rimeUpdate()
          sliderGroupIndex = groupCount - 1
        }
        NSApp.squirrelAppDelegate.panel?.setGroupMode(true)
        NSApp.squirrelAppDelegate.panel?.setSelectedGroup(sliderGroupIndex)
        return true
      }
      if !tildeDown {
        tildeDown = true
        NSApp.squirrelAppDelegate.panel?.setGroupMode(true)
        NSApp.squirrelAppDelegate.panel?.setSelectedGroup(sliderGroupIndex)
      }
      if isGroupSel {
        _ = selectCandidate(sliderGroupIndex * groupSize + (itemNum - 1))
        // 滑块模式：选字后不退出三色，保持常驻并回到第一组，便于连续选字。
        tildeDown = true
        sliderGroupIndex = 0
        NSApp.squirrelAppDelegate.panel?.setGroupMode(true)
        NSApp.squirrelAppDelegate.panel?.setSelectedGroup(0)
        return true
      }
      return false

    default:
      // ---- 触发模式：按触发键进入三色，1/2/3 选组/选字 ----
      if keyCode == triTriggerKey {
        if !tildeDown {
          tildeDown = true
          tildeGroup = nil
          NSApp.squirrelAppDelegate.panel?.setGroupMode(true)
          NSApp.squirrelAppDelegate.panel?.setSelectedGroup(nil)
        } else if tildeGroup != nil {
          tildeGroup = nil
          NSApp.squirrelAppDelegate.panel?.setSelectedGroup(nil)
        } else {
          tildeDown = false
          NSApp.squirrelAppDelegate.panel?.setGroupMode(false)
        }
        return true
      }
      if tildeDown, isGroupSel {
        if tildeGroup == nil {
          tildeGroup = itemNum - 1
          NSApp.squirrelAppDelegate.panel?.setSelectedGroup(tildeGroup)
        } else {
          _ = selectCandidate(tildeGroup! * groupSize + (itemNum - 1))
          finishTriSelect()
        }
        return true
      }
      if tildeDown, tildeGroup != nil {
        tildeGroup = nil
      }
      return false
    }
  }

  /// 选中候选后：清组、退出三色、回到蓝色。
  private func finishTriSelect() {
    tildeGroup = nil
    tildeDown = false
    NSApp.squirrelAppDelegate.panel?.setGroupMode(false)
  }


  func selectCandidate(_ index: Int) -> Bool {
    let success = rimeAPI.select_candidate_on_current_page(session, index)
    if success {
      rimeUpdate()
    }
    return success
  }

  // swiftlint:disable:next identifier_name
  func page(up: Bool) -> Bool {
    var handled = false
    handled = rimeAPI.change_page(session, up)
    if handled {
      rimeUpdate()
    }
    return handled
  }

  func moveCaret(forward: Bool) -> Bool {
    let currentCaretPos = rimeAPI.get_caret_pos(session)
    guard let input = rimeAPI.get_input(session) else { return false }
    if forward {
      if currentCaretPos <= 0 {
        return false
      }
      rimeAPI.set_caret_pos(session, currentCaretPos - 1)
    } else {
      let inputStr = String(cString: input)
      if currentCaretPos >= inputStr.utf8.count {
        return false
      }
      rimeAPI.set_caret_pos(session, currentCaretPos + 1)
    }
    rimeUpdate()
    return true
  }

  override func recognizedEvents(_ sender: Any!) -> Int {
    // keyDown + keyUp（感知 `~` 松开以退出三色分组）+ flagsChanged
    return Int(NSEvent.EventTypeMask.Element(arrayLiteral: .keyDown, .keyUp, .flagsChanged).rawValue)
  }

  override func activateServer(_ sender: Any!) {
    self.client ?= sender as? IMKTextInput
    var keyboardLayout = NSApp.squirrelAppDelegate.config?.getString("keyboard_layout") ?? ""
    if keyboardLayout == "last" || keyboardLayout == "" {
      keyboardLayout = ""
    } else if keyboardLayout == "default" {
      keyboardLayout = "com.apple.keylayout.ABC"
    } else if !keyboardLayout.hasPrefix("com.apple.keylayout.") {
      keyboardLayout = "com.apple.keylayout.\(keyboardLayout)"
    }
    if keyboardLayout != "" {
      client?.overrideKeyboard(withKeyboardNamed: keyboardLayout)
    }
    // Activation delivers no flagsChanged event, and NSEvent.modifierFlags
    // only reflects this process's own event stream, so lastModifiers may
    // disagree with the actual Caps Lock state by now. Seed it from the
    // session-wide hardware state; otherwise the next Caps Lock press can
    // compare equal to the stale lastModifiers and be dropped by the
    // early-return in handle().
    if CGEventSource.flagsState(.combinedSessionState).contains(.maskAlphaShift) {
      lastModifiers.insert(.capsLock)
    } else {
      lastModifiers.remove(.capsLock)
    }
    preedit = ""
    if session != 0 {
      let state = rimeAPI.get_option(session, "ascii_mode")
      let label = rimeAPI.get_state_label_abbreviated(session, "ascii_mode", state, true).asString
      NSApp.squirrelAppDelegate.updateStatusIcon(asciiMode: state, schemaLabel: label)
    }
  }

  override init!(server: IMKServer!, delegate: Any!, client: Any!) {
    self.client = client as? IMKTextInput
    super.init(server: server, delegate: delegate, client: client)
    createSession()

    NotificationCenter.default.addObserver(
      forName: .init("SquirrelSetASCIIModeNotification"),
      object: nil,
      queue: nil
    ) { [weak self] notification in
      self?.handleASCIIModeToggle(notification)
    }

    NotificationCenter.default.addObserver(
      forName: .init("SquirrelReportASCIIModeNotification"),
      object: nil,
      queue: nil
    ) { [weak self] notification in
      self?.reportASCIIMode(notification)
    }
  }

  override func deactivateServer(_ sender: Any!) {
    hidePalettes()
    commitComposition(sender)
    client = nil
  }

  override func hidePalettes() {
    NSApp.squirrelAppDelegate.panel?.hide()
    super.hidePalettes()
  }

  override func commitComposition(_ sender: Any!) {
    self.client ?= sender as? IMKTextInput
    if session != 0 {
      if let input = rimeAPI.get_input(session) {
        commit(string: String(cString: input))
        rimeAPI.clear_composition(session)
      }
    }
  }

  override func menu() -> NSMenu! {
    let deploy = NSMenuItem(title: NSLocalizedString("Deploy", comment: "Menu item"), action: #selector(deploy), keyEquivalent: "`")
    deploy.target = self
    deploy.keyEquivalentModifierMask = [.control, .option]
    let sync = NSMenuItem(title: NSLocalizedString("Sync user data", comment: "Menu item"), action: #selector(syncUserData), keyEquivalent: "")
    sync.target = self
    let logDir = NSMenuItem(title: NSLocalizedString("Logs...", comment: "Menu item"), action: #selector(openLogFolder), keyEquivalent: "")
    logDir.target = self
    let setting = NSMenuItem(title: NSLocalizedString("Settings...", comment: "Menu item"), action: #selector(openSettingsApp), keyEquivalent: "")
    setting.target = self
    let rimeFolder = NSMenuItem(title: NSLocalizedString("Open Rime folder...", comment: "Menu item"), action: #selector(openRimeFolder), keyEquivalent: "")
    rimeFolder.target = self
    let wiki = NSMenuItem(title: NSLocalizedString("Rime Wiki...", comment: "Menu item"), action: #selector(openWiki), keyEquivalent: "")
    wiki.target = self
    let update = NSMenuItem(title: NSLocalizedString("Check for updates...", comment: "Menu item"), action: #selector(checkForUpdates), keyEquivalent: "")
    update.target = self

    let menu = NSMenu()
    menu.addItem(deploy)
    menu.addItem(sync)
    menu.addItem(logDir)
    menu.addItem(setting)
    menu.addItem(rimeFolder)
    menu.addItem(wiki)
    menu.addItem(update)

    return menu
  }

  @objc func deploy() {
    NSApp.squirrelAppDelegate.deploy()
  }

  @objc func syncUserData() {
    NSApp.squirrelAppDelegate.syncUserData()
  }

  @objc func openLogFolder() {
    NSApp.squirrelAppDelegate.openLogFolder()
  }

  /// 打开图形化设置窗口（TriFectaSettings.app，安装在输入法包 Contents/MacOS 内）；
  /// 未安装时回退为打开 Rime 配置文件夹，保证手改 YAML 路径始终可用。
  @objc func openSettingsApp() {
    let settingsURL = Bundle.main.bundleURL
      .appendingPathComponent("Contents", isDirectory: true)
      .appendingPathComponent("MacOS", isDirectory: true)
      .appendingPathComponent("TriFectaSettings.app", isDirectory: true)
    if FileManager.default.fileExists(atPath: settingsURL.path) {
      // 设置窗口用 WindowGroup + LSUIElement：窗口关闭后进程常驻，
      // 再次 NSWorkspace.open 只激活旧进程而不重建窗口，导致"保存退出后无法唤起"。
      let settingsBundleID = "im.rime.inputmethod.Squirrel.settings"
      let running = NSRunningApplication.runningApplications(withBundleIdentifier: settingsBundleID)
      for app in running {
        app.terminate()
      }
      if running.isEmpty {
        NSWorkspace.shared.open(settingsURL)
      } else {
        DispatchQueue.global(qos: .userInitiated).async {
          let deadline = Date().addingTimeInterval(3)
          while Date() < deadline && !running.allSatisfy({ $0.isTerminated }) {
            usleep(80_000)
          }
          for app in running where !app.isTerminated {
            app.forceTerminate()
          }
          DispatchQueue.main.async {
            NSWorkspace.shared.open(settingsURL)
          }
        }
      }
    } else {
      openRimeFolder()
    }
  }

  @objc func openRimeFolder() {
    NSApp.squirrelAppDelegate.openRimeFolder()
  }

  @objc func checkForUpdates() {
    NSApp.squirrelAppDelegate.checkForUpdates()
  }

  @objc func openWiki() {
    NSApp.squirrelAppDelegate.openWiki()
  }

  private(set) var specialCommentIndices: [ReservedPropertyKey: Set<Int>] = [:]

  func handleReservedProperty(key rawKey: String, value rawValue: String, for sessionId: RimeSessionId) throws(ReservedPropertyError) {
    guard session == sessionId, session != 0, rimeAPI.find_session(session) else { return }
    guard let key = ReservedPropertyKey(rawValue: rawKey) else { throw .unknownInput(rawKey) }
    let parsed = try ReservedPropertyValue.parse(rawValue)
    switch key {
    case .commentHighlight:
      specialCommentIndices[.commentHighlight] = try parsed.indices()
    case .commentWarning:
      specialCommentIndices[.commentWarning] = try parsed.indices()
    case .refreshUI:
      rimeUpdate(clearReservedComments: false)
    }
  }

  deinit {
    destroySession()
  }
}

private extension SquirrelInputController {

  func onChordTimer(_: Timer) {
    var processedKeys = false
    if chordKeyCount > 0 && session != 0 {
      // Chord typing releases are synthesized after the configured timeout.
      for i in 0..<chordKeyCount {
        let handled = rimeAPI.process_key(session, Int32(chordKeyCodes[i]), Int32(chordModifiers[i] | kReleaseMask.rawValue))
        if handled {
          processedKeys = true
        }
      }
    }
    clearChord()
    if processedKeys {
      rimeUpdate()
    }
  }

  func updateChord(keycode: UInt32, modifiers: UInt32) {
    for i in 0..<chordKeyCount where chordKeyCodes[i] == keycode {
      return
    }
    if chordKeyCount >= Self.keyRollOver {
      return
    }
    chordKeyCodes[chordKeyCount] = keycode
    chordModifiers[chordKeyCount] = modifiers
    chordKeyCount += 1
    if let timer = chordTimer, timer.isValid {
      timer.invalidate()
    }
    chordDuration = 0.1
    if let duration = NSApp.squirrelAppDelegate.config?.getDouble("chord_duration"), duration > 0 {
      chordDuration = duration
    }
    chordTimer = Timer.scheduledTimer(withTimeInterval: chordDuration, repeats: false, block: onChordTimer)
  }

  func clearChord() {
    chordKeyCount = 0
    if let timer = chordTimer {
      if timer.isValid {
        timer.invalidate()
      }
      chordTimer = nil
    }
  }

  func createSession() {
    let app = client?.bundleIdentifier() ?? {
      SquirrelInputController.unknownAppCnt &+= 1
      return "UnknownApp\(SquirrelInputController.unknownAppCnt)"
    }()
    print("createSession: \(app)")
    currentApp = app
    session = rimeAPI.create_session()
    schemaId = ""

    if session != 0 {
      updateAppOptions()
    }
  }

  func updateAppOptions() {
    if currentApp == "" {
      return
    }
    if let appOptions = NSApp.squirrelAppDelegate.config?.getAppOptions(currentApp) {
      for (key, value) in appOptions {
        print("set app option: \(key) = \(value)")
        rimeAPI.set_option(session, key, value)
      }
    }
    if let reportBundleID = NSApp.squirrelAppDelegate.config?.getBool("unsafe/report_bundleid"), reportBundleID {
      currentApp.withCString { name in
        rimeAPI.set_property(session, "client_app", name)
      }
    }
  }

  func destroySession() {
    if session != 0 {
      _ = rimeAPI.destroy_session(session)
      session = 0
    }
    clearChord()
  }

  func processKey(_ rimeKeycode: UInt32, modifiers rimeModifiers: UInt32) -> Bool {
    if let panel = NSApp.squirrelAppDelegate.panel {
      if panel.linear != rimeAPI.get_option(session, "_linear") {
        rimeAPI.set_option(session, "_linear", panel.linear)
      }
      if panel.vertical != rimeAPI.get_option(session, "_vertical") {
        rimeAPI.set_option(session, "_vertical", panel.vertical)
      }
    }

    let handled = rimeAPI.process_key(session, Int32(rimeKeycode), Int32(rimeModifiers))

    if !handled {
      let isVimBackInCommandMode = rimeKeycode == XK_Escape || ((rimeModifiers & kControlMask.rawValue != 0) && (rimeKeycode == XK_c || rimeKeycode == XK_C || rimeKeycode == XK_bracketleft))
      if isVimBackInCommandMode && rimeAPI.get_option(session, "vim_mode") &&
          !rimeAPI.get_option(session, "ascii_mode") {
        rimeAPI.set_option(session, "ascii_mode", true)
      }
    } else {
      let isChordingKey = switch Int32(rimeKeycode) {
      case XK_space...XK_asciitilde, XK_Control_L, XK_Control_R, XK_Alt_L, XK_Alt_R, XK_Shift_L, XK_Shift_R:
        true
      default:
        false
      }
      if isChordingKey && rimeAPI.get_option(session, "_chord_typing") {
        updateChord(keycode: rimeKeycode, modifiers: rimeModifiers)
      } else if (rimeModifiers & kReleaseMask.rawValue) == 0 {
        clearChord()
      }
    }

    return handled
  }

  func rimeConsumeCommittedText() {
    var commitText = RimeCommit.rimeStructInit()
    if rimeAPI.get_commit(session, &commitText) {
      if let text = commitText.text {
        commit(string: String(cString: text))
      }
      _ = rimeAPI.free_commit(&commitText)
    }
  }

  // Preserve reserved comment marks when librime requests a UI-only refresh.
  func rimeUpdate(clearReservedComments: Bool = true) {
    // 组合结束后复位 `~` 递进选字状态（不再依赖 keyUp）
    if NSApp.squirrelAppDelegate.panel?.candidateCount == 0 {
      tildeDown = false
      tildeGroup = nil
      sliderGroupIndex = 0   // 滑块模式：拼音清空时滑块回到初始组
      NSApp.squirrelAppDelegate.panel?.setGroupMode(false)
    }
    if clearReservedComments {
      specialCommentIndices = [:]
    }
    rimeConsumeCommittedText()

    var status = RimeStatus_stdbool.rimeStructInit()
    if rimeAPI.get_status(session, &status) {
      // swiftlint:disable:next identifier_name
      if let schema_id = status.schema_id, schemaId == "" || schemaId != String(cString: schema_id) {
        schemaId = String(cString: schema_id)
        NSApp.squirrelAppDelegate.loadSettings(for: schemaId)
        if let panel = NSApp.squirrelAppDelegate.panel {
          inlinePreedit = (panel.inlinePreedit && !rimeAPI.get_option(session, "no_inline")) || rimeAPI.get_option(session, "inline")
          inlineCandidate = panel.inlineCandidate && !rimeAPI.get_option(session, "no_inline")
          rimeAPI.set_option(session, "soft_cursor", !inlinePreedit)
        }
      }
      _ = rimeAPI.free_status(&status)
    }

    var ctx = RimeContext_stdbool.rimeStructInit()
    if rimeAPI.get_context(session, &ctx) {
      let preedit = ctx.composition.preedit.map({ String(cString: $0) }) ?? ""

      let start = String.Index(preedit.utf8.index(preedit.utf8.startIndex, offsetBy: Int(ctx.composition.sel_start)), within: preedit) ?? preedit.startIndex
      let end = String.Index(preedit.utf8.index(preedit.utf8.startIndex, offsetBy: Int(ctx.composition.sel_end)), within: preedit) ?? preedit.startIndex
      let caretPos = String.Index(preedit.utf8.index(preedit.utf8.startIndex, offsetBy: Int(ctx.composition.cursor_pos)), within: preedit) ?? preedit.startIndex

      if inlineCandidate {
        var candidatePreview = ctx.commit_text_preview.map { String(cString: $0) } ?? ""
        let endOfCandidatePreview = candidatePreview.endIndex
        if inlinePreedit {
          // 左移光標後的情形：
          // preedit:             ^已選某些字[xiang zuo yi dong]|guangbiao$
          // commit_text_preview: ^已選某些字向左移動$
          // candidate_preview:   ^已選某些字[向左移動]|guangbiao$
          // 繼續翻頁至指定更短字詞的情形：
          // preedit:             ^已選某些字[xiang zuo]yidong|guangbiao$
          // commit_text_preview: ^已選某些字向左yidong$
          // candidate_preview:   ^已選某些字[向左]yidong|guangbiao$
          // 光標移至當前段落最左端的情形：
          // preedit:             ^已選某些字|[xiang zuo yi dong guang biao]$
          // commit_text_preview: ^已選某些字向左移動光標$
          // candidate_preview:   ^已選某些字|[向左移動光標]$
          // 討論：
          // preedit 與 commit_text_preview 中“已選某些字”部分一致
          // 因此，選中範圍即正在翻譯的碼段“向左移動”中，兩者的 start 值一致
          // 光標位置的範圍是 start ..= endOfCandidatePreview
          if caretPos >= end && caretPos < preedit.endIndex {
            // 從 preedit 截取光標後未翻譯的編碼“guangbiao”
            candidatePreview += preedit[caretPos...]
          }
        } else {
          // 翻頁至指定更短字詞的情形：
          // preedit:             ^已選某些字[xiang zuo]yidong|guangbiao$
          // commit_text_preview: ^已選某些字向左yidongguangbiao$
          // candidate_preview:   ^已選某些字[向左???]|$
          // 光標移至當前段落最左端，繼續翻頁至指定更短字詞的情形：
          // preedit:             ^已選某些字|[xiang zuo]yidongguangbiao$
          // commit_text_preview: ^已選某些字向左yidongguangbiao$
          // candidate_preview:   ^已選某些字|[向左]???$
          // FIXME: add librime APIs to support preview candidate without remaining code.
        }
        // preedit can contain additional prompt text before start:
        // ^(prompt)[selection]$
        let start = min(start, candidatePreview.endIndex)
        let caretPos = caretPos <= start ? caretPos : endOfCandidatePreview
        show(preedit: candidatePreview,
             selRange: NSRange(location: start.utf16Offset(in: candidatePreview),
                               length: candidatePreview.utf16.distance(from: start, to: candidatePreview.endIndex)),
             caretPos: caretPos.utf16Offset(in: candidatePreview))
      } else {
        if inlinePreedit {
          show(preedit: preedit, selRange: NSRange(location: start.utf16Offset(in: preedit), length: preedit.utf16.distance(from: start, to: end)), caretPos: caretPos.utf16Offset(in: preedit))
        } else {
          // Use a full-width space placeholder to prevent iTerm2 from echoing raw preedit;
          // half-width placeholders make the Chinese composition baseline unstable.
          show(preedit: preedit.isEmpty ? "" : "　", selRange: NSRange(location: 0, length: 0), caretPos: 0)
        }
      }

      let numCandidates = Int(ctx.menu.num_candidates)
      var candidates = [String]()
      var comments = [String]()
      for i in 0..<numCandidates {
        let candidate = ctx.menu.candidates[i]
        candidates.append(candidate.text.map { String(cString: $0) } ?? "")
        comments.append(candidate.comment.map { String(cString: $0) } ?? "")
      }
      var labels = [String]()
      // swiftlint:disable identifier_name
      if let select_keys = ctx.menu.select_keys {
        labels = String(cString: select_keys).map { String($0) }
      } else if let select_labels = ctx.select_labels {
        let pageSize = Int(ctx.menu.page_size)
        for i in 0..<pageSize {
          labels.append(select_labels[i].map { String(cString: $0) } ?? "")
        }
      }
      // swiftlint:enable identifier_name
      let page = Int(ctx.menu.page_no)
      let lastPage = ctx.menu.is_last_page

      let selRange = NSRange(location: start.utf16Offset(in: preedit), length: preedit.utf16.distance(from: start, to: end))
      showPanel(preedit: inlinePreedit ? "" : preedit, selRange: selRange, caretPos: caretPos.utf16Offset(in: preedit),
                candidates: candidates, comments: comments, labels: labels, highlighted: Int(ctx.menu.highlighted_candidate_index),
                page: page, lastPage: lastPage)
      _ = rimeAPI.free_context(&ctx)
    } else {
      hidePalettes()
    }
  }

  func commit(string: String) {
    guard let client = client else { return }

    let forceMarkedText =
      session != 0 &&
      rimeAPI.get_option(session, "force_marked_text_for_direct_commit")

    // Direct commits such as full-width punctuation do not necessarily have an
    // active marked-text phase. Some NSTextInputClient implementations require
    // one before accepting insertText.
    if forceMarkedText && preedit.isEmpty && !string.isEmpty {
      let markedText = NSMutableAttributedString(string: string)
      client.setMarkedText(
        markedText,
        selectionRange: NSRange(location: markedText.length, length: 0),
        replacementRange: .empty
      )
    }

    client.insertText(string, replacementRange: .empty)
    preedit = ""
    hidePalettes()
  }

  func show(preedit: String, selRange: NSRange, caretPos: Int) {
    guard let client = client else { return }
    if self.preedit == preedit && self.caretPos == caretPos && self.selRange == selRange {
      return
    }

    self.preedit = preedit
    self.caretPos = caretPos
    self.selRange = selRange

    let start = selRange.location
    let attrString = NSMutableAttributedString(string: preedit)
    if start > 0 {
      let attrs = mark(forStyle: kTSMHiliteConvertedText, at: NSRange(location: 0, length: start))! as! [NSAttributedString.Key: Any]
      attrString.setAttributes(attrs, range: NSRange(location: 0, length: start))
    }
    let remainingRange = NSRange(location: start, length: preedit.utf16.count - start)
    let attrs = mark(forStyle: kTSMHiliteSelectedRawText, at: remainingRange)! as! [NSAttributedString.Key: Any]
    attrString.setAttributes(attrs, range: remainingRange)
    client.setMarkedText(attrString, selectionRange: NSRange(location: caretPos, length: 0), replacementRange: .empty)
  }

  // swiftlint:disable:next function_parameter_count
  func showPanel(preedit: String, selRange: NSRange, caretPos: Int, candidates: [String], comments: [String], labels: [String], highlighted: Int, page: Int, lastPage: Bool) {
    guard let client = client else { return }
    var inputPos = NSRect()
    client.attributes(forCharacterIndex: 0, lineHeightRectangle: &inputPos)
    if let panel = NSApp.squirrelAppDelegate.panel {
      panel.position = inputPos
      panel.inputController = self
      panel.update(preedit: preedit, selRange: selRange, caretPos: caretPos, candidates: candidates, comments: comments, labels: labels,
                   highlighted: highlighted, page: page, lastPage: lastPage, update: true)
    }
  }

  private func handleASCIIModeToggle(_ notification: Notification) {
    guard let enableASCII = notification.object as? Bool else { return }
    guard session != 0 && rimeAPI.find_session(session) else { return }

    rimeAPI.set_option(session, "ascii_mode", enableASCII)
    rimeUpdate()
  }

  private func reportASCIIMode(_: Notification) {
    guard client != nil else { return }
    guard session != 0 && rimeAPI.find_session(session) else { return }

    let isASCIIMode = rimeAPI.get_option(session, "ascii_mode")
    let status = isASCIIMode ? "ascii" : "nascii"

    DistributedNotificationCenter.default().postNotificationName(
      .init("SquirrelASCIIModeResponse"),
      object: status
    )
  }

}
