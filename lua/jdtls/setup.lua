local api = vim.api
local lsp = vim.lsp
local uv = vim.loop
local path = require('jdtls.path')
local M = {}
local URI_SCHEME_PATTERN = '^([a-zA-Z]+[a-zA-Z0-9+-.]*)://.*'


local status_callback = function(_, result)
  api.nvim_command(string.format(':echohl Function | echo "%s" | echohl None', result.message))
end


local lsp_clients = {}
do
  local client_id_by_root_dir = {}

  function lsp_clients.start(config)
      local bufnr = api.nvim_get_current_buf()
      local root_dir = uv.fs_realpath(config.root_dir)
      local client_id = client_id_by_root_dir[root_dir]
      -- client could have died on us; so check if alive
      if client_id then
        local client = lsp.get_client_by_id(client_id)
        if not client or client.is_stopped() then
          client_id = nil
        end
      end
      if not client_id then
        client_id = lsp.start_client(config)
        client_id_by_root_dir[root_dir] = client_id
      end
      lsp.buf_attach_client(bufnr, client_id)
  end

  function lsp_clients.stop()
    for root_dir, client_id in pairs(client_id_by_root_dir) do
      local client = lsp.get_client_by_id(client_id)
      if client then
        client.stop()
        client_id_by_root_dir[root_dir] = nil
      end
    end
  end

  function lsp_clients.restart()
    for root_dir, client_id in pairs(client_id_by_root_dir) do
      local client = lsp.get_client_by_id(client_id)
      if client then
        local bufs = lsp.get_buffers_by_client_id(client_id)
        client.stop()
        client_id = lsp.start_client(client.config)
        client_id_by_root_dir[root_dir] = client_id
        for _, buf in pairs(bufs) do
          lsp.buf_attach_client(buf, client_id)
        end
      end
    end
  end
end

M.restart = lsp_clients.restart


local function attach_to_active_buf(bufnr, client_name)
  for _, buf in pairs(vim.fn.getbufinfo({bufloaded=true})) do
    if api.nvim_buf_get_option(buf.bufnr, 'filetype') == 'java' then
      local clients = lsp.buf_get_clients(buf.bufnr)
      for _, client in ipairs(clients) do
        if client.config.name == client_name then
          lsp.buf_attach_client(bufnr, client.id)
          return true
        end
      end
    end
  end
  print('No active LSP client found to use for jdt:// document')
  return false
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
  classFileContentsSupport = true;
  generateToStringPromptSupport = true;
  hashCodeEqualsPromptSupport = true;
  advancedExtractRefactoringSupport = true;
  advancedOrganizeImportsSupport = true;
  generateConstructorsPromptSupport = true;
  generateDelegateMethodsPromptSupport = true;
  moveRefactoringSupport = true;
  overrideMethodsPromptSupport = true;
  inferSelectionSupport = {
    "extractMethod",
    "extractVariable",
    "extractConstant",
    "extractVariableAllOccurrence"
  };
};


local function configuration_handler(err, result, ctx, config)
  local client_id = ctx.client_id
  local bufnr = 0
  local client = lsp.get_client_by_id(client_id)
  -- This isn't done in start_or_attach because a user could use a plugin like editorconfig to configure tabsize/spaces
  -- That plugin may run after `start_or_attach` which is why we defer the setting lookup.
  -- This ensures the language-server will use the latest version of the options
  client.config.settings = vim.tbl_deep_extend('keep', client.config.settings or {}, {
    java = {
      format = {
        insertSpaces = api.nvim_buf_get_option(bufnr, 'expandtab'),
        tabSize = lsp.util.get_effective_tabstop(bufnr)
      }
    }
  })
  return lsp.handlers['workspace/configuration'](err, result, ctx, config)
end


local function init_with_config_notify(original_init)
  return function(...)
    local client = select(1, ...)
    if client.config.settings then
      client.notify('workspace/didChangeConfiguration', { settings = client.config.settings })
    end
    if original_init then
      original_init(...)
    end
  end
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
      vim.fn.mkdir(vim.fn.expand('%:p:h'), 'p')
      vim.cmd('w')
    end
  end
