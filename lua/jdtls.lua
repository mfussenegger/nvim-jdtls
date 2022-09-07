---@mod jdtls LSP extensions for Neovim and eclipse.jdt.ls

local api = vim.api

local ui = require('jdtls.ui')
local util = require('jdtls.util')

local with_java_executable = util.with_java_executable
local with_classpaths = util.with_classpaths
local resolve_classname = util.resolve_classname
local execute_command = util.execute_command

local jdtls_dap = require('jdtls.dap')
local setup = require('jdtls.setup')



local M = {
  setup_dap = jdtls_dap.setup_dap,
  test_class = jdtls_dap.test_class,
  test_nearest_method = jdtls_dap.test_nearest_method,
  pick_test = jdtls_dap.pick_test,
  extendedClientCapabilities = setup.extendedClientCapabilities,
  setup = setup,
  settings = {
    jdt_uri_timeout_ms = 5000,
  }
}

--- Start the language server (if not started), and attach the current buffer.
--- @param config table configuration. See |vim.lsp.start_client|
function M.start_or_attach(config)
  setup.start_or_attach(config)
end


local request = function(bufnr, method, params, handler)
  vim.lsp.buf_request(bufnr, method, params, handler)
end
local highlight_ns = api.nvim_create_namespace('jdtls_hl')
M.jol_path = nil



local function java_apply_workspace_edit(command)
  for _, argument in ipairs(command.arguments) do
    vim.lsp.util.apply_workspace_edit(argument, 'utf-16')
  end
end


local function java_generate_to_string_prompt(_, outer_ctx)
  local params = outer_ctx.params
  request(0, 'java/checkToStringStatus', params, function(err, result, ctx)
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
    request(ctx.bufnr, 'java/generateToString', { context = params; fields = fields; }, function(e, edit)
      if e then
        print("Could not execute java/generateToString: " .. e.message)
        return
      end
      if edit then
        vim.lsp.util.apply_workspace_edit(edit, 'utf-16')
      end
    end)
  end)
end


local function java_generate_constructors_prompt(_, outer_ctx)
  request(0, 'java/checkConstructorsStatus', outer_ctx.params, function(err0, status, ctx)
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
      local opts = {
        is_selected = function(item)
          return item.isSelected
        end
      }
      fields = ui.pick_many(status.fields, 'Include field to initialize by constructor(s): ', function(x)
        return string.format('%s: %s', x.name, x.type)
      end, opts)
    end

    local params = {
      context = outer_ctx.params,
      constructors = constructors,
      fields = fields
    }
    request(ctx.bufnr, 'java/generateConstructors', params, function(err1, edit)
      if err1 then
        print("Could not execute java/generateConstructors: " .. err1.message)
      elseif edit then
        vim.lsp.util.apply_workspace_edit(edit, 'utf-16')
      end
    end)
  end)
end


local function java_generate_delegate_methods_prompt(_, outer_ctx)
  request(0, 'java/checkDelegateMethodsStatus', outer_ctx.params, function(err0, status, ctx)
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
      context = outer_ctx.params,
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
    request(ctx.bufnr, 'java/generateDelegateMethods', params, function(err1, workspace_edit)
      if err1 then
        print('Could not execute java/generateDelegateMethods', err1.message)
      elseif workspace_edit then
        vim.lsp.util.apply_workspace_edit(workspace_edit, 'utf-16')
      end
    end)
  end)
end


local function java_hash_code_equals_prompt(_, outer_ctx)
  local params = outer_ctx.params
  request(0, 'java/checkHashCodeEqualsStatus', params, function(_, result, ctx)
    if not result or not result.fields or #result.fields == 0 then
      print(string.format("The operation is not applicable to the type %", result.type))
      return
    end
    local fields = ui.pick_many(result.fields, 'Include item in equals/hashCode?', function(x)
      return string.format('%s: %s', x.name, x.type)
    end)
    request(ctx.bufnr, 'java/generateHashCodeEquals', { context = params; fields = fields; }, function(e, edit)
      if e then
        print("Could not execute java/generateHashCodeEquals: " .. e.message)
      end
      if edit then
        vim.lsp.util.apply_workspace_edit(edit, 'utf-16')
      end
    end)
  end)
end


