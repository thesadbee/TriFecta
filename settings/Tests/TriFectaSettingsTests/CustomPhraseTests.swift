//
//  CustomPhraseTests.swift
//  TriFectaSettingsTests
//

import XCTest
@testable import TriFectaSettingsCore

final class CustomPhraseTests: XCTestCase {
  func testParseSkipsCommentsAndBlankLines() {
    let text = """
    # 表头注释
    你好\tni hao\t2
    \t
    薄荷输入法\tbo he shu ru fa\t1
    """
    let phrases = CustomPhraseStore.parse(text)
    XCTAssertEqual(phrases.count, 2)
    XCTAssertEqual(phrases[0].word, "你好")
    XCTAssertEqual(phrases[0].code, "ni hao")
    XCTAssertEqual(phrases[0].weight, 2)
    XCTAssertEqual(phrases[1].word, "薄荷输入法")
  }

  func testParseToleratesMissingOrBadWeight() {
    let text = """
    只有两列\tzhi you liang lie
    权重非法\tshe zhi fei fa\tabc
    """
    let phrases = CustomPhraseStore.parse(text)
    XCTAssertEqual(phrases.count, 2)
    XCTAssertEqual(phrases[0].weight, 1)      // 缺权重默认 1
    XCTAssertEqual(phrases[1].weight, 1)      // 非数字也回退 1
  }

  func testSerializeRoundTrip() {
    let original = [
      CustomPhrase(word: "你好", code: "ni hao", weight: 2),
      CustomPhrase(word: "张三丰", code: "zhang san feng", weight: 1.5),
    ]
    let text = CustomPhraseStore.serialize(original)
    XCTAssertTrue(text.hasPrefix("#"), "应包含表头注释")
    let parsed = CustomPhraseStore.parse(text)
    XCTAssertEqual(parsed.count, 2)
    XCTAssertEqual(parsed[0].word, "你好")
    XCTAssertEqual(parsed[0].weight, 2)
    XCTAssertEqual(parsed[1].weight, 1.5)
  }

  func testSerializeSkipsInvalidEntries() {
    let phrases = [
      CustomPhrase(word: "有效", code: "you xiao", weight: 1),
      CustomPhrase(word: "", code: "kong", weight: 1),      // 无词条 → 跳过
      CustomPhrase(word: "无拼音", code: "", weight: 1),      // 无拼音 → 跳过
    ]
    let parsed = CustomPhraseStore.parse(CustomPhraseStore.serialize(phrases))
    XCTAssertEqual(parsed.count, 1)
    XCTAssertEqual(parsed[0].word, "有效")
  }

  func testSaveAndLoadInTemporaryDirectory() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("TriFectaCustomPhraseTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }

    let phrases = [CustomPhrase(word: "测试", code: "ce shi", weight: 3)]
    let url = try CustomPhraseStore.save(phrases, to: dir)
    XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    XCTAssertEqual(url.lastPathComponent, "custom_phrase.txt")

    let loaded = CustomPhraseStore.load(from: dir)
    XCTAssertEqual(loaded.count, 1)
    XCTAssertEqual(loaded[0].word, "测试")
    XCTAssertEqual(loaded[0].weight, 3)
  }

  func testResetUserDictRemovesDirectory() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("TriFectaCustomPhraseReset-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let dbURL = CustomPhraseStore.userDictURL(in: dir)
    try FileManager.default.createDirectory(at: dbURL, withIntermediateDirectories: true)
    XCTAssertTrue(FileManager.default.fileExists(atPath: dbURL.path))

    CustomPhraseStore.resetUserDict(in: dir)
    XCTAssertFalse(FileManager.default.fileExists(atPath: dbURL.path), "短语用户词典应被清理")
  }

  func testLoadMissingFileReturnsEmpty() {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("TriFectaCustomPhraseMissing-\(UUID().uuidString)")
    XCTAssertTrue(CustomPhraseStore.load(from: dir).isEmpty)
  }
}
