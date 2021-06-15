local api = vim.api
local lsp = vim.lsp
local uv = vim.loop
local path = require('jdtls.path')
local M = {}
local URI_SCHEME_PATTERN = '^([a-zA-Z]+[a-zA-Z0-9+-.]*)://.*'


local status_callback = vim.schedule_wrap(function(_, _, result)
  api.nvim_command(string.format(':echohl Function | echo "%s" | echohl None', result.message))
end)


local lsp_clients = {}
do
  local client_id_by_root_dir = {}

  function lsp_clients.start(config)
      local bufnr = api.nvim_get_current_buf()
      local client_id = client_id_by_root_dir[config.root_dir]
      -- client could have died on us; so check if alive
      if client_id then
        local client = lsp.get_client_by_id(client_id)
        if not client or client.is_stopped() then
          client_id = nil
        end
      end
      if not client_id then
        client_id = lsp.start_client(config)
        client_id_by_root_dir[config.root_dir] = client_id
      end
      lsp.buf_attach_client(bufnr, client_id)
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


local function progress_report(_, _, result, client_id)
  local client = lsp.get_client_by_id(client_id)
  if not client then
    return
  end

  -- Messages are only cleared on consumption, so protect against messages
  -- filling up infinitely if user doesn't consume them by discarding new ones.
  -- Ring buffer would be nicer, but messages.progress is a dict
  if vim.tbl_count(client.messages.progress) > 10 then
    return
  end
  client.messages.progress[result.id or 'DUMMY'] = {
    title = result.task,
    message = result.subTask,
    percentage = (result.workDone / result.totalWork) * 100,
    done = result.complete
  }
  vim.cmd("doautocmd <nomodeline> User LspProgressUpdate")
end


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
  while not (getparent(dirname) == dirname) do
    for _, marker in ipairs(markers) do
      if uv.fs_stat(path.join(dirname, marker)) then
        return dirname
      end
    end
    dirname = getparent(dirname)
  end
end


M.extendedClientCapabilities = {
  progressReportProvider = true;
  classFileContentsSupport = true;
  generateToStringPromptSupport = true;
  hashCodeEqualsPromptSupport = true;
  advancedExtractRefactoringSupport = true;
  advancedOrganizeImportsSupport = true;
  generateConstructorsPromptSupport = true;
  generateDelegateMethodsPromptSupport = true;
  moveRefactoringSupport = true;
  inferSelectionSupport = {"extractMethod", "extractVariable", "extractConstant"};
};


local function configuration_handler(err, method, params, client_id, bufnr, config)
  local client = lsp.get_client_by_id(client_id)
  -- This isn't done in start_or_attach because a user could use a plugin like editorconfig to configue tabsize/spaces
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
  return lsp.handlers['workspace/configuration'](err, method, params, client_id, bufnr, config)
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
    local stat = vim.loop.fs_stat(api.nvim_buf_get_name(bufnr))
    if not stat then
      vim.fn.mkdir(vim.fn.expand('%:p:h'), 'p')
      vim.cmd('w')
    end
  end
end


function M.start_or_attach(config)
  assert(config, 'config is required')
  assert(
    config.cmd and type(config.cmd) == 'table',
    'Config must have a `cmd` property and that must be a table. Got: '
      .. table.concat(config.cmd, ' ')
  )
  assert(
    tonumber(vim.fn.executable(config.cmd[1])) == 1,
    'LSP cmd must be an executable: ' .. config.cmd[1]
  )
  config.name = config.name or 'jdt.ls'

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
  config.handlers['language/progressReport'] = config.handlers['language/progressReport'] or progress_report
  config.handlers['language/status'] = config.handlers['language/status'] or status_callback
  config.handlers['workspace/configuration'] = config.handlers['workspace/configuration'] or configuration_handler
  local capabilities = config.capabilities or lsp.protocol.make_client_capabilities()
  local extra_capabilities = {
    textDocument = {
      codeAction = {
        dataSupport = true;
        resolveSupport = {
          properties = {'edit',}
        };
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
    java = {
      progressReports = { enabled = true },
    }
  })
  config.on_init = init_with_config_notify(config.on_init)
  local workspace = capabilities.workspace or {}
  if not workspace.workspaceEdit
    or not vim.tbl_contains(workspace.workspaceEdit.resourceOperations, 'rename')
    or not vim.tbl_contains(workspace.workspaceEdit.resourceOperations, 'create')
    or not vim.tbl_contains(workspace.workspaceEdit.resourceOperations, 'delete')
  then
    config.init_options.extendedClientCapabilities.moveRefactoringSupport = false;
  end
  maybe_implicit_save()
  lsp_clients.start(config)
end


function M.add_commands()
  api.nvim_command [[command! -buffer -nargs=? -complete=custom,v:lua.require'jdtls'._complete_compile JdtCompile lua require('jdtls').compile(<f-args>)]]
  api.nvim_command [[command! -buffer JdtUpdateConfig lua require('jdtls').update_project_config()]]
  api.nvim_command [[command! -buffer -nargs=* JdtJol lua require('jdtls').jol(<f-args>)]]
  api.nvim_command [[command! -buffer JdtBytecode lua require('jdtls').javap()]]
  api.nvim_command [[command! -buffer JdtJshell lua require('jdtls').jshell()]]
  api.nvim_command [[command! -buffer JdtRestart lua require('jdtls.setup').restart()]]
  local ok, dap = pcall(require, 'dap')
  if ok and dap.adapters.java then
    api.nvim_command "command! -buffer JdtRefreshDebugConfigs lua require('jdtls.dap').setup_dap_main_class_configs()"
  end
end


return M