local function handle_refactor_workspace_edit(err, result, ctx)
  if err then
    print('Error getting refactoring edit: ' .. err.message)
    return
  end
  if not result then
    return
  end

  if result.edit then
    vim.lsp.util.apply_workspace_edit(result.edit, 'utf-16')
  end

  if result.command then
    local command = result.command
    local fn = M.commands[command.command]
    if fn then
      fn(command, ctx)
    else
      execute_command(command)
    end
  end
end


local function move_file(command, code_action_params)
  local uri = command.arguments[3].uri
  local params = {
    moveKind = 'moveResource';
    sourceUris = { uri, },
    params = vim.NIL
  }
  request(0, 'java/getMoveDestinations', params, function(err, result, ctx)
    assert(not err, err and err.message or vim.inspect(err))
    if result and result.errorMessage then
      print(result.errorMessage)
      return
    end
    if not result or not result.destinations or #result.destinations == 0 then
      print("Couldn't find any destination packages")
      return
    end
    local destinations = vim.tbl_filter(
      function(x) return not x.isDefaultPackage end,
      result.destinations
    )
    ui.pick_one_async(
      destinations,
      'Target package> ',
      function(x) return x.project .. ' » ' .. (x.isParentOfSelectedFile and '* ' or '') .. x.displayName end,
      function(x)
        local move_params = {
          moveKind = 'moveResource',
          sourceUris = { uri, },
          params = code_action_params,
          destination = x,
          updateReferences = true
        }
        request(ctx.bufnr, 'java/move', move_params, function(move_err, refactor_edit)
          handle_refactor_workspace_edit(move_err, refactor_edit)
        end)
      end
    )
  end)
end


local function move_instance_method(command, code_action_params)
  local params = {
    moveKind = 'moveInstanceMethod';
    sourceUris = { command.arguments[2].textDocument.uri, };
    params = code_action_params
  }
  request(0, 'java/getMoveDestinations', params, function(err, result, ctx)
    assert(not err, err and err.message or vim.inspect(err))
    if result and result.errorMessage then
      print(result.errorMessage)
      return
    end
    if not result or not result.destinations or #result.destinations == 0 then
      print("Couldn't find any destinations")
      return
    end
    ui.pick_one_async(
      result.destinations,
      'Destination> ',
      function(x)
        local prefix
        if x.isField then
          prefix = '[Field]            '
        else
          prefix = '[Method Parameter] '
        end
        return prefix .. x.type .. ' ' .. x.name
      end,
      function(x)
        params.destination = x
        params.updateReferences = true
        request(ctx.bufnr, 'java/move', params, function(move_err, refactor_edit)
          handle_refactor_workspace_edit(move_err, refactor_edit)
        end)
      end
    )
  end)
end

local function search_symbols(project, enclosing_type_name, on_selection)
  local params = {
    query = '*',
    projectName = project,
    sourceOnly = true,
  }
  request(0, 'java/searchSymbols', params, function(err, result, ctx)
    assert(not err, err and err.message or vim.inspect(err))
    if not result or #result == 0 then
      print("Couldn't find any destinations")
      return
    end
    if enclosing_type_name then
      result = vim.tbl_filter(
        function(x)
          if x.containerName then
            return enclosing_type_name == x.containerName .. '.' .. x.name
          else
            return enclosing_type_name == x.name
          end
        end,
        result
      )
    end
    ui.pick_one_async(
      result,
      'Destination> ',
      function(x) return x.containerName .. ' » ' .. x.name end,
      function(x)
        on_selection(x, ctx.bufnr)
      end
    )
  end)
end


local function move_static_member(command, code_action_params)
  local member = command.arguments[3]
  search_symbols(
    member.projectName,
    member.enclosingTypeName,
    function(picked, bufnr)
      local move_params = {
        moveKind = 'moveStaticMember',
        sourceUris = { command.arguments[2].uri },
        params = code_action_params,
        destination = picked
      }
      request(bufnr, 'java/move', move_params, function(move_err, refactor_edit)
        handle_refactor_workspace_edit(move_err, refactor_edit)
      end)
    end
  )
end

