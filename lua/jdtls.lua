local api = vim.api
local uv = vim.loop

local ui = require('jdtls.ui')
local junit = require('jdtls.junit')
local M = {}
local request = vim.lsp.buf_request
M.jol_path = nil


local function java_apply_workspace_edit(command)
  for _, argument in ipairs(command.arguments) do
    vim.lsp.util.apply_workspace_edit(argument)
  end
end


local function java_generate_to_string_prompt(_, params)
  request(0, 'java/checkToStringStatus', params, function(err, _, result)
    if err then
      print("Could not execute java/checkToStringStatus: " .. err.message)
      return
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
    request(0, 'java/generateToString', { context = params; fields = fields; }, function(e, _, edit)
      if e then
        print("Could not execute java/generateToString: " .. e.message)
        return
      end
      if edit then
        vim.lsp.util.apply_workspace_edit(edit)
      end
    end)
  end)
end


local function java_generate_constructors_prompt(_, code_action_params)
  request(0, 'java/checkConstructorsStatus', code_action_params, function(err0, _, status)
    if err0 then
      print("Could not execute java/checkConstructorsStatus: " .. err0.message)
      return
    end
    if not status or not status.constructors or #status.constructors == 0 then
      return
    end
    local constructors = status.constructors
    if #status.constructors > 1 then
      constructors = ui.pick_many(status.constructors, 'Include super class constructor(s): ', function(x)
        return string.format('%s(%s)', x.name, table.concat(x.parameters, ','))
      end)
      if not constructors or #constructors == 0 then
        return
      end
    end

    local fields = status.fields
    if fields then
      fields = ui.pick_many(status.fields, 'Include field to initialize by constructor(s): ', function(x)
        return string.format('%s: %s', x.name, x.type)
      end)
      if not fields or #fields == 0 then
        return
      end
    end

    local params = {
      context = code_action_params,
      constructors = constructors,
      fields = fields
    }
    request(0, 'java/generateConstructors', params, function(err1, _, edit)
      if err1 then
        print("Could not execute java/generateConstructors: " .. err1.message)
      elseif edit then
        vim.lsp.util.apply_workspace_edit(edit)
      end
    end)
  end)
end


local function java_generate_delegate_methods_prompt(_, code_action_params)
  request(0, 'java/checkDelegateMethodsStatus', code_action_params, function(err0, _, status)
    if err0 then
      print('Could not execute java/checkDelegateMethodsStatus: ', err0.message)
      return
    end
    if not status or not status.delegateFields or #status.delegateFields == 0 then
      print('All delegatable methods are already implemented.')
      return
    end

    local field = #status.delegateFields == 1 and status.delegateFields[1] or ui.pick_one(
      status.delegateFields,
      'Select target to generate delegates for.',
      function(x) return string.format('%s: %s', x.field.name, x.field.type) end
    )
    if not field then
      return
    end
    if #field.delegateMethods == 0 then
      print('All delegatable methods are already implemented.')
      return
    end

    local methods = ui.pick_many(field.delegateMethods, 'Generate delegate for method:', function(x)
      return string.format('%s(%s)', x.name, table.concat(x.parameters, ','))
    end)
    if not methods or #methods == 0 then
      return
    end

    local params = {
      context = code_action_params,
      delegateEntries = vim.tbl_map(
        function(x)
          return {
            field = field.field,
            delegateMethod = x
          }
        end,
        methods
      ),
    }
    request(0, 'java/generateDelegateMethods', params, function(err1, _, workspace_edit)
      if err1 then
        print('Could not execute java/generateDelegateMethods', err1.message)
      elseif workspace_edit then
        vim.lsp.util.apply_workspace_edit(workspace_edit)
      end
    end)
  end)
end


local function java_hash_code_equals_prompt(_, params)
  request(0, 'java/checkHashCodeEqualsStatus', params, function(_, _, result)
    if not result or not result.fields or #result.fields == 0 then
      print(string.format("The operation is not applicable to the type %", result.type))
      return
    end
    local fields = ui.pick_many(result.fields, 'Include item in equals/hashCode?', function(x)
      return string.format('%s: %s', x.name, x.type)
    end)
    request(0, 'java/generateHashCodeEquals', { context = params; fields = fields; }, function(e, _, edit)
      if e then
        print("Could not execute java/generateHashCodeEquals: " .. e.message)
      end
      if edit then
        vim.lsp.util.apply_workspace_edit(edit)
      end
    end)
  end)
end


local function handle_refactor_workspace_edit(err, _, result)
  if err then
    print('Error getting refactoring edit: ' .. err.message)
    return
  end
  if not result then
    return
  end

  if result.edit then
    vim.lsp.util.apply_workspace_edit(result.edit)
  end

  if result.command then
    local command = result.command
    local fn = M.commands[command.command]
    if fn then
      fn(command, {})
    else
      M.execute_command(command)
    end
  end
end


