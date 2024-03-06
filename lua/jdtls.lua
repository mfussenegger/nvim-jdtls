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

local offset_encoding = 'utf-16'

---@diagnostic disable-next-line: deprecated
local get_clients = vim.lsp.get_clients or vim.lsp.get_active_clients


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
---
---@param config table<string, any> configuration. See |vim.lsp.start_client|
---@param opts? jdtls.start.opts
---@param start_opts? lsp.StartOpts options passed to vim.lsp.start
---@return integer|nil client_id
function M.start_or_attach(config, opts, start_opts)
  return setup.start_or_attach(config, opts, start_opts)
end


local request = function(bufnr, method, params, handler)
  local clients = get_clients({ bufnr = bufnr, name = "jdtls" })
  local _, client = next(clients)
  if not client then
    vim.notify("No LSP client with name `jdtls` available", vim.log.levels.WARN)
    return
  end
  local co
  if not handler then
    co = coroutine.running()
    if co then
      handler = function(err, result, ctx)
        coroutine.resume(co, err, result, ctx)
      end
    end
  end
  client.request(method, params, handler, bufnr)
  if co then
    return coroutine.yield()
  end
end

local highlight_ns = api.nvim_create_namespace('jdtls_hl')
M.jol_path = nil



local function java_apply_workspace_edit(command)
  for _, argument in ipairs(command.arguments) do
    vim.lsp.util.apply_workspace_edit(argument, offset_encoding)
  end
end


local function java_generate_to_string_prompt(_, outer_ctx)
  local params = outer_ctx.params
  local bufnr = assert(outer_ctx.bufnr, '`outer_ctx` must have bufnr property')
  coroutine.wrap(function()
    local err, result = request(bufnr, 'java/checkToStringStatus', params)
    if err then
      print("Could not execute java/checkToStringStatus: " .. err.message)
      return
    end
    if not result then
      return
    end
    if result.exists then
      local prompt = string.format(
        "Method 'toString()' already exists in '%s'. Do you want to replace it?",
        result.type
      )
      local choice = ui.pick_one({"Replace", "Cancel"}, prompt, tostring)
      if choice == "Cancel" then
        return
      end
    end
    local fields = ui.pick_many(result.fields, 'Include item in toString?', function(x)
      return string.format('%s: %s', x.name, x.type)
    end)
    local e, edit = request(bufnr, 'java/generateToString', { context = params; fields = fields; })
    if e then
      print("Could not execute java/generateToString: " .. e.message)
    elseif edit then
      vim.lsp.util.apply_workspace_edit(edit, offset_encoding)
    end
  end)()
end


local function java_generate_constructors_prompt(_, outer_ctx)
  local bufnr = assert(outer_ctx.bufnr, '`outer_ctx` must have bufnr property')
  coroutine.wrap(function()
    local err0, status = request(bufnr, 'java/checkConstructorsStatus', outer_ctx.params)
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
    local err1, edit = request(bufnr, 'java/generateConstructors', params)
    if err1 then
      print("Could not execute java/generateConstructors: " .. err1.message)
    elseif edit then
      vim.lsp.util.apply_workspace_edit(edit, offset_encoding)
    end
  end)()
end


local function java_generate_delegate_methods_prompt(_, outer_ctx)
  local bufnr = assert(outer_ctx.bufnr, '`outer_ctx` must have bufnr property')
  coroutine.wrap(function()
    local err0, status = request(bufnr, 'java/checkDelegateMethodsStatus', outer_ctx.params)
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
    local err1, workspace_edit = request(bufnr, 'java/generateDelegateMethods', params)
    if err1 then
      print('Could not execute java/generateDelegateMethods', err1.message)
    elseif workspace_edit then
      vim.lsp.util.apply_workspace_edit(workspace_edit, offset_encoding)
    end
  end)()
end


local function java_hash_code_equals_prompt(_, outer_ctx)
  local bufnr = assert(outer_ctx.bufnr, '`outer_ctx` must have bufnr property')
  local params = outer_ctx.params
  coroutine.wrap(function()
    local _, result = request(bufnr, 'java/checkHashCodeEqualsStatus', params)
    if not result then
      vim.notify("No result", vim.log.levels.INFO)
      return
    elseif not result.fields or #result.fields == 0 then
      vim.notify(string.format("The operation is not applicable to the type %", result.type), vim.log.levels.WARN)
      return
    end
    local fields = ui.pick_many(result.fields, 'Include item in equals/hashCode?', function(x)
      return string.format('%s: %s', x.name, x.type)
    end)
    local err, edit = request(bufnr, 'java/generateHashCodeEquals', { context = params; fields = fields; })
    if err then
      print("Could not execute java/generateHashCodeEquals: " .. err.message)
    elseif edit then
      vim.lsp.util.apply_workspace_edit(edit, offset_encoding)
    end
  end)()
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
    vim.lsp.util.apply_workspace_edit(result.edit, offset_encoding)
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
      function(x)
        local name = x.project .. ' » ' .. (x.isParentOfSelectedFile and '* ' or '') .. x.displayName
        local sourceset = string.match(x.path, "src/(%a+)/")
        return (sourceset and sourceset or x.path) .. " » " .. name
      end,
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