end


local function extract_data_dir(bufnr)
  local is_jdtls = function(client)
    return client.name == 'jdtls'
  end
  -- Prefer client from current buffer, in case there are multiple jdtls clients (multiple projects)
  local client = vim.tbl_filter(is_jdtls, vim.lsp.buf_get_clients(bufnr))[1]
  if not client then
    -- Try first matching jdtls client otherwise. In case the user is in a
    -- different buffer like the quickfix list
    local clients = vim.tbl_filter(is_jdtls, vim.lsp.get_active_clients())
    if vim.tbl_count(clients) > 1 then
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
    for i, part in pairs(client.config.cmd) do
      -- jdtls helper script uses `--data`, java jar command uses `-data`.
      if part == '-data' or part == '--data' then
        return client.config.cmd[i + 1]
      end
    end
  end

  return nil
end


function M.start_or_attach(config)
  assert(config, 'config is required')
  assert(
    config.cmd and type(config.cmd) == 'table',
    'Config must have a `cmd` property and that must be a table. Got: '
      .. table.concat(config.cmd, ' ')
  )
  config.name = 'jdtls'

  local bufnr = api.nvim_get_current_buf()
  local bufname = api.nvim_buf_get_name(bufnr)
  -- Won't be able to get the correct root path for jdt:// URIs
  -- So need to connect to an existing client
  if vim.startswith(bufname, 'jdt://') then
    if attach_to_active_buf(bufnr, config.name) then
      return
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
  local extra_capabilities = {
    textDocument = {
      codeAction = {
        codeActionLiteralSupport = {
          codeActionKind = {
            valueSet = {
                "source.generate.toString",
                "source.generate.hashCodeEquals",
                "source.organizeImports",
            };
          };
        };
      }
    }
  }
  config.capabilities = vim.tbl_deep_extend('keep', capabilities, extra_capabilities)
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
  config.on_init = init_with_config_notify(config.on_init)
  maybe_implicit_save()
  lsp_clients.start(config)
end


function M.wipe_data_and_restart()
  local data_dir = extract_data_dir(vim.api.nvim_get_current_buf())
  if not data_dir then
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
      lsp_clients.stop()
      vim.defer_fn(function()
        vim.fn.delete(data_dir, 'rf')
        for _, buf in pairs(api.nvim_list_bufs()) do
          if vim.bo[buf].filetype == 'java' then
            api.nvim_buf_call(buf, function() vim.cmd('e!') end)
          end
        end
      end, 200)
    end)
  end)
end


function M.add_commands()
  vim.cmd [[command! -buffer -nargs=? -complete=custom,v:lua.require'jdtls'._complete_compile JdtCompile lua require('jdtls').compile(<f-args>)]]
  vim.cmd [[command! -buffer -nargs=? -complete=custom,v:lua.require'jdtls'._complete_set_runtime JdtSetRuntime lua require('jdtls').set_runtime(<f-args>)]]
  vim.cmd [[command! -buffer JdtUpdateConfig lua require('jdtls').update_project_config()]]
  vim.cmd [[command! -buffer -nargs=* JdtJol lua require('jdtls').jol(<f-args>)]]
  vim.cmd [[command! -buffer JdtBytecode lua require('jdtls').javap()]]
  vim.cmd [[command! -buffer JdtJshell lua require('jdtls').jshell()]]
  vim.cmd [[command! -buffer JdtRestart lua require('jdtls.setup').restart()]]
  local ok, dap = pcall(require, 'dap')
  if ok and dap.adapters.java then
    api.nvim_command "command! -buffer JdtRefreshDebugConfigs lua require('jdtls.dap').setup_dap_main_class_configs({ verbose = true })"
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
    api.nvim_create_user_command('JdtHotcodeReplace', redefine_classes, {
      desc = "Trigger reload of changed classes for current debug session",
    })
  end
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
