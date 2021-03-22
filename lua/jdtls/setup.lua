local api = vim.api
local lsp = vim.lsp
local uv = vim.loop
local path = require('jdtls.path')
local util = require('jdtls.util')

local lsps = {}
local status_callback = vim.schedule_wrap(function(_, _, result)
  api.nvim_command(string.format(':echohl Function | echo "%s" | echohl None', result.message))
end)

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

local function find_root(markers, bufname)
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


local extendedClientCapabilities = {
  classFileContentsSupport = true;
  generateToStringPromptSupport = true;
  hashCodeEqualsPromptSupport = true;
  advancedExtractRefactoringSupport = true;
  advancedOrganizeImportsSupport = true;
  generateConstructorsPromptSupport = true;
  generateDelegateMethodsPromptSupport = true;
  moveRefactoringSupport = true;
  inferSelectionSupport = {"extractMethod", "extractVariable"};
};


local function tabsize(bufnr)
  local get_option = api.nvim_buf_get_option
  local sts = get_option(bufnr, 'softtabstop')
  return (
    (sts > 0 and sts)
    or (sts < 0 and get_option(bufnr, 'shiftwidth'))
    or get_option(bufnr, 'tabstop')
  )
end


local function configuration_handler(err, method, params, client_id, bufnr, config)
  local client = vim.lsp.get_client_by_id(client_id)
  -- This isn't done in start_or_attach because a user could use a plugin like editorconfig to configue tabsize/spaces
  -- That plugin may run after `start_or_attach` which is why we defer the setting lookup.
  -- This ensures the language-server will use the latest version of the options
  client.config.settings = vim.tbl_deep_extend('keep', client.config.settings or {}, {
    java = {
      format = {
        insertSpaces = api.nvim_buf_get_option(bufnr, 'expandtab'),
        tabSize = tabsize(bufnr),
      }
    }
  })
  return vim.lsp.handlers['workspace/configuration'](err, method, params, client_id, bufnr, config)
end


local function nil_zero_version_in_edit(default_handler, upstream)
  return function(...)
    local edit = select(3, ...)
    util._nil_version_if_zero(edit)
    local handler = default_handler or vim.lsp.handlers[upstream]
    handler(...)
  end
end


local function start_or_attach(config)
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
    or find_root({'.git', 'gradlew', 'mvnw'}, bufname)
    or vim.fn.getcwd()
  )
  config.handlers = config.handlers or {}
  config.handlers['language/status'] = config.handlers['language/status'] or status_callback
  config.handlers['workspace/configuration'] = config.handlers['workspace/configuration'] or configuration_handler
  config.handlers['workspace/applyEdit'] = nil_zero_version_in_edit(config.handlers['workspace/applyEdit'], 'workspace/applyEdit')
  config.handlers['textDocument/rename'] = nil_zero_version_in_edit(config.handlers['textDocument/rename'], 'textDocument/rename')
  local capabilities = config.capabilities or lsp.protocol.make_client_capabilities()
  capabilities.textDocument.codeAction = {
      dynamicRegistration = false;
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
  config.capabilities = capabilities
  config.init_options = config.init_options or {}
  config.init_options.extendedClientCapabilities = (
    config.init_options.extendedClientCapabilities or vim.deepcopy(extendedClientCapabilities)
  )
  local workspace = capabilities.workspace or {}
  if not workspace.workspaceEdit
    or not vim.tbl_contains(workspace.workspaceEdit.resourceOperations, 'rename')
    or not vim.tbl_contains(workspace.workspaceEdit.resourceOperations, 'create')
    or not vim.tbl_contains(workspace.workspaceEdit.resourceOperations, 'delete')
  then
    config.init_options.extendedClientCapabilities.moveRefactoringSupport = false;
  end
  local client_id = lsps[config.root_dir]
  if not client_id then
    client_id = lsp.start_client(config)
    lsps[config.root_dir] = client_id
  end
  lsp.buf_attach_client(bufnr, client_id)
end


local function add_commands()
  api.nvim_command [[command! -buffer -nargs=? JdtCompile lua require('jdtls').compile(<f-args>)]]
  api.nvim_command [[command! -buffer JdtUpdateConfig lua require('jdtls').update_project_config()]]
  api.nvim_command [[command! -buffer -nargs=* JdtJol lua require('jdtls').jol(<f-args>)]]
  api.nvim_command [[command! -buffer JdtBytecode lua require('jdtls').javap()]]
  api.nvim_command [[command! -buffer JdtJshell lua require('jdtls').jshell()]]
end

return {
  start_or_attach = start_or_attach;
  extendedClientCapabilities = extendedClientCapabilities;
  add_commands = add_commands;
  find_root = find_root;
}