---@return {tabSize: integer, insertSpaces: boolean}
local function format_opts()
  return {
    tabSize = vim.lsp.util.get_effective_tabstop(),
    insertSpaces = vim.bo.expandtab,
  }
end


---@param bufnr integer
---@param command table
---@param code_action_params table
local function change_signature(bufnr, command, code_action_params)
  local cmd_name = command.arguments[1]
  local signature = command.arguments[3]
  local edit_buf = api.nvim_create_buf(false, true)
  api.nvim_create_autocmd("BufUnload", {
    buffer = edit_buf,
    once = true,
    callback = function(args)
      local lines = api.nvim_buf_get_lines(args.buf, 0, -1, true)
      local is_delegate = false
      local access_type = signature.modifier
      local method_name = signature.methodName
      local return_type = signature.returnType
      local preview = false
      local expect_param_next = false
      local parameters = {}
      local new_param_idx = #signature.parameters
      for _, line in ipairs(lines) do
        if vim.startswith(line, "---") then
          break
        elseif expect_param_next and vim.startswith(line, "- ") then
          local matches = { line:match("%- ((%d+):) ([^ ]+) (%w+)") }
          if next(matches) then
            table.insert(parameters, {
              name = matches[4],
              originalIndex = assert(tonumber(matches[2]), "Parameter must have originalIndex"),
              type = matches[3],
            })
          else
            matches = { line:match("%- (%w+) ([^ ]+) ?(.*)") }
            if next(matches) then
              table.insert(parameters, {
                type = matches[1],
                name = matches[2],
                defaultValue = matches[3],
                originalIndex = new_param_idx
              })
              new_param_idx = new_param_idx + 1
            end
          end
        elseif vim.startswith(line, "Access type: ") then
          access_type = line:sub(#"Access type: " + 1)
        elseif vim.startswith(line, "Name: ") then
          method_name = line:sub(#"Name: " + 1)
        elseif vim.startswith(line, "Parameters:") then
          expect_param_next = true
        elseif vim.startswith(line, "Return type: ") then
          return_type = line:sub(#"Return type: " + 1)
        end
      end
      local params = {
        command = cmd_name,
        context = code_action_params,
        options = format_opts(),
        commandArguments = {
          signature.methodIdentifier,
          is_delegate,
          method_name,
          access_type,
          return_type,
          parameters,
          signature.exceptions,
          preview
        },
      }
      request(bufnr, 'java/getRefactorEdit', params, handle_refactor_workspace_edit)
    end,
  })
  vim.bo[edit_buf].bufhidden = "wipe"
  local width = math.floor(vim.o.columns * 0.9)
  local height = math.floor(vim.o.lines * 0.8)
  local win_opts = {
    relative = "editor",
    style = "minimal",
    row = math.floor((vim.o.lines - height) * 0.5),
    col = math.floor((vim.o.columns - width) * 0.5),
    width = width,
    height = height,
    border = "single",
  }
  api.nvim_open_win(edit_buf, true, win_opts)
  local lines = {
    "Access type: " .. signature.modifier,
    "Name: " .. signature.methodName,
    "Return type: " .. signature.returnType,
    "Parameters:",
  }
  for _, param in ipairs(signature.parameters) do
    table.insert(lines, string.format("- %d: %s %s",
      param.originalIndex,
      param.type,
      param.name
    ))
  end
  local comment_start = #lines + 1
  vim.list_extend(lines, {
    "",
    string.rep("-", math.max(width, 3)),
    "Labels are used to parse the values. Keep them!",
    "Accept change & close the window:",
    " - `<Ctrl-w> q`",
    " - `:bd`",
    "",
    "Parameters:",
    " - Order sensitive",
    " - New param format: '- <type> <name> [defaultValue]'",
    " - Existing param format: '- <n>: <type> <name>'",
    " - <n> marks the original index, don't add it for new entries, don't change for moved params",
  })
  api.nvim_buf_set_lines(edit_buf, 0, -1, true, lines)
  local highlights = {
    {0, "Access type:", "Identifier"},
    {1, "Name:", "Identifier"},
    {2, "Return type:", "Identifier"},
    {3, "Parameters:", "Identifier"},
  }
  for _, hl in ipairs(highlights) do
    api.nvim_buf_set_extmark(edit_buf, highlight_ns, hl[1], 0, {
      end_row = hl[1],
      end_col = #hl[2],
      hl_group = hl[3],
    })
  end
  api.nvim_buf_set_extmark(edit_buf, highlight_ns, comment_start, 0, {
    hl_group = "Comment",
    end_row = #lines
  })
end


---@param after_refactor? function
local function java_apply_refactoring_command(command, outer_ctx, after_refactor)
  local cmd = command.arguments[1]
  local bufnr = outer_ctx.bufnr
  local code_action_params = outer_ctx.params

  if cmd == 'moveFile' then
    return move_file(command, code_action_params)
  elseif cmd == 'moveInstanceMethod' then
    return move_instance_method(command, code_action_params)
  elseif cmd == 'moveStaticMember' then
    return move_static_member(command, code_action_params)
  elseif cmd == 'moveType' then
    return move_type(command, code_action_params)
  elseif cmd == "changeSignature" then
    return change_signature(bufnr, command, code_action_params)
  end

  local params = {
    command = cmd,
    context = code_action_params,
    options = format_opts(),
  }
  local apply_refactor = function(err, result, ctx)
    handle_refactor_workspace_edit(err, result, ctx)
    if after_refactor then
      after_refactor()
    end
  end
  if not vim.tbl_contains(setup.extendedClientCapabilities.inferSelectionSupport, cmd) then
    request(bufnr, 'java/getRefactorEdit', params, apply_refactor)
    return
  end
  local range = code_action_params.range
  if not (range.start.character == range['end'].character and range.start.line == range['end'].line) then
    request(bufnr, 'java/getRefactorEdit', params, apply_refactor)
    return
  end

  request(bufnr, 'java/inferSelection', params, function(err, selection_info, ctx)
    assert(not err, vim.inspect(err))
    if not selection_info or #selection_info == 0 then
      print('No selection found that could be extracted')
      return
    end
    if #selection_info == 1 then
      params.commandArguments = selection_info
      request(ctx.bufnr, 'java/getRefactorEdit', params, apply_refactor)
    else
      ui.pick_one_async(
        selection_info,
        'Choices:',
        function(x) return x.name end,
        function(selection)
          if not selection then return end
          params.commandArguments = {selection}
          request(ctx.bufnr, 'java/getRefactorEdit', params, apply_refactor)
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
      vim.lsp.util.apply_workspace_edit(resp, offset_encoding)
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
  local bufnr = assert(context.bufnr, '`context` must have bufnr property')
  coroutine.wrap(function()
    local err1, result1 = request(bufnr, 'java/listOverridableMethods', context.params)
    if err1 then
      vim.notify("Error getting overridable methods: " .. err1.message, vim.log.levels.WARN)
      return
    end
    if not result1 or not result1.methods then
      vim.notify("No methods to override", vim.log.levels.INFO)
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
    local err2, result2 = request(context.bufnr, 'java/addOverridableMethods', params)
    if err2 ~= nil then
      print("Error getting workspace edits: " .. err2.message)
      return
    end
    if result2 then
      vim.lsp.util.apply_workspace_edit(result2, offset_encoding)
    end
  end)()
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
  ['_java.test.askClientForChoice'] = function(args)
    local prompt = args[1]
    local choices = args[2]
    local pick_many = args[3]
    return require("jdtls.tests")._ask_client_for_choice(prompt, choices, pick_many)
  end,
  ['_java.test.advancedAskClientForChoice'] = function(args)
    local prompt = args[1]
    local choices = args[2]
    -- local advanced_action = args[3]
    local pick_many = args[4]
    return require("jdtls.tests")._ask_client_for_choice(prompt, choices, pick_many)
  end,
  ['_java.test.askClientForInput'] = function(args)
    local prompt = args[1]
    local default = args[2]
    local result = vim.fn.input({
      prompt = prompt .. ': ',
      default = default
    })
    return result and result or vim.NIL
  end,
}

if vim.lsp.commands then
  for k, v in pairs(M.commands) do
    vim.lsp.commands[k] = v  -- luacheck: ignore 122
  end
end


if not vim.lsp.handlers['workspace/executeClientCommand'] then
  vim.lsp.handlers['workspace/executeClientCommand'] = function(_, params, ctx)  -- luacheck: ignore 122
    local client = vim.lsp.get_client_by_id(ctx.client_id) or {}
    local commands = client.commands or {}
    local global_commands = vim.lsp.commands or M.commands
    local fn = commands[params.command] or global_commands[params.command]
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

local function on_build_result(err, result, ctx)
  local CompileWorkspaceStatus = {
    FAILED = 0,
    SUCCEED = 1,
    WITHERROR = 2,
    CANCELLED = 3,
  }
  assert(not err, 'Error trying to build project(s): ' .. vim.inspect(err))
  if result == CompileWorkspaceStatus.SUCCEED then
    vim.fn.setqflist({}, 'r', { title = 'jdtls'; items = {} })
    print('Compile successful')
  else
    vim.tbl_add_reverse_lookup(CompileWorkspaceStatus)
    local project_config_errors = {}
    local compile_errors = {}
    local ns = vim.lsp.diagnostic.get_namespace(ctx.client_id)
    for _, d in pairs(vim.diagnostic.get(nil, { namespace = ns })) do
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


--- Compile the Java workspace
--- If there are compile errors they'll be shown in the quickfix list.
---@param type string|nil
---|"full"
---|"incremental"
function M.compile(type)
  request(0, 'java/buildWorkspace', type == 'full', on_build_result)
end


---@param mode nil|"prompt"|"all"
local function pick_projects(mode)
  local command = {
    command = 'java.project.getAll',
  }
  local bufnr = api.nvim_get_current_buf()
  assert(coroutine.running(), '`pick_projects` must be called within coroutine')
  local err, projects = util.execute_command(command, nil, bufnr)
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
        return project
      end
    )
  end
  return selection
end


--- Trigger a rebuild of one or more projects.
---
---@param opts JdtBuildProjectOpts|nil optional configuration options
function M.build_projects(opts)
  opts = opts or {}
  local bufnr = api.nvim_get_current_buf()
  coroutine.wrap(function()
    local selection = pick_projects(opts.select_mode or "prompt")
    if selection and next(selection) then
      local params = {
        identifiers = vim.tbl_map(function(project) return { uri = project } end, selection),
        isFullBuild = opts.full_build == nil and true or opts.full_build
      }
      request(bufnr, 'java/buildProjects', params, on_build_result)
    end
  end)()
end

---@class JdtBuildProjectOpts
---@field select_mode? JdtProjectSelectMode Show prompt to select projects or select all. Defaults to "prompt"
---@field full_build? boolean full rebuild or incremental build. Defaults to true (full build)

--- Update the project configuration (from Gradle or Maven).
--- In a multi-module project this will only update the configuration of the
--- module of the current buffer.
function M.update_project_config()
  local params = { uri = vim.uri_from_bufnr(0) }
  request(0, 'java/projectConfigurationUpdate', params, function(err)
    if err then
      print('Could not update project configuration: ' .. err.message)
    end
  end)
end

--- Process changes made to the Gradle or Maven configuration of one or more projects.
--- Requires eclipse.jdt.ls >= 1.13.0
---
---@param opts JdtUpdateProjectsOpts|nil configuration options
function M.update_projects_config(opts)
  opts = opts or {}
  coroutine.wrap(function()
    local bufnr = api.nvim_get_current_buf()
    local selection = pick_projects(opts.select_mode or "prompt")
    if selection and next(selection) then
      local params = {
        identifiers = vim.tbl_map(function(project) return { uri = project } end, selection)
      }
      vim.lsp.buf_notify(bufnr, 'java/projectConfigurationsUpdate', params)
    end
  end)()
end

---@class JdtUpdateProjectsOpts
---@field select_mode? JdtProjectSelectMode show prompt to select projects or select all. Defaults to "prompt"

---@alias JdtProjectSelectMode string
---|"all"
---|"prompt"


---@alias jdtls.extract.opts {visual?: boolean, name?: string|fun(): string}


---@param entity string
---@param opts? jdtls.extract.opts
local function extract(entity, opts)
  opts = opts or {}
  if type(opts) == "boolean" then
    -- bwc, param changed from boolean to table
    opts = {
      visual = opts
    }
  end
  local params = make_code_action_params(opts.visual or false)
  local command = { arguments = { entity }, }
  local after_refactor = function()
    local name = opts.name
    if type(name) == "function" then
      name = name()
    end
    if type(name) == "string" then
      vim.lsp.buf.rename(name, { name = "jdtls" })
    end
  end
  java_apply_refactoring_command(command, { params = params }, after_refactor)
end

--- Extract a constant from the expression under the cursor
---@param opts? jdtls.extract.opts
function M.extract_constant(opts)
  extract('extractConstant', opts)
end

--- Extract a variable from the expression under the cursor
---@param opts? jdtls.extract.opts
function M.extract_variable(opts)
  extract('extractVariable', opts)
end

--- Extract a local variable from the expression under the cursor and replace all occurrences
---@param opts? jdtls.extract.opts
function M.extract_variable_all(opts)
  extract('extractVariableAllOccurrence', opts)
end

--- Extract a method
---@param opts? jdtls.extract.opts
function M.extract_method(opts)
  extract('extractMethod', opts)
end


--- Jump to the super implementation of the method under the cursor
function M.super_implementation()
  local params = {
    type = 'superImplementation',
    position = vim.lsp.util.make_position_params(0, offset_encoding),
  }
  request(0, 'java/findLinks', params, function(err, result)
    assert(not err, vim.inspect(err))
    if result and #result == 1 then
      vim.lsp.util.jump_to_location(result[1], offset_encoding, true)
    else
      assert(result == nil or #result == 0, 'Expected one or zero results for `findLinks`')
      vim.notify('No result found')
    end
  end)
end


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
  local bufnr = api.nvim_get_current_buf()
  with_classpaths(function(result)
    local buf = api.nvim_create_buf(true, true)
    local classpaths = {}
    for _, path in pairs(result.classpaths) do
      if vim.fn.filereadable(path) == 1 or vim.fn.isdirectory(path) == 1 then
        table.insert(classpaths, path)
      end
    end
    local cp = table.concat(classpaths, ':')
    with_java_executable(resolve_classname(), '', function(java_exec)
      api.nvim_win_set_buf(0, buf)
      local jshell = java_exec and (vim.fn.fnamemodify(java_exec, ":p:h") .. '/jshell') or "jshell"
      vim.fn.termopen(jshell, { env = { ["CLASSPATH"] = cp }})
    end, bufnr)
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
---@param mode? string
---|"estimates"
---|"footprint"
---|"externals"
---|"internals"
---@param classname? string fully qualified class name. Defaults to the current class.
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


--- Open `jdt://` uri or decompile class contents and load them into the buffer
---
--- nvim-jdtls by defaults configures a `BufReadCmd` event which uses this function.
--- You shouldn't need to call this manually.
---
---@param fname string
function M.open_classfile(fname)
  local uri
  local use_cmd
  if vim.startswith(fname, "jdt://") then
    uri = fname
    use_cmd = false
  else
    uri = vim.uri_from_fname(fname)
    use_cmd = true
    if not vim.startswith(uri, "file://") then
      return
    end
  end
  local buf = api.nvim_get_current_buf()
  vim.bo[buf].modifiable = true
  vim.bo[buf].swapfile = false
  vim.bo[buf].buftype = 'nofile'
  -- This triggers FileType event which should fire up the lsp client if not already running
  vim.bo[buf].filetype = 'java'
  local timeout_ms = M.settings.jdt_uri_timeout_ms
  vim.wait(timeout_ms, function()
    return next(get_clients({ name = "jdtls", bufnr = buf })) ~= nil
  end)
  local client = get_clients({ name = "jdtls", bufnr = buf })[1]
  assert(client, 'Must have a `jdtls` client to load class file or jdt uri')

  local content
  local function handler(err, result)
    assert(not err, vim.inspect(err))
    content = result
    local normalized = string.gsub(result, '\r\n', '\n')
    local source_lines = vim.split(normalized, "\n", { plain = true })
    api.nvim_buf_set_lines(buf, 0, -1, false, source_lines)
    vim.bo[buf].modifiable = false
  end

  if use_cmd then
    local command = {
      command = "java.decompile",
      arguments = { uri }
    }
    execute_command(command, handler)
  else
    local params = {
      uri = uri
    }
    client.request("java/classFileContents", params, handler, buf)
  end
  -- Need to block. Otherwise logic could run that sets the cursor to a position
  -- that's still missing.
  vim.wait(timeout_ms, function() return content ~= nil end)
end


---@private
function M._complete_set_runtime()
  local client
  for _, c in pairs(get_clients()) do
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
  for _, c in pairs(get_clients()) do
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
        return r.name .. ' (' .. r.path .. ')'
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