local function move_type(command, code_action_params)
  local info = command.arguments[3]
  if not info.supportedDestinationKinds or #info.supportedDestinationKinds == 0 then
    print('No available destinations')
    return
  end
  ui.pick_one_async(
    info.supportedDestinationKinds,
    'Action> ',
    function(x)
      if x == 'newFile' then
        return string.format('Move type `%s` to new file', info.displayName)
      else
        return string.format('Move type `%s` to another class', info.displayName)
      end
    end,
    function(x)
      if x == 'newFile' then
        local move_params = {
          moveKind = 'moveTypeToNewFile',
          sourceUris = { command.arguments[2].textDocument.uri },
          params = code_action_params
        }
        request(0, 'java/move', move_params, function(move_err, refactor_edit)
          handle_refactor_workspace_edit(move_err, refactor_edit)
        end)
      else
        search_symbols(
          info.projectName,
          info.enclosingTypeName,
          function(picked, bufnr)
            local move_params = {
              moveKind = 'moveTypeToClass',
              sourceUris = { command.arguments[2].uri },
              params = code_action_params,
              destination = picked
            }
            request(bufnr, 'java/move', move_params, function(move_err, refactor_edit)
              handle_refactor_workspace_edit(move_err, refactor_edit)
            end)
          end
        )
      end
    end
  )
end


local function java_apply_refactoring_command(command, outer_ctx)
  local cmd = command.arguments[1]
  local code_action_params = outer_ctx.params
  local params = {
    command = cmd,
    context = code_action_params,
    options = {
      tabSize = vim.lsp.util.get_effective_tabstop(),
      insertSpaces = vim.bo.expandtab,
    }
  }
  if cmd == 'moveFile' then
    return move_file(command, code_action_params)
  elseif cmd == 'moveInstanceMethod' then
    return move_instance_method(command, code_action_params)
  elseif cmd == 'moveStaticMember' then
    return move_static_member(command, code_action_params)
  elseif cmd == 'moveType' then
    return move_type(command, code_action_params)
  end
  if not vim.tbl_contains(setup.extendedClientCapabilities.inferSelectionSupport, cmd) then
    request(0, 'java/getRefactorEdit', params, handle_refactor_workspace_edit)
    return
  end
  local range = code_action_params.range
  if not (range.start.character == range['end'].character and range.start.line == range['end'].line) then
    request(0, 'java/getRefactorEdit', params, handle_refactor_workspace_edit)
    return
  end

  request(0, 'java/inferSelection', params, function(err, selection_info, ctx)
    assert(not err, vim.inspect(err))
    if not selection_info or #selection_info == 0 then
      print('No selection found that could be extracted')
      return
    end
    if #selection_info == 1 then
      params.commandArguments = selection_info
      request(ctx.bufnr, 'java/getRefactorEdit', params, handle_refactor_workspace_edit)
    else
      ui.pick_one_async(
        selection_info,
        'Choices:',
        function(x) return x.name end,
        function(selection)
          if not selection then return end
          params.commandArguments = {selection}
          request(ctx.bufnr, 'java/getRefactorEdit', params, handle_refactor_workspace_edit)
        end
      )
    end
  end)
end


local function java_action_rename(command, ctx)
  local target = command.arguments[1]
  local win = api.nvim_get_current_win()

  local bufnr = api.nvim_win_get_buf(win)
  if bufnr ~= ctx.bufnr then
    return
  end

  local lines = vim.api.nvim_buf_get_lines(ctx.bufnr, 0, -1, true)
  local content = table.concat(lines, '\n')

  local byteidx = vim.fn.byteidx(content, target.offset)
  local line = vim.fn.byte2line(byteidx)
  local col = byteidx - vim.fn.line2byte(line)

  api.nvim_win_set_cursor(win, { line, col + 1 })
end


local function java_action_organize_imports(_, ctx)
  request(0, 'java/organizeImports', ctx.params, function(err, resp)
    if err then
      print('Error on organize imports: ' .. err.message)
      return
    end
    if resp then
      vim.lsp.util.apply_workspace_edit(resp, 'utf-16')
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
    api.nvim_command('normal! zvzz')
    api.nvim_buf_add_highlight(
      0, highlight_ns, 'IncSearch', start.line, start.character, selection.range['end'].character)
    api.nvim_command("redraw")

    local candidates = selection.candidates
    local fqn = candidates[1].fullyQualifiedName
    local type_name = fqn:sub(find_last(fqn, '%.') + 1)
    local choice = #candidates == 1 and candidates[1] or ui.pick_one(
      candidates,
      'Choose type ' .. type_name .. ' to import',
      function(x) return x.fullyQualifiedName end
    )
    api.nvim_buf_clear_namespace(0, highlight_ns, 0, -1)
    table.insert(choices, choice)
  end
  return choices
