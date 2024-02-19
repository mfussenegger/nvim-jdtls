local api = vim.api
local lsp = vim.lsp
local uv = vim.loop
local path = require('jdtls.path')
local M = {}
local URI_SCHEME_PATTERN = '^([a-zA-Z]+[a-zA-Z0-9+-.]*)://.*'

---@diagnostic disable-next-line: deprecated
local get_clients = vim.lsp.get_clients or vim.lsp.get_active_clients


local status_callback = function(_, result)
  api.nvim_command(string.format(':echohl Function | echo "%s" | echohl None',
                                string.sub(result.message, 1, vim.v.echospace)))
end


M.restart = function()
  for _, client in ipairs(get_clients({ name = "jdtls" })) do
    local bufs = lsp.get_buffers_by_client_id(client.id)
    client.stop()
    vim.wait(30000, function()
      return lsp.get_client_by_id(client.id) == nil
    end)
    local client_id = lsp.start_client(client.config)
    if client_id then
      for _, buf in ipairs(bufs) do
        lsp.buf_attach_client(buf, client_id)
      end
    end
  end
end

local function may_jdtls_buf(bufnr)
  if vim.bo[bufnr].filetype == "java" then
    return true
  end
  local fname = api.nvim_buf_get_name(bufnr)
  return vim.endswith(fname, "build.gradle") or vim.endswith(fname, "pom.xml")
end

---@return integer? client_id
local function attach_to_active_buf(bufnr, client_name)
  local function try_attach(buf)
    if not may_jdtls_buf(buf) then
      return nil
    end
    local clients = get_clients({ bufnr = buf, name = client_name })
    local _, client = next(clients)
    if client then
      lsp.buf_attach_client(bufnr, client.id)
      return client.id
    end
    return nil
  end

  ---@diagnostic disable-next-line: param-type-mismatch
  local altbuf = vim.fn.bufnr("#", -1)
  if altbuf and altbuf > 0 then
    local client_id = try_attach(altbuf)
    if client_id then
      return client_id
    end
  end
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_loaded(buf) then
      local client_id = try_attach(buf)
      if client_id then
        return client_id
      end
    end
  end
  print('No active LSP client found to use for jdt:// document')
  return nil
end


function M.find_root(markers, bufname)
  bufname = bufname or api.nvim_buf_get_name(api.nvim_get_current_buf())
  local dirname = vim.fn.fnamemodify(bufname, ':p:h')
  local getparent = function(p)
    return vim.fn.fnamemodify(p, ':h')
  end
  while getparent(dirname) ~= dirname do
    for _, marker in ipairs(markers) do
      if uv.fs_stat(path.join(dirname, marker)) then
        return dirname
      end
    end
    dirname = getparent(dirname)
  end
end


M.extendedClientCapabilities = {
  classFileContentsSupport = true,
  generateToStringPromptSupport = true,
  hashCodeEqualsPromptSupport = true,
  advancedExtractRefactoringSupport = true,
  advancedOrganizeImportsSupport = true,
  generateConstructorsPromptSupport = true,
  generateDelegateMethodsPromptSupport = true,
  moveRefactoringSupport = true,
  overrideMethodsPromptSupport = true,
  executeClientCommandSupport = true,
  inferSelectionSupport = {
    "extractMethod",
    "extractVariable",
    "extractConstant",
    "extractVariableAllOccurrence"
  },
}


local function configuration_handler(err, result, ctx, config)
  local client_id = ctx.client_id
  local bufnr = 0
  local client = lsp.get_client_by_id(client_id)
  if client then
    -- This isn't done in start_or_attach because a user could use a plugin like editorconfig to configure tabsize/spaces
    -- That plugin may run after `start_or_attach` which is why we defer the setting lookup.
    -- This ensures the language-server will use the latest version of the options
    local new_settings = {
      java = {
        format = {
          insertSpaces = vim.bo[bufnr].expandtab,
          tabSize = lsp.util.get_effective_tabstop(bufnr)
        }
      }
    }
    if client.settings then
      client.settings.java = vim.tbl_deep_extend('keep', client.settings.java or {}, new_settings.java)
    else
      client.config.settings = vim.tbl_deep_extend('keep', client.config.settings or {}, new_settings)
    end
  end
  return lsp.handlers['workspace/configuration'](err, result, ctx, config)
end


