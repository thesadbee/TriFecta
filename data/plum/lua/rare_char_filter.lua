-- rare_char_filter.lua
-- 过滤掉「系统字体普遍没有字形」的 CJK 扩展区生僻字候选。
--
-- 背景：简繁转换表（OpenCC TSCharacters）会把一些繁体生僻字转成 Unicode 扩展 C/D/E
-- 区的异体字，例如 餧(U+9927) → 𫗭(U+2B5ED)。macOS 常见字体都没有这些字的字形，
-- 候选框只能显示成「?」，上屏后观感也像乱码。
--
-- 规则：候选文本里只要含有扩展 C/D/E（U+2A700–U+2EBEF）或扩展 F/G/H/I
-- （U+30000–U+323AF）的字符就丢弃。常用汉字（基本区、扩展 A、扩展 B 常用字）不受影响。
--
-- 用法（schema）：engine/filters 里加上
--   - lua_filter@*rare_char_filter
-- 放在 simplifier 之后（过滤转换后的最终字形）。

local kRareMin = 0x2A700
local kRareMax = 0x2EBEF
local kSupMin = 0x30000
local kSupMax = 0x323AF

local function is_rare_codepoint(cp)
  return (cp >= kRareMin and cp <= kRareMax) or (cp >= kSupMin and cp <= kSupMax)
end

local function has_rare_char(text)
  if not text or text == "" then return false end
  for _, cp in utf8.codes(text) do
    if is_rare_codepoint(cp) then return true end
  end
  return false
end

local function filter(input, env)
  for cand in input:iter() do
    if not has_rare_char(cand.text) then
      yield(cand)
    end
  end
end

return filter
