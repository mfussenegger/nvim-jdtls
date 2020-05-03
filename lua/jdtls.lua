local api = vim.api
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


local function get_diagnostics_for_line(bufnr, linenr)
  local diagnostics = vim.lsp.util.diagnostics_by_buf[bufnr]
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
    uri = uri
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


local function start_debug_adapter(callback)
  M.execute_command({command = 'vscode.java.startDebugSession'}, function(err0, port)
    assert(not err0, vim.inspect(err0))

    callback({ type = 'server'; host = '127.0.0.1'; port = port; })
  end)
end


local function run_test_codelens(choose_lens, no_match_msg)
  local status, dap = pcall(require, 'dap')
  if not status then
    print('nvim-dap is not available')
    return
  end
  local uri = vim.uri_from_bufnr(0)
  local cmd_codelens = {
    command = 'vscode.java.test.search.codelens';
    arguments = { uri };
  }
  M.execute_command(cmd_codelens, function(err0, codelens)
    if err0 then
      print('Error fetching codelens: ' .. err0.message)
    end
    local choice = choose_lens(codelens)
    if not choice then
      print(no_match_msg)
      return
    end

    local methodname = ''
    local name_parts = vim.split(choice.fullName, '#')
    local classname = name_parts[1]
    if #name_parts > 1 then
      methodname = name_parts[2]
      if #choice.paramTypes > 0 then
        methodname = string.format('%s(%s)', methodname, table.concat(choice.paramTypes, ','))
      end
    end
    local cmd_junit_args = {
      command = 'vscode.java.test.junit.argument';
      arguments = { vim.fn.json_encode({
        uri = uri;
        classFullName = classname;
        testName = methodname;
        project = choice.project;
        scope = choice.level;
        testKind = choice.kind;
      })};
    }
    M.execute_command(cmd_junit_args, function(err1, launch_args)
      if err1 then
        print('Error retrieving launch arguments: ' .. err1.message)
        return
      end
      start_debug_adapter(function(adapter)
        local args = table.concat(launch_args.programArguments, ' ');
        local config = {
          name = 'Launch Java Test: ' .. choice.fullName;
          type = 'java';
          request = 'launch';
          mainClass = launch_args.mainClass;
          projectName = launch_args.projectName;
          cwd = launch_args.workingDirectory;
          classPaths = launch_args.classpath;
          modulePaths = launch_args.modulepath;
          args = args:gsub('-port ([0-9]+)', '-port ' .. adapter.port);
          vmArgs = table.concat(launch_args.vmArguments, ' ');
          noDebug = false;
        }
        dap.attach(adapter.host, adapter.port, config)
      end)
    end)
  end)
end


function M.test_class()
  local choose_lens = function(codelens)
    for _, lens in pairs(codelens) do
      if lens.level == 3 then
        return lens
      end
    end
  end
  run_test_codelens(choose_lens, 'No test class found')
end


function M.test_nearest_method()
  local lnum = api.nvim_win_get_cursor(0)[1]
  local candidates = {}
  local choose_lens = function(codelens)
    for _, lens in pairs(codelens) do
      if lens.level == 4 and lens.location.range.start.line <= lnum then
        table.insert(candidates, lens)
      end
    end
    if #candidates == 0 then return end
    table.sort(candidates, function(a, b)
      return a.location.range.start.line > b.location.range.start.line
    end)
    return candidates[1]
  end
  run_test_codelens(choose_lens, 'No suitable test method found')
end

local original_configurations = nil

function M.setup_dap()
  local status, dap = pcall(require, 'dap')
  if not status then
    print('nvim-dap is not available')
    return
  end

  dap.adapters.java = start_debug_adapter
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
