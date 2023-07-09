---@mod jdtls.tests Functions which require vscode-java-test


local api = vim.api
local M = {}

--- Generate tests for the current class
function M.generate()
  local bufnr = api.nvim_get_current_buf()
  local win = api.nvim_get_current_win()
  local cursor = api.nvim_win_get_cursor(win) -- (1, 0) indexed
  local lnum = cursor[1]
  local line = api.nvim_buf_get_lines(bufnr, lnum -1, lnum, true)[1]
  local byteoffset = vim.fn.line2byte(lnum) + vim.str_byteindex(line, cursor[2], true)
  local command = {
    title = "Generate tests",
    command = "vscode.java.test.generateTests",
    arguments = {vim.uri_from_bufnr(bufnr), byteoffset},
  }
  ---@param result? lsp.WorkspaceEdit
  local on_result = function(err, result)
    assert(not err, err)
    if not result then
      return
    end
    vim.lsp.util.apply_workspace_edit(result, "utf-16")

    if not api.nvim_win_is_valid(win) or api.nvim_win_get_buf(win) ~= bufnr then
      return
    end

    -- Set buffer of window to first created/changed file
    local uri = next(result.changes or {})
    if uri then
      local changed_buf = vim.uri_to_bufnr(uri)
      api.nvim_win_set_buf(win, changed_buf)
    else
      -- documentChanges?: ( TextDocumentEdit[] | (TextDocumentEdit | CreateFile | RenameFile | DeleteFile)[]);
      local changes = result.documentChanges or {}
      local _, change = next(changes)
      ---@diagnostic disable-next-line: undefined-field
      local document = changes.textDocument or change.textDocument
      if change.uri and change.kind ~= "delete" then
        local changed_buf = vim.uri_to_bufnr(change.uri)
        api.nvim_win_set_buf(win, changed_buf)
      elseif document then
        local changed_buf = vim.uri_to_bufnr(document.uri)
        api.nvim_win_set_buf(win, changed_buf)
      end
    end
  end
  require("jdtls.util").execute_command(command, on_result, bufnr)
end


---@private
function M._ask_client_for_choice(prompt, choices, pick_many)
  local label = function(x)
    local description = x.description and (' ' .. x.description) or ''
    return x.label .. description
  end
  local ui = require("jdtls.ui")
  if pick_many then
    local opts = {
      is_selected = function(x) return x.picked end
    }
    local result = ui.pick_many(choices, prompt, label, opts)
    return vim.tbl_map(function(x) return x.value or x.label end, result)
  else
    local co, is_main = coroutine.running()
    local choice
    if co and not is_main then
      ui.pick_one_async(choices, prompt, label, function(result)
        coroutine.resume(co, result)
      end)
      choice = coroutine.yield()
    else
      choice = ui.pick_one(choices, prompt, label)
    end
    return choice and (choice.value or choice.label) or vim.NIL
  end
end


return M