end

local function java_override_methods(_, context)
  request(context.bufnr, 'java/listOverridableMethods', context.params, function(e1, result1)
    if e1 then
      print("Error getting overridable methods: " .. e1.message)
      return
    end

    local fmt = function(method)
      return string.format("%s(%s) class: %s", method.name, table.concat(method.parameters, ", "), method.declaringClass)
    end

    local selected = ui.pick_many(result1.methods, "Method to override", fmt)

    if #selected < 1 then
      return
    end

    local params = {
      context = context.params,
      overridableMethods = selected
    }
    request(context.bufnr, 'java/addOverridableMethods', params, function(e2, result2)
      if e2 ~= nil then
        print("Error getting workspace edits: " .. e2.message)
        return
      end
      vim.lsp.util.apply_workspace_edit(result2, 'utf-16')
    end)
  end)
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
  ['java.action.overrideMethodsPrompt'] = java_override_methods;
}

if vim.lsp.commands then
  for k, v in pairs(M.commands) do
    vim.lsp.commands[k] = v  -- luacheck: ignore 122
  end
end


if not vim.lsp.handlers['workspace/executeClientCommand'] then
  vim.lsp.handlers['workspace/executeClientCommand'] = function(_, params, ctx)  -- luacheck: ignore 122
    local fn = M.commands[params.command]
    if fn then
      local ok, result = pcall(fn, params.arguments, ctx)
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


local function make_code_action_params(from_selection)
  local params
  if from_selection then
    params = vim.lsp.util.make_given_range_params()
  else
    params = vim.lsp.util.make_range_params()
  end
  local bufnr = api.nvim_get_current_buf()
  params.context = {
    diagnostics = vim.lsp.diagnostic.get_line_diagnostics(bufnr),
  }
  return params
end


--- Organize the imports in the current buffer
function M.organize_imports()
  java_action_organize_imports(nil, { params = make_code_action_params(false) })
end


---@private
function M._complete_compile()
  return 'full\nincremental'
end

local function on_build_result(err, result)
  local CompileWorkspaceStatus = {
    FAILED = 0,
    SUCCEED = 1,
    WITHERROR = 2,
    CANCELLED = 3,
  }
  assert(not err, 'Error trying to build project(s): ' .. vim.inspect(err))
  if result == CompileWorkspaceStatus.SUCCEED then
    vim.fn.setqflist({}, 'r', { title = 'jdtls'; items = {} })
    print('Compile successfull')
  else
    vim.tbl_add_reverse_lookup(CompileWorkspaceStatus)
    local project_config_errors = {}
    local compile_errors = {}
    for _, d in pairs(vim.diagnostic.get(nil)) do
      local fname = api.nvim_buf_get_name(d.bufnr)
      local stat = vim.loop.fs_stat(fname)
      local items
      if (vim.endswith(fname, 'build.gradle')
          or vim.endswith(fname, 'pom.xml')
          or (stat and stat.type == 'directory')) then
        items = project_config_errors
      elseif vim.fn.fnamemodify(fname, ':e') == 'java' then
        items = compile_errors
      end
      if d.severity == vim.diagnostic.severity.ERROR and items then
        table.insert(items, d)
      end
    end
    local items = #project_config_errors > 0 and project_config_errors or compile_errors
    vim.fn.setqflist({}, 'r', { title = 'jdtls'; items = vim.diagnostic.toqflist(items) })
    if #items > 0 then
      print(string.format('Compile error. (%s)', CompileWorkspaceStatus[result]))
      vim.cmd('copen')
    else
      print("Compile error, but no error diagnostics available."
        .. " Save all pending changes and try running compile again."
        .. " If you used incremental mode, try a full rebuild.")
    end
  end
end


--- Compile/build the Java workspace.
--- If there are compile errors they'll be shown in the quickfix list.
---
---@param type nil|"full"|"incremental"
function M.compile(type)
  request(0, 'java/buildWorkspace', type == 'full', on_build_result)
end


---@param mode nil|"prompt"|"all"
local function pick_projects(mode, on_projects)
  local command = {
    command = 'java.project.getAll',
  }
  local bufnr = api.nvim_get_current_buf()
  util.execute_command(command, function(err, projects)
    if err then
      error(err.message or vim.inspect(err))
    end
    local selection
    if mode == "all" then
      selection = projects
    elseif #projects == 1 then
      selection = projects
    else
      selection = ui.pick_many(
        projects,
        'Projects> ',
        function(project)
          return vim.fn.fnamemodify(project, ':.:t')
        end
      )
    end
    on_projects(selection)
  end, bufnr)
