---@generic T : any
---@alias pick_one_fn fun(items: T[], prompt: string, label_fn: fun(item: T): string): T|nil

---@generic T : any
---@alias lbl_fn fun(item: T): string
---@alias on_pick_fn fun(item: T, index?: number): nil
---@alias pick_one_async_fn fun(items: T[], prompt: string, label_fn: lbl_fn, on_select: on_pick_fn): nil

---@generic T : any
---@alias pick_many_fn fun(items: T[], prompt: string, label_fn: fun(item: T): string, opts: {is_selected: fun(item: T): boolean}): T[]

---@class JdtUiOpts
---@field pick_one pick_one_fn
---@field pick_one_async pick_one_async_fn
---@field pick_many pick_many_fn
local M = {}

local opts = require("jdtls.setup").opts.ui or {}

---@type pick_one_async_fn
function M.pick_one_async(items, prompt, label_fn, cb)
  if vim.ui then
    return vim.ui.select(items, {
      prompt = prompt,
      format_item = label_fn,
    }, cb)
  end
  local result = M.pick_one(items, prompt, label_fn)
  cb(result)
end

---@generic T
---@param items T[]
---@param prompt string
---@param label_fn fun(item: T): string
---@result T|nil
function M.pick_one(items, prompt, label_fn)
  local choices = { prompt }
  for i, item in ipairs(items) do
    table.insert(choices, string.format("%d: %s", i, label_fn(item)))
  end
  local choice = vim.fn.inputlist(choices)
  if choice < 1 or choice > #items then
    return nil
  end
  return items[choice]
end

local function index_of(xs, term)
  for i, x in pairs(xs) do
    if x == term then
      return i
    end
  end
  return -1
end

---@param index integer
---@param choices string[]
---@param items table[]
---@param selected table[]
local function mark_selected(index, choices, items, selected)
  local choice = choices[index]
  local item = items[index]
  if string.find(choice, "*") == nil then
    table.insert(selected, item)
    choices[index] = choice .. " *"
  else
    choices[index] = string.gsub(choice, " %*$", "")
    local idx = index_of(selected, item)
    table.remove(selected, idx)
  end
end

function M.pick_many(items, prompt, label_f, opts)
  if not items or #items == 0 then
    return {}
  end

  label_f = label_f or function(item)
    return item
  end
  opts = opts or {}

  local choices = {}
  local selected = {}
  local is_selected = opts.is_selected or function(_)
    return false
  end
  for i, item in pairs(items) do
    local label = label_f(item)
    local choice = string.format("%d. %s", i, label)
    if is_selected(item) then
      choice = choice .. " *"
      table.insert(selected, item)
    end
    table.insert(choices, choice)
  end

  while true do
    local answer = vim.fn.input(string.format("\n%s\n%s (Esc to finish): ", table.concat(choices, "\n"), prompt))
    if answer == "" then
      break
    end
    local range_start, range_end = answer:match("(%d+)%s*%-%s*(%d*)")
    if range_start then
      range_start = math.max(1, tonumber(range_start))
      range_end = math.min(#items, tonumber(range_end) or #items)

      if range_start > range_end then
        range_start, range_end = range_end, range_start
      end

      for i = range_start, range_end do
        mark_selected(i, choices, items, selected)
      end
    else
      local idx = tonumber(answer)
      if idx then
        mark_selected(idx, choices, items, selected)
      end
    end
  end
  return selected
end

vim.tbl_extend("force", M, opts)

return M
