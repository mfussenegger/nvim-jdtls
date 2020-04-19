local api = vim.api
local diagnostics_by_buf = {}
local ui = require('jdtls.ui')
local M = {}


local function java_apply_workspace_edit(command)
  for _, argument in ipairs(command.arguments) do
    vim.lsp.util.apply_workspace_edit(argument)
  end
end


local function java_generate_to_string_prompt(_, params)
  vim.lsp.buf_request(0, 'java/checkToStringStatus', params, function(err, _, result)
    if err then
      print("Could not execute java/checkToStringStatus: " .. err.message)
    end
    if not result then return end
    if result.exists then
      local choice = vim.fn.inputlist({
        string.format("Method 'toString()' already exists in '%s'. Do you want to replace it?", result.type),
        "1. Replace",
        "2. Cancel"
      })
      if choice < 1 or choice == 2 then
        return
      end
    end
    local fields = ui.pick_many(result.fields, 'Include item in toString?', function(x)
      return string.format('%s: %s', x.name, x.type)
    end)
    vim.lsp.buf_request(0, 'java/generateToString', { context = params; fields = fields; }, function(e, _, edit)
      if e then
        print("Could not execute java/generateToString: " .. e.message)
      end
      if edit then
        vim.lsp.util.apply_workspace_edit(edit)
      end
    end)
  end)
end


local function java_hash_code_equals_prompt(_, params)
  vim.lsp.buf_request(0, 'java/checkHashCodeEqualsStatus', params, function(_, _, result)
    if not result or not result.fields or #result.fields == 0 then
      print(string.format("The operation is not applicable to the type %", result.type))
      return
    end
    local fields = ui.pick_many(result.fields, 'Include item in equals/hashCode?', function(x)
      return string.format('%s: %s', x.name, x.type)
    end)
    vim.lsp.buf_request(0, 'java/generateHashCodeEquals', { context = params; fields = fields; }, function(e, _, edit)
      if e then
        print("Could not execute java/generateHashCodeEquals: " .. e.message)
      end
      if edit then
        vim.lsp.util.apply_workspace_edit(edit)
      end
    end)
  end)
end


M.commands = {
  ['java.apply.workspaceEdit'] = java_apply_workspace_edit;
  ['java.action.generateToStringPrompt'] = java_generate_to_string_prompt;
  ['java.action.hashCodeEqualsPrompt'] = java_hash_code_equals_prompt;
}


-- Not needed anymore after https://github.com/neovim/neovim/pull/11607
function M.workspace_apply_edit(err, _, result)
  -- result:
  --   label?: string;
  --   edit: WorkspaceEdit;
  --
  if err then
    print("Received error for workspace/applyEdit: " .. err.message)
  end
  local status, failure = pcall(vim.lsp.util.apply_workspace_edit, result.edit)
  return {
    applied = status;
    failureReason = failure;
  }
end


function M.save_diagnostics(bufnr, diagnostics)
  if not diagnostics then return end
  if not diagnostics_by_buf[bufnr] then
    api.nvim_buf_attach(bufnr, false, {
      on_detach = function(b) diagnostics_by_buf[b] = nil end
    })
  end
  diagnostics_by_buf[bufnr] = diagnostics
end


local function get_diagnostics_for_line(bufnr, linenr)
  local diagnostics = diagnostics_by_buf[bufnr]
  if not diagnostics then return {} end
  local line_diagnostics = {}
  for _, diagnostic in ipairs(diagnostics) do
    if diagnostic.range.start.line == linenr then
      table.insert(line_diagnostics, diagnostic)
    end
  end
  if #line_diagnostics >= 1 then
    return line_diagnostics[1]
  end
  return {}
end


local function make_code_action_params()
  local params = vim.lsp.util.make_position_params()
  local row, pos = unpack(api.nvim_win_get_cursor(0))
  params.range = {
    ["start"] = { line = row - 1; character = pos };
    ["end"] = { line = row - 1; character = pos };
  }
  local bufnr = api.nvim_get_current_buf()
  params.context = {
    diagnostics = get_diagnostics_for_line(bufnr, row - 1)
  }
  return params
end

-- Similar to https://github.com/neovim/neovim/pull/11607, but with extensible commands
function M.code_action()
  local code_action_params = make_code_action_params()
  vim.lsp.buf_request(0, 'textDocument/codeAction', code_action_params, function(err, _, actions)
    if err then return end
    -- actions is (Command | CodeAction)[] | null
    -- CodeAction
    --      title: String
    --      kind?: CodeActionKind
    --      diagnostics?: Diagnostic[]
    --      isPreferred?: boolean
    --      edit?: WorkspaceEdit
    --      command?: Command
    --
    -- Command
    --      title: String
    --      command: String
    --      arguments?: any[]
    if not actions or #actions == 0 then
      print("No code actions available")
      return
    end
    local action = ui.pick_one(actions, 'Code Actions:', function(x)
      return (x.title:gsub('\r\n', '\\r\\n')):gsub('\n', '\\n')
    end)
    if not action then
      return
    end
    if action.edit then
      vim.lsp.util.apply_workspace_edit(action.edit)
      return
    end
    local command
    if type(action.command) == "table" then
      command = action.command
    else
      command = action
    end
    local fn = M.commands[command.command]
    if fn then
      fn(command, code_action_params)
    else
      M.execute_command(command)
    end
  end)
end


-- Until https://github.com/neovim/neovim/pull/11607 is merged
function M.execute_command(command)
  vim.lsp.buf_request(0, 'workspace/executeCommand', command, function(err, _, _)
    if err then
      print("Could not execute code action: " .. err.message)
    end
  end)
end


function M.organize_imports()
  M.execute_command({
    command = "java.edit.organizeImports";
    arguments = { vim.uri_from_bufnr(0) }
  })
end


local function is_jdt_link_location(location)
  return location and (location.uri and location.uri:sub(1, 6) == "jdt://")
end


local function jump_to_buf(buf, range)
  vim.api.nvim_set_current_buf(buf)
  local row = range.start.line
  local col = range.start.character
  local line = vim.api.nvim_buf_get_lines(0, row, row + 1, true)[1]
  col = vim.str_byteindex(line, col)
  vim.api.nvim_win_set_cursor(0, { row + 1, col })
end


local function open_jdt_link(uri, range)
  local bufnr = api.nvim_get_current_buf()
  local params = {
    uri = uri
  }
  vim.lsp.buf_request(bufnr, 'java/classFileContents', params, function(err, _, content)
    if err then return end
    local buf = api.nvim_create_buf(false, true)
    api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(content, '\n', true))
    api.nvim_buf_set_option(buf, 'filetype', 'java')
    jump_to_buf(buf, range)
  end)
end


function M.location_callback(autojump)
  return function(_, _, result)
    if result == nil or #result == 0 then
      return nil
    end
    if not autojump or #result > 1 then
      vim.fn.setqflist({}, ' ', {
        title = 'Language Server';
        items = vim.lsp.util.locations_to_items(
          vim.tbl_filter(
            function(loc) return not is_jdt_link_location(loc) end,
            result
          )
        )
      })
      api.nvim_command("copen")
      api.nvim_command("wincmd p")
    elseif result[1].uri ~= nil then
      vim.cmd "normal! m'" -- save position in jumplist
      local location = result[1]
      if is_jdt_link_location(location) then
        open_jdt_link(location.uri, location.range)
      else
        jump_to_buf(vim.uri_to_bufnr(location.uri), location.range)
      end
    end
  end
end


return M
