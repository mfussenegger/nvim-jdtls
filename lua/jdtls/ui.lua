local M = {}


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
  local choices = {prompt}
  for i, item in ipairs(items) do
    table.insert(choices, string.format('%d: %s', i, label_fn(item)))
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

    local index = tonumber(answer)
    if index ~= nil then
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
  end
  return selected
end


return M
