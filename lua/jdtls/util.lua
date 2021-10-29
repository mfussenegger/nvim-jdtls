local api = vim.api
local M = {}


function M.mk_handler(fn)
  return function(...)
    local config_or_client_id = select(4, ...)
    local is_new = type(config_or_client_id) ~= 'number'
    if is_new then
      return fn(...)
    else
      local err = select(1, ...)
      local method = select(2, ...)
      local result = select(3, ...)
      local client_id = select(4, ...)
      local bufnr = select(5, ...)
      local config = select(6, ...)
      return fn(err, result, { method = method, client_id = client_id, bufnr = bufnr }, config)
    end
  end
end


function M.execute_command(command, callback, bufnr)
  local clients = {}
  for _, c in pairs(vim.lsp.buf_get_clients(bufnr)) do
    local command_provider = c.server_capabilities.executeCommandProvider
    local commands = type(command_provider) == 'table' and command_provider.commands or {}
    if vim.tbl_contains(commands, command.command) then
      table.insert(clients, c)
    end
  end
  local num_clients = vim.tbl_count(clients)
  if num_clients == 0 then
    vim.notify('No LSP client found that supports ' .. command.command, vim.log.levels.ERROR)
    return
  end

  if num_clients > 1 then
    vim.notify(
      'Multiple LSP clients found that support ' .. command.command .. ' you should have at most one JDTLS server running',
      vim.log.levels.WARN)
  end

  clients[1].request('workspace/executeCommand', command, M.mk_handler(function(err, resp)
    if callback then
      callback(err, resp)
    elseif err then
      print("Could not execute code action: " .. err.message)
    end
  end))
end


function M.with_java_executable(mainclass, project, fn, bufnr)
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
  end, bufnr)
end


function M.resolve_classname()
  local lines = api.nvim_buf_get_lines(0, 0, -1, true)
  local pkgname
  for _, line in ipairs(lines) do
    local match = line:match('package ([a-z0-9_\\.]+);')
    if match then
      pkgname = match
      break
    end
  end
  local classname = vim.fn.fnamemodify(vim.fn.expand('%'), ':t:r')
  if pkgname then
    return pkgname .. '.' .. classname
  else
    return classname
  end
end


return M
