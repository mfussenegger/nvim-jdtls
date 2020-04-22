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
function M.execute_command(command, callback)
  vim.lsp.buf_request(0, 'workspace/executeCommand', command, function(err, _, resp)
    if callback then
      callback(err, resp)
    elseif err then
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


--- Reads the uri into the current buffer
--
-- This requires at least one open buffer that is connected to the jdtls
-- language server.
--
--@param uri expected to be a `jdt://` uri
function M.open_jdt_link(uri)
  local lspbuf
  for _, buf in pairs(vim.fn.getbufinfo({bufloaded=true})) do
    if api.nvim_buf_get_option(buf.bufnr, 'filetype') == 'java' and #vim.lsp.buf_get_clients(buf.bufnr) > 0 then
      lspbuf = buf.bufnr
      break
    end
  end
  local buf = api.nvim_get_current_buf()
  local params = {
    uri = uri:gsub("([\\<>`])", function(c) return "%" .. string.format("%02x", string.byte(c)) end)
  }
  local responses = vim.lsp.buf_request_sync(lspbuf, 'java/classFileContents', params)
  if not responses or #responses == 0 or not responses[1].result then
    api.nvim_buf_set_lines(buf, 0, -1, false, {"Failed to load contents for uri", params.uri})
  else
    api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(responses[1].result, '\n', true))
  end
  api.nvim_buf_set_option(0, 'filetype', 'java')
  api.nvim_command('setlocal nomodifiable')
end


local original_configurations = nil


function M.setup_dap()
  local status, dap = pcall(require, 'dap')
  if not status then
    print('nvim-dap is not available')
    return
  end

  dap.adapters.java = function(callback)
    M.execute_command({command = 'vscode.java.startDebugSession'}, function(err0, port)
      assert(not err0, vim.inspect(err0))

      callback({ type = 'server'; host = '127.0.0.1'; port = port; })
    end)
  end
  if not original_configurations then
    original_configurations = dap.configurations.java or {}
  end
  local configurations = vim.deepcopy(original_configurations)
  dap.configurations.java = configurations

  M.execute_command({command = 'vscode.java.resolveMainClass'}, function(err0, mainclasses)
    if err0 then
      print('Could not resolve mainclasses: ' .. err0.message)
      return
    end

    for _, mc in pairs(mainclasses) do
      local mainclass = mc.mainClass
      local project = mc.projectName

      M.execute_command({command = 'vscode.java.resolveJavaExecutable', arguments = { mainclass, project }}, function(err1, java_exec)
        if err1 then
          print('Could not resolve java executable: ' .. err1.message)
          return
        end

        M.execute_command({command = 'vscode.java.resolveClasspath', arguments = { mainclass, project }}, function(err2, paths)
          if err2 then
            print(string.format('Could not resolve classpath and modulepath for %s/%s: %s', project, mainclass, err2.message))
            return
          end
          local config = {
            type = 'java';
            name = 'Launch ' .. mainclass;
            projectName = project;
            mainClass = mainclass;
            modulePaths = paths[1];
            classPaths = paths[2];
            javaExec = java_exec;
            request = 'launch';
            console = 'integratedTerminal';
          }
          table.insert(configurations, config)
        end)
      end)
    end
  end)
end


return M