local function java_apply_refactoring_command(command, code_action_params)
  local cmd = command.arguments[1]
  local sts = vim.bo.softtabstop;
  local params = {
    command = cmd,
    context = code_action_params,
    options = {
      tabSize = (sts > 0 and sts) or (sts < 0 and vim.bo.shiftwidth) or vim.bo.tabstop;
      insertSpaces = vim.bo.expandtab;
    },
  }
  request(0, 'java/getRefactorEdit', params, handle_refactor_workspace_edit)
end


local function java_action_rename()
  -- Ignored for now
end


local function java_action_organize_imports(_, code_action_params)
  request(0, 'java/organizeImports', code_action_params, function(err, _, resp)
    if err then
      print('Error on organize imports: ' .. err.message)
      return
    end
    if resp then
      vim.lsp.util.apply_workspace_edit(resp)
    end
  end)
end


local function find_last(str, pattern)
  local idx = nil
  while true do
    local i = string.find(str, pattern, (idx or 0) + 1)
    if i == nil then
      break
    else
      idx = i
    end
  end
  return idx
end


local function java_choose_imports(resp)
  local uri = resp[1]
  local selections = resp[2]
  local choices = {}
  for _, selection in ipairs(selections) do
    local start = selection.range.start

    local buf = vim.uri_to_bufnr(uri)
    api.nvim_win_set_buf(0, buf)
    api.nvim_win_set_cursor(0, {start.line + 1, start.character})
    api.nvim_command("redraw")

    local candidates = selection.candidates
    local fqn = candidates[1].fullyQualifiedName
    local type_name = fqn:sub(find_last(fqn, '%.') + 1)
    local choice = #candidates == 1 and candidates[1] or ui.pick_one(
      candidates,
      'Choose type ' .. type_name .. ' to import',
      function(x) return x.fullyQualifiedName end
    )
    table.insert(choices, choice)
  end
  return choices
end


M.commands = {
  ['java.apply.workspaceEdit'] = java_apply_workspace_edit;
  ['java.action.generateToStringPrompt'] = java_generate_to_string_prompt;
  ['java.action.hashCodeEqualsPrompt'] = java_hash_code_equals_prompt;
  ['java.action.applyRefactoringCommand'] = java_apply_refactoring_command;
  ['java.action.rename'] = java_action_rename;
  ['java.action.organizeImports'] = java_action_organize_imports;
  ['java.action.organizeImports.chooseImports'] = java_choose_imports;
  ['java.action.generateConstructorsPrompt'] = java_generate_constructors_prompt;
  ['java.action.generateDelegateMethodsPrompt'] = java_generate_delegate_methods_prompt;
}


if not vim.lsp.callbacks['workspace/executeClientCommand'] then
  vim.lsp.callbacks['workspace/executeClientCommand'] = function(_, _, params)
    local fn = M.commands[params.command]
    if fn then
      local ok, result = pcall(fn, params.arguments)
      if ok then
        return result
      else
        return vim.lsp.rpc_response_error(vim.lsp.protocol.ErrorCodes.InternalError, result)
      end
    else
      return vim.lsp.rpc_response_error(
        vim.lsp.protocol.ErrorCodes.MethodNotFound,
        'Command ' .. params.command .. ' not supported on client'
      )
    end
  end
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


