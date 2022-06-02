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


function M.pick_many(items, prompt, label_f)
  if not items or #items == 0 then
    return {}
  end

  label_f = label_f or function(item)
    return item
  end

  local choices = {}
  for i, item in pairs(items) do
    table.insert(choices, string.format("%d. %s", i, label_f(item)))
  end

  local selected = {}
  while true do
    local answer = vim.fn.input(string.format("\n%s\n%s (Esc to finish): ", table.concat(choices, "\n"), prompt))
    if answer == "" then
      break
    end

    local index = tonumber(answer)
    if index ~= nil then
      if string.find(choices[index], "*") == nil then
        table.insert(selected, items[index])
        choices[index] = choices[index] .. " *"
      end
    end
  end
  return selected
end


return M