end


--- Trigger a rebuild of one or more projects.
---
---@param opts JdtBuildProjectOpts|nil optional configuration options
function M.build_projects(opts)
  opts = opts or {}
  local bufnr = api.nvim_get_current_buf()
  pick_projects(opts.select_mode or "prompt", function(selection)
    if selection and next(selection) then
      local params = {
        identifiers = vim.tbl_map(function(project) return { uri = project } end, selection),
        isFullBuild = opts.full_build == nil and true or opts.full_build
      }
      vim.lsp.buf_request(bufnr, 'java/buildProjects', params, on_build_result)
    end
  end)
end
---@class JdtBuildProjectOpts
---@field select_mode JdtProjectSelectMode Show prompt to select projects or select all. Defaults to "prompt"
---@field full_build boolean full rebuild or incremental build. Defaults to true (full build)

--- Update the project configuration (from Gradle or Maven).
--- In a multi-module project this will only update the configuration of the
--- module of the current buffer.
function M.update_project_config()
  local params = { uri = vim.uri_from_bufnr(0) }
  request(0, 'java/projectConfigurationUpdate', params, function(err)
    if err then
      print('Could not update project configuration: ' .. err.message)
      return
    end
  end)
end

--- Process changes made to the Gradle or Maven configuration of one or more projects.
--- Requires eclipse.jdt.ls >= 1.13.0
---
---@param opts JdtUpdateProjectsOpts|nil configuration options
function M.update_projects_config(opts)
  opts = opts or {}
  local bufnr = api.nvim_get_current_buf()
  pick_projects(opts.select_mode or "prompt", function(selection)
    if selection and next(selection) then
      local params = {
        identifiers = vim.tbl_map(function(project) return { uri = project } end, selection)
      }
      vim.lsp.buf_notify(bufnr, 'java/projectConfigurationsUpdate', params)
    end
  end)
end
---@class JdtUpdateProjectsOpts
---@field select_mode JdtProjectSelectMode|nil show prompt to select projects or select all. Defaults to "prompt"

---@alias JdtProjectSelectMode "all"|"prompt"|nil
--

local function mk_extract(entity)
  return function(from_selection)
    local params = make_code_action_params(from_selection or false)
    java_apply_refactoring_command({ arguments = { entity }, }, { params = params })
  end
end

M.extract_constant = mk_extract('extractConstant')
M.extract_variable = mk_extract('extractVariable')
M.extract_method = mk_extract('extractMethod')


--- Run the `javap` tool in a terminal buffer.
--- Sets the classpath based on the current project.
function M.javap()
  with_classpaths(function(resp)
    local classname = resolve_classname()
    local cp = table.concat(resp.classpaths, ':')
    local buf = api.nvim_create_buf(false, true)
    api.nvim_win_set_buf(0, buf)
    vim.fn.termopen({'javap', '-c', '--class-path', cp, classname})
  end)
end


--- Run the `jshell` tool in a terminal buffer.
--- Sets the classpath based on the current project.
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
      local jshell = vim.fn.fnamemodify(java_exec, ':p:h') .. '/jshell'
      vim.fn.termopen(jshell, { env = { ["CLASSPATH"] = cp }})
    end)
  end)
end