local function make_code_action_params(from_selection, kind)
  local params = {
    textDocument = { uri = vim.uri_from_bufnr(0) },
  }
  if from_selection then
    local start_row, start_col = unpack(api.nvim_buf_get_mark(0, '<'))
    local end_row, end_col = unpack(api.nvim_buf_get_mark(0, '>'))
    start_row = start_row - 1
    end_row = end_row - 1
    start_col = vim.lsp.util.character_offset(0, start_row, start_col)
    end_col = vim.lsp.util.character_offset(0, end_row, end_col)
    -- LSP spec: If you want to specify a range that contains a line including
    -- the line ending character(s) then use an end position denoting the start
    -- of the next line
    local line = api.nvim_buf_get_lines(0, end_row, end_row + 1, true)[1]
    if line and end_col == (#line - 1) then
      end_row = end_row + 1
      end_col = 0
    end
    params.range = {
      ["start"] = { line = start_row, character = start_col };
      ["end"] = { line = end_row, character = end_col };
    }
  else
    local row, pos = unpack(api.nvim_win_get_cursor(0))
    params.range = {
      ["start"] = { line = row - 1; character = pos };
      ["end"] = { line = row - 1; character = pos };
    }
  end
  local bufnr = api.nvim_get_current_buf()
  params.context = {
    diagnostics = get_diagnostics_for_line(bufnr, params.range.start.line),
    only = kind,
  }
  return params
end

-- Similar to https://github.com/neovim/neovim/pull/11607, but with extensible commands
function M.code_action(from_selection, kind)
  local code_action_params = make_code_action_params(from_selection or false, kind)
  request(0, 'textDocument/codeAction', code_action_params, function(err, _, actions)
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
  request(0, 'workspace/executeCommand', command, function(err, _, resp)
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


function M.compile(full_compile)
  local CompileWorkspaceStatus = {
    FAILED = 0,
    SUCCEED = 1,
    WITHERROR = 2,
    CANCELLED = 3,
  }
  request(0, 'java/buildWorkspace', full_compile or false, function(err, _, result)
    if err then
      print('Compile error: ' .. err.message)
      return
    end
    if result ~= CompileWorkspaceStatus.SUCCEED then
      print('Compile error')
    end
  end)
end


function M.update_project_config()
  local params = { uri = vim.uri_from_bufnr(0) }
  request(0, 'java/projectConfigurationUpdate', params, function(err)
    if err then
      print('Could not update project configuration: ' .. err.message)
      return
    end
  end)
end


function M.extract_variable(from_selection)
  local params = make_code_action_params(from_selection or false)
  java_apply_refactoring_command({ arguments = { 'extractVariable' }, }, params)
end


function M.extract_method(from_selection)
  local params = make_code_action_params(from_selection or false)
  java_apply_refactoring_command({ arguments = { 'extractMethod' }, }, params)
end


local function resolve_classname()
  local lines = api.nvim_buf_get_lines(0, 0, -1, true)
  local pkgname
  for _, line in ipairs(lines) do
    local match = line:match('package ([a-z\\.]+);')
    if match then
      pkgname = match
      break
    end
  end
  assert(pkgname, 'Could not find package name for current class')
  local classname = vim.fn.fnamemodify(vim.fn.expand('%'), ':t:r')
  return pkgname .. '.' .. classname
end


local function with_classpaths(fn)
  local options = vim.fn.json_encode({
    scope = 'runtime';
  })
  local cmd = {
    command = 'java.project.getClasspaths';
    arguments = { vim.uri_from_bufnr(0), options };
  }
  M.execute_command(cmd, function(err, resp)
    if err then
      print('Error executing java.project.getClasspaths: ' .. err.message)
    else
      fn(resp)
    end
  end)
end


local function with_java_executable(mainclass, project, fn)
  vim.validate({
    mainclass = { mainclass, 'string' }
  })
  M.execute_command({
    command = 'vscode.java.resolveJavaExecutable',
    arguments = { mainclass, project }
  }, function(err, java_exec)
    if err then
      print('Could not resolve java executable: ' .. err.message)
    else
      fn(java_exec)
    end
  end)
end


function M.javap()
  with_classpaths(function(resp)
    local classname = resolve_classname()
    local cp = table.concat(resp.classpaths, ':')
    local buf = api.nvim_create_buf(false, true)
    api.nvim_win_set_buf(0, buf)
    vim.fn.termopen({'javap', '-c', '--class-path', cp, classname})
  end)
end


function M.jshell()
  with_classpaths(function(result)
    local buf = api.nvim_create_buf(false, true)
    local classpaths = {}
    for _, path in pairs(result.classpaths) do
      if vim.fn.filereadable(path) == 1 or vim.fn.isdirectory(path) == 1 then
        table.insert(classpaths, path)
      end
    end
    local cp = table.concat(classpaths, ':')
    with_java_executable(resolve_classname(), '', function(java_exec)
      api.nvim_win_set_buf(0, buf)
      local jshell = vim.fn.fnamemodify(java_exec, ':h') .. '/jshell'
      vim.fn.termopen({jshell, '--class-path', cp})
    end)
  end)
end


function M.jol(mode, classname)
  mode = mode or 'estimates'
  local jol = assert(M.jol_path, [[Path to jol must be set using `lua require('jdtls').jol_path = 'path/to/jol.jar'`]])
  with_classpaths(function(resp)
    local resolved_classname = resolve_classname()
    local cp = table.concat(resp.classpaths, ':')
    with_java_executable(resolved_classname, '', function(java_exec)
      local buf = api.nvim_create_buf(false, true)
      api.nvim_win_set_buf(0, buf)
      vim.fn.termopen({
        java_exec, '-Djdk.attach.allowAttachSelf', '-jar', jol, mode, '-cp', cp, classname or resolved_classname})
    end)
  end)
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
      return
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
      if choice.paramTypes and #choice.paramTypes > 0 then
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
        print('Error retrieving launch arguments: ' .. (err1.message or vim.inspect(err1)))
        return
      end
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
        args = args;
        vmArgs = table.concat(launch_args.vmArguments, ' ');
        noDebug = false;
      }
      local test_results
      local server = nil
      dap.run(config, {
        before = function(conf)
          server = uv.new_tcp()
          test_results = junit.mk_test_results()
          server:bind('127.0.0.1', 0)
          server:listen(128, function(err2)
            assert(not err2, err2)
            local sock = vim.loop.new_tcp()
            server:accept(sock)
            sock:read_start(test_results.mk_reader(sock))
          end)
          conf.args = conf.args:gsub('-port ([0-9]+)', '-port ' .. server:getsockname().port);
          return conf
        end;
        after = function()
          server:shutdown()
          server:close()
          test_results.show()
        end;
      })
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

      with_java_executable(mainclass, project, function(java_exec)
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


M.extendedClientCapabilities = {
  classFileContentsSupport = true;
  generateToStringPromptSupport = true;
  hashCodeEqualsPromptSupport = true;
  advancedExtractRefactoringSupport = true;
  advancedOrganizeImportsSupport = true;
  generateConstructorsPromptSupport = true;
  generateDelegateMethodsPromptSupport = true;
};


return M