local function maybe_implicit_save()
  -- 💀
  -- If the client is attached to a buffer that doesn't exist on the filesystem,
  -- jdtls struggles and cannot provide completions and other functionality
  -- until the buffer is re-attached (`:e!`)
  --
  -- So this implicitly saves a file before attaching the lsp client.
  local bufnr = api.nvim_get_current_buf()
  if vim.o.buftype == '' then
    local uri = vim.uri_from_bufnr(bufnr)
    local scheme = uri:match(URI_SCHEME_PATTERN)
    if scheme ~= 'file' then
      return
    end
    local fname = api.nvim_buf_get_name(bufnr)
    if fname == '' then
      return
    end
    local stat = vim.loop.fs_stat(fname)
    if not stat then
      local filepath = vim.fn.expand('%:p:h')
      assert(type(filepath) == "string")
      vim.fn.mkdir(filepath, 'p')
      vim.cmd('w')
    end
  end
end


---@return string?, lsp.Client?
local function extract_data_dir(bufnr)
  -- Prefer client from current buffer, in case there are multiple jdtls clients (multiple projects)
  local client = get_clients({ name = "jdtls", bufnr = bufnr })[1]
  if not client then
    -- Try first matching jdtls client otherwise. In case the user is in a
    -- different buffer like the quickfix list
    local clients = get_clients({ name = "jdtls" })
    if vim.tbl_count(clients) > 1 then
      ---@diagnostic disable-next-line: cast-local-type
      client = require('jdtls.ui').pick_one(
        clients,
        'Multiple jdtls clients found, pick one: ',
        function(c) return c.config.root_dir end
      )
    else
      client = clients[1]
    end
  end

  if client and client.config and client.config.cmd then
    local cmd = client.config.cmd
    if type(cmd) == "table" then
      for i, part in pairs(cmd) do
        -- jdtls helper script uses `--data`, java jar command uses `-data`.
        if part == '-data' or part == '--data' then
          return client.config.cmd[i + 1], client
        end
      end
    end
  end

  return nil, nil
end


---@param client lsp.Client
---@param opts jdtls.start.opts
local function add_commands(client, bufnr, opts)
  local function create_cmd(name, command, cmdopts)
    api.nvim_buf_create_user_command(bufnr, name, command, cmdopts or {})
  end
  create_cmd("JdtCompile", "lua require('jdtls').compile(<f-args>)", {
    nargs = "?",
    complete = "custom,v:lua.require'jdtls'._complete_compile"
  })
  create_cmd("JdtSetRuntime", "lua require('jdtls').set_runtime(<f-args>)", {
    nargs = "?",
    complete = "custom,v:lua.require'jdtls'._complete_set_runtime"
  })
  create_cmd("JdtUpdateConfig", function(args)
    require("jdtls").update_projects_config(args.bang and { select_mode = "all" } or {})
  end, {
    bang = true
  })
  create_cmd("JdtJol", "lua require('jdtls').jol(<f-args>)", {
    nargs = "*"
  })
  create_cmd("JdtBytecode", "lua require('jdtls').javap()")
  create_cmd("JdtJshell", "lua require('jdtls').jshell()")
  create_cmd("JdtRestart", "lua require('jdtls.setup').restart()")
  local ok, dap = pcall(require, 'dap')
  if ok then
    local command_provider = client.server_capabilities.executeCommandProvider or {}
    local commands = command_provider.commands or {}
    if not vim.tbl_contains(commands, "vscode.java.startDebugSession") then
      return
    end

    require("jdtls.dap").setup_dap(opts.dap or {})
    api.nvim_command "command! -buffer JdtUpdateDebugConfig lua require('jdtls.dap').setup_dap_main_class_configs({ verbose = true })"
    local redefine_classes = function()
      local session = dap.session()
      if not session then
        vim.notify('No active debug session')
      else
        vim.notify('Applying code changes')
        session:request('redefineClasses', nil, function(err)
          assert(not err, vim.inspect(err))
        end)
      end
    end
    api.nvim_create_user_command('JdtUpdateHotcode', redefine_classes, {
      desc = "Trigger reload of changed classes for current debug session",
    })
  end
end


---@class jdtls.start.opts
---@field dap? JdtSetupDapOpts


