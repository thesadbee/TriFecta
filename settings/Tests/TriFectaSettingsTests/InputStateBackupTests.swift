//
//  InputStateBackupTests.swift
//  TriFectaSettingsTests
//

import XCTest
@testable import TriFectaSettingsCore

final class InputStateBackupTests: XCTestCase {
  private func makeUserDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("TriFectaBackupTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  /// 造一个假的用户词典目录 + 自定义短语文件
  private func seedState(in dir: URL) throws {
    let db = dir.appendingPathComponent("luna_pinyin.userdb")
    try FileManager.default.createDirectory(at: db, withIntermediateDirectories: true)
    try Data("dummy".utf8).write(to: db.appendingPathComponent("000001.ldb"))
    try Data("CURRENT".utf8).write(to: db.appendingPathComponent("CURRENT"))

    let phrases = [CustomPhrase(word: "张三丰", code: "zhang san feng", weight: 2)]
    try CustomPhraseStore.save(phrases, to: dir)
  }

  func testCollectItemsFindsUserdbAndPhraseFile() throws {
    let dir = try makeUserDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    try seedState(in: dir)

    let items = InputStateBackup.collectItems(in: dir)
    XCTAssertTrue(items.contains("luna_pinyin.userdb"))
    XCTAssertTrue(items.contains("custom_phrase.txt"))
  }

  func testExportThenRestoreRoundTrip() throws {
    let sourceDir = try makeUserDir()
    let targetDir = try makeUserDir()
    let zipURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("TriFectaBackup-\(UUID().uuidString).zip")
    defer {
      try? FileManager.default.removeItem(at: sourceDir)
      try? FileManager.default.removeItem(at: targetDir)
      try? FileManager.default.removeItem(at: zipURL)
    }
    try seedState(in: sourceDir)

    let exported = try InputStateBackup.export(to: zipURL, userDir: sourceDir)
    XCTAssertTrue(FileManager.default.fileExists(atPath: zipURL.path), "应生成 zip")
    XCTAssertTrue(exported.contains("luna_pinyin.userdb"))
    XCTAssertTrue(exported.contains("custom_phrase.txt"))

    // 还原到空目录
    let restored = try InputStateBackup.restore(from: zipURL, userDir: targetDir)
    XCTAssertTrue(restored.contains("luna_pinyin.userdb"))
    XCTAssertTrue(restored.contains("custom_phrase.txt"))

    let restoredDB = targetDir.appendingPathComponent("luna_pinyin.userdb/000001.ldb")
    XCTAssertTrue(FileManager.default.fileExists(atPath: restoredDB.path), "用户词典文件应被还原")

    let phrases = CustomPhraseStore.load(from: targetDir)
    XCTAssertEqual(phrases.count, 1)
    XCTAssertEqual(phrases[0].word, "张三丰")
  }

  func testExportWithNothingThrows() throws {
    let dir = try makeUserDir()
    let zipURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("TriFectaBackupEmpty-\(UUID().uuidString).zip")
    defer {
      try? FileManager.default.removeItem(at: dir)
      try? FileManager.default.removeItem(at: zipURL)
    }
    XCTAssertThrowsError(try InputStateBackup.export(to: zipURL, userDir: dir)) { error in
      XCTAssertEqual((error as? InputStateBackup.BackupError), .nothingToExport)
    }
  }

  func testRestoreOverwritesExistingUserDict() throws {
    let sourceDir = try makeUserDir()
    let targetDir = try makeUserDir()
    let zipURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("TriFectaBackupOverwrite-\(UUID().uuidString).zip")
    defer {
      try? FileManager.default.removeItem(at: sourceDir)
      try? FileManager.default.removeItem(at: targetDir)
      try? FileManager.default.removeItem(at: zipURL)
    }
    try seedState(in: sourceDir)
    _ = try InputStateBackup.export(to: zipURL, userDir: sourceDir)

    // 目标目录里放一个“旧的”用户词典
    let oldDB = targetDir.appendingPathComponent("luna_pinyin.userdb")
    try FileManager.default.createDirectory(at: oldDB, withIntermediateDirectories: true)
    try Data("stale".utf8).write(to: oldDB.appendingPathComponent("stale.ldb"))

    _ = try InputStateBackup.restore(from: zipURL, userDir: targetDir)

    let stale = targetDir.appendingPathComponent("luna_pinyin.userdb/stale.ldb")
    XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path), "旧文件应被替换")
    let fresh = targetDir.appendingPathComponent("luna_pinyin.userdb/000001.ldb")
    XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path), "新文件应就位")
  }
}

extension InputStateBackup.BackupError: Equatable {
  public static func == (lhs: InputStateBackup.BackupError, rhs: InputStateBackup.BackupError) -> Bool {
    switch (lhs, rhs) {
    case (.nothingToExport, .nothingToExport),
         (.archiveFailed, .archiveFailed),
         (.extractFailed, .extractFailed),
         (.nothingToRestore, .nothingToRestore):
      return true
    default:
      return false
    }
  }
}