--- Run the `jol` tool in a terminal buffer to print the class layout
--- You must configure `jol_path` to point to the `jol` jar file:
---
--- ```
--- require('jdtls').jol_path = '/absolute/path/to/jol.jar`
--- ```
---
--- https://github.com/openjdk/jol
---
--- Must be called from a regular java source file.
---
--- Examples:
--- ```
--- lua require('jdtls').jol()
--- ```
---
--- ```
--- lua require('jdtls').jol(nil, "java.util.ImmutableCollections$List12")
--- ```
---@param mode nil|"estimates"|"footprint"|"externals"|"internals"
---@param classname string|nil fully qualified class name. Defaults to the current class.
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
---
--- This requires at least one open buffer that is connected to the jdtls
--- language server.
---
--- nvim-jdtls by defaults configures a `BufReadCmd` event which uses this function.
--- You shouldn't need to call this manually.
---
--- @param uri string expected to be a `jdt://` uri
function M.open_jdt_link(uri)
  local client
  for _, c in ipairs(vim.lsp.get_active_clients()) do
    if c.config.init_options
      and c.config.init_options.extendedClientCapabilities
      and c.config.init_options.extendedClientCapabilities.classFileContentsSupport then

      client = c
      break
    end
  end
  assert(client, 'Must have a buffer open with a language client connected to eclipse.jdt.ls to load JDT URI')
  local buf = api.nvim_get_current_buf()
  local params = {
    uri = uri
  }
  local response = nil
  local cb = function(err, result)
    response = {err, result}
  end
  local ok, request_id = client.request('java/classFileContents', params, cb, buf)
  assert(ok, 'Request to `java/classFileContents` must succeed to open JDT URI. Client shutdown?')
  local timeout_ms = M.settings.jdt_uri_timeout_ms
  local wait_ok, reason = vim.wait(timeout_ms, function() return response end)
  local log_path = require('jdtls.path').join(vim.fn.stdpath('cache'), 'lsp.log')
  local buf_content
  if wait_ok and #response == 2 and response[2] then
    local content = response[2]
    if content == "" then
      buf_content = {
        'Received response from server, but it was empty. Check the log file for errors', log_path}
    else
      buf_content = vim.split(response[2], '\n', true)
    end
  else
    local error_msg
    if not wait_ok then
      client.cancel_request(request_id)
      local wait_failure = {
        [-1] = 'timeout';
        [-2] = 'interrupted';
        [-3] = 'error'
      }
      error_msg = wait_failure[reason]
    else
      error_msg = response[1]
    end
    buf_content = {
      'Failed to load content for uri',
      uri,
      '',
      'Error was: ',
    }
    vim.list_extend(buf_content, vim.split(vim.inspect(error_msg), '\n'))
    vim.list_extend(buf_content, {'', 'Check the log file for errors', log_path})
  end
  api.nvim_buf_set_option(buf, 'modifiable', true)
  api.nvim_buf_set_lines(buf, 0, -1, false, buf_content)
  api.nvim_buf_set_option(0, 'filetype', 'java')
  api.nvim_buf_set_option(buf, 'modifiable', false)
end


---@private
function M._complete_set_runtime()
  local client
  for _, c in pairs(vim.lsp.get_active_clients()) do
    if c.config.settings.java then
      client = c
      break
    end
  end
  if not client then
    return {}
  end
  local runtimes = (client.config.settings.java.configuration or {}).runtimes or {}
  return table.concat(vim.tbl_map(function(runtime) return runtime.name end, runtimes), '\n')
end

--- Change the Java runtime.
--- This requires a `settings.java.configuration.runtimes` configuration.
---
---@param runtime nil|string Java runtime. Prompts for runtime if nil
function M.set_runtime(runtime)
  local client
  for _, c in pairs(vim.lsp.get_active_clients()) do
    if c.config.settings.java then
      client = c
      break
    end
  end
  if not client then
    vim.notify('No LSP client found with settings for java', vim.log.levels.ERROR)
    return
  end
  local runtimes = (client.config.settings.java.configuration or {}).runtimes or {}
  if #runtimes == 0 then
    vim.notify(
      'No runtimes found in `config.settings.java.configuration.runtimes`. You need to add runtime paths to change the runtime',
      vim.log.levels.WARN
    )
    return
  end
  if runtime then
    local match = false
    for _, r in pairs(runtimes) do
      if r.name == runtime then
        r.default = true
        match = true
      else
        r.default = nil
      end
    end
    if not match then
      vim.notify(
        'Provided runtime `' .. runtime .. '` not found in `config.settings.java.configuration.runtimes`',
        vim.log.levels.WARN
      )
      return
    end
    client.notify('workspace/didChangeConfiguration', { settings = client.config.settings })
  else
    ui.pick_one_async(
      runtimes,
      'Runtime> ',
      function(r)
        return r.name
      end,
      function(selected_runtime)
        if not selected_runtime then
          return
        end
        selected_runtime.default = true
        for _, r in pairs(runtimes) do
          if r ~= selected_runtime then
            r.default = nil
          end
        end
        client.notify('workspace/didChangeConfiguration', { settings = client.config.settings })
      end
    )
  end
end


return M
