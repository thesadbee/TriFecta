#!/usr/bin/env python3
"""
生成 Rime 表情字典 data/plum/emoji.dict.yaml。

数据来源：
  1) 中文名拼音：gaboolic/rime-shuangpin-fuzhuma 的 emoji.dict.yaml
     （词条 = emoji，编码 = 中文名拼音，用撇号分音节）
  2) 英文名：iamcal/emoji-data 的 emoji.json（short_names / name）

生成策略：
  - 编码统一小写、撇号转空格、压缩多余空格
  - 中文名编码权重 -5，英文名 -6（负权重让 exp(weight) 很小，emoji 排在中文候选之后）
  - 去重 (emoji, code)
  - 仅保留 emoji 字符开头的条目

用法：
  python3 scripts/gen-emoji-dict.py <gaboolic_emoji.dict.yaml> <emoji_data.json> <输出路径>
"""

import json
import re
import sys


def is_emoji_char(ch: str) -> bool:
    cp = ord(ch)
    return (
        0x1F000 <= cp <= 0x1FAFF
        or 0x2600 <= cp <= 0x27BF
        or 0x2B00 <= cp <= 0x2BFF
        or 0x2190 <= cp <= 0x21FF
        or 0x2300 <= cp <= 0x23FF
        or cp in (0x2764, 0x2B50, 0x2B55, 0x3030, 0x303D, 0x3297, 0x3299, 0x00A9, 0x00AE, 0x2122)
    )


def normalize_code(code: str) -> str:
    code = code.strip().lower().replace("'", " ").replace("\u2019", " ")
    code = re.sub(r"[^a-z0-9 ]+", " ", code)
    return re.sub(r"\s+", " ", code).strip()


def load_chinese_codes(path: str) -> dict:
    """读取 gaboolic 字典 → {emoji: set(codes)}"""
    result = {}
    for line in open(path, encoding="utf-8"):
        if not line.strip() or line.startswith("#") or line.startswith(" ") or "\t" not in line:
            continue
        parts = line.rstrip("\n").split("\t")
        if len(parts) < 2:
            continue
        text, code = parts[0], parts[1]
        if not text or not is_emoji_char(text[0]):
            continue
        code = normalize_code(code)
        if code and re.fullmatch(r"[a-z0-9 ]+", code):
            result.setdefault(text, set()).add(code)
    return result


def emoji_char(unified: str) -> str:
    try:
        return "".join(chr(int(part, 16)) for part in unified.split("-"))
    except ValueError:
        return ""


def load_english_codes(path: str) -> dict:
    """读取 iamcal/emoji-data → {emoji: set(codes)}"""
    data = json.load(open(path, encoding="utf-8"))
    result = {}
    for entry in data:
        ch = emoji_char(entry.get("unified", ""))
        if not ch or not is_emoji_char(ch[0]):
            continue
        codes = set()
        for short in entry.get("short_names", []) or []:
            code = normalize_code(short.replace("_", " "))
            if code and len(code) <= 40:
                codes.add(code)
        name = entry.get("name")
        if name:
            code = normalize_code(name)
            if code and len(code) <= 40:
                codes.add(code)
        if codes:
            result.setdefault(ch, set()).update(codes)
    return result


def main() -> None:
    if len(sys.argv) != 4:
        print(__doc__)
        sys.exit(1)
    zh_path, en_path, out_path = sys.argv[1:4]

    zh = load_chinese_codes(zh_path)
    en = load_english_codes(en_path)

    all_emoji = set(zh) | set(en)
    rows = []
    seen = set()
    for emoji in sorted(all_emoji):
        for code, weight in sorted(
            [(c, -5) for c in zh.get(emoji, set())] + [(c, -6) for c in en.get(emoji, set())]
        ):
            key = (emoji, code)
            if key in seen:
                continue
            seen.add(key)
            rows.append((emoji, code, weight))

    with open(out_path, "w", encoding="utf-8") as f:
        f.write("---\n")
        f.write("name: emoji\n")
        f.write('version: "2026-11-23"\n')
        f.write("sort: by_weight\n")
        f.write("use_preset_vocabulary: false\n")
        f.write("columns:\n")
        f.write("  - text\n")
        f.write("  - code\n")
        f.write("  - weight\n")
        f.write("...\n")
        for emoji, code, weight in rows:
            f.write(f"{emoji}\t{code}\t{weight}\n")

    print(f"emoji 数: {len(all_emoji)}")
    print(f"中文名来源: {len(zh)} 个 emoji")
    print(f"英文名来源: {len(en)} 个 emoji")
    print(f"总编码条数: {len(rows)}")
    print(f"输出: {out_path}")


if __name__ == "__main__":
    main()