--- Start the language server (if not started), and attach the current buffer.
---
---@param config table<string, any> configuration. See |vim.lsp.start_client|
---@param opts? jdtls.start.opts
---@param start_opts? lsp.StartOpts options passed to vim.lsp.start
---@return integer? client_id
function M.start_or_attach(config, opts, start_opts)
  opts = opts or {}
  assert(config, 'config is required')
  assert(
    config.cmd and type(config.cmd) == 'table',
    'Config must have a `cmd` property and that must be a table. Got: '
      .. table.concat(config.cmd, ' ')
  )
  config.name = 'jdtls'
  local on_attach = config.on_attach
  config.on_attach = function(client, bufnr)
    if on_attach then
      on_attach(client, bufnr)
    end
    add_commands(client, bufnr, opts)
  end

  local bufnr = api.nvim_get_current_buf()
  local bufname = api.nvim_buf_get_name(bufnr)
  -- Won't be able to get the correct root path for jdt:// URIs
  -- So need to connect to an existing client
  if vim.startswith(bufname, 'jdt://') then
    local client_id = attach_to_active_buf(bufnr, config.name)
    if client_id then
      return client_id
    end
  end

  config.root_dir = (config.root_dir
    or M.find_root({'.git', 'gradlew', 'mvnw'}, bufname)
    or vim.fn.getcwd()
  )
  config.handlers = config.handlers or {}
  config.handlers['language/status'] = config.handlers['language/status'] or status_callback
  config.handlers['workspace/configuration'] = config.handlers['workspace/configuration'] or configuration_handler
  local capabilities = vim.tbl_deep_extend('keep', config.capabilities or {}, lsp.protocol.make_client_capabilities())
  local extra_code_action_literals = {
    "source.generate.toString",
    "source.generate.hashCodeEquals",
    "source.organizeImports",
  }
  local code_action_literals = vim.tbl_get(
    capabilities,
    "textDocument",
    "codeAction",
    "codeActionLiteralSupport",
    "codeActionKind",
    "valueSet"
  ) or {}
  for _, extra_literal in ipairs(extra_code_action_literals) do
    if not vim.tbl_contains(code_action_literals, extra_literal) then
      table.insert(code_action_literals, extra_literal)
    end
  end
  local extra_capabilities = {
    textDocument = {
      codeAction = {
        codeActionLiteralSupport = {
          codeActionKind = {
            valueSet = code_action_literals
          };
        };
      }
    }
  }
  config.capabilities = vim.tbl_deep_extend('force', capabilities, extra_capabilities)

  config.init_options = config.init_options or {}
  config.init_options.extendedClientCapabilities = (
    config.init_options.extendedClientCapabilities or vim.deepcopy(M.extendedClientCapabilities)
  )
  config.settings = vim.tbl_deep_extend('keep', config.settings or {}, {
    -- the `java` property is used in other places to detect the client as the jdtls client
    -- don't remove it without updating those places
    java = {
    }
  })
  maybe_implicit_save()
  return vim.lsp.start(config, start_opts)
end


function M.wipe_data_and_restart()
  local data_dir, client = extract_data_dir(vim.api.nvim_get_current_buf())
  if not data_dir or not client then
    vim.notify(
      "Data directory wasn't detected. " ..
      "You must call `start_or_attach` at least once and the cmd must include a `-data` parameter (or `--data` if using the official `jdtls` wrapper)")
    return
  end
  local opts = {
    prompt = 'Are you sure you want to wipe the data folder: ' .. data_dir .. ' and restart? ',
  }
  vim.ui.select({'Yes', 'No'}, opts, function(choice)
    if choice ~= 'Yes' then
      return
    end
    vim.schedule(function()
      local bufs = vim.lsp.get_buffers_by_client_id(client.id)
      client.stop()
      vim.wait(30000, function()
        return vim.lsp.get_client_by_id(client.id) == nil
      end)
      vim.fn.delete(data_dir, 'rf')
      local client_id = lsp.start_client(client.config)
      if client_id then
        for _, buf in ipairs(bufs) do
          lsp.buf_attach_client(buf, client_id)
        end
      end
    end)
  end)
end


---@deprecated not needed, start automatically adds commands
function M.add_commands()
end


function M.show_logs()
  local data_dir = extract_data_dir(vim.api.nvim_get_current_buf())
  if data_dir then
    vim.cmd('split | e ' .. data_dir .. '/.metadata/.log | normal G')
  end
  if vim.fn.has('nvim-0.8') == 1 then
    vim.cmd('vsplit | e ' .. vim.fn.stdpath('log') .. '/lsp.log | normal G')
  else
    vim.cmd('vsplit | e ' .. vim.fn.stdpath('cache') .. '/lsp.log | normal G')
  end
end


return M
