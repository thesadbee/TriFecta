-- hyphen_priority.lua
-- "-" 键在组字过程中有两种冲突的含义：
--   1) key_binder 把它绑定为翻到候选词上一页（when: has_menu）
--   2) recognizer 的 "hyphenated" 规则把它识别成标识符里的字面连字符（如 "bss-service"）
-- recognizer 在处理器链中排在 key_binder 之前，且它的正则匹配完全不看当前是否已经
-- 有候选词菜单，所以只要正则匹配上就会直接抢占按键。
--
-- 优先级规则：候选词还在第一页时，翻到"上一页"没有意义，所以"-"默认当作字面连字
-- 符，交给 recognizer 处理；一旦已经翻到第二页及以后，说明用户大概率是想翻回上一
-- 页，这时"-"应该优先翻页，而不是被当成连字符吃掉。
--
-- 用法（schema）：engine/processors 里把
--   - lua_processor@*hyphen_priority
-- 加在 recognizer 之前。

local kAccepted = 1
local kNoop = 2

local function page_size(env)
  local n = env.engine.schema.config:get_int("menu/page_size")
  if n == nil or n <= 0 then
    n = 5 -- Rime 默认页面大小
  end
  return n
end

local function hyphen_priority(key_event, env)
  if key_event:release() or key_event:ctrl() or key_event:alt() or key_event:super() then
    return kNoop
  end
  if key_event:repr() ~= "minus" then
    return kNoop
  end
  local ctx = env.engine.context
  if not ctx:is_composing() or not ctx:has_menu() then
    return kNoop
  end
  local seg = ctx.composition:back()
  if seg == nil then
    return kNoop
  end
  local current_page = math.floor(seg.selected_index / page_size(env))
  if current_page == 0 then
    return kNoop -- 第一页：没有上一页可翻，"-" 默认是字面连字符
  end
  env.engine:process_key(KeyEvent("Page_Up"))
  return kAccepted
end

return { func = hyphen_priority }
