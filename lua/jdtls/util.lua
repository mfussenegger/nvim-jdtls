local api = vim.api
local M = {}


function M.execute_command(command, callback, bufnr)
  local clients = {}
  local candidates = bufnr and vim.lsp.buf_get_clients(bufnr) or vim.lsp.get_active_clients()
  for _, c in pairs(candidates) do
    local command_provider = c.server_capabilities.executeCommandProvider
    local commands = type(command_provider) == 'table' and command_provider.commands or {}
    if vim.tbl_contains(commands, command.command) then
      table.insert(clients, c)
    end
  end
  local num_clients = vim.tbl_count(clients)
  if num_clients == 0 then
    if bufnr then
      -- User could've switched buffer to non-java file, try all clients
      return M.execute_command(command, callback, nil)
    else
      vim.notify('No LSP client found that supports ' .. command.command, vim.log.levels.ERROR)
      return
    end
  end

  if num_clients > 1 then
    vim.notify(
      'Multiple LSP clients found that support ' .. command.command .. ' you should have at most one JDTLS server running',
      vim.log.levels.WARN)
  end

  clients[1].request('workspace/executeCommand', command, function(err, resp)
    if callback then
      callback(err, resp)
    elseif err then
      print("Could not execute code action: " .. err.message)
    end
  end)
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


function M.with_classpaths(fn)
  local is_test_file_cmd = {
    command = 'java.project.isTestFile',
    arguments = { vim.uri_from_bufnr(0) }
  };
  M.execute_command(is_test_file_cmd, function(err, is_test_file)
    assert(not err, vim.inspect(err))
    local options = vim.fn.json_encode({
      scope = is_test_file and 'test' or 'runtime';
    })
    local cmd = {
      command = 'java.project.getClasspaths';
      arguments = { vim.uri_from_bufnr(0), options };
    }
    M.execute_command(cmd, function(err1, resp)
      if err1 then
        print('Error executing java.project.getClasspaths: ' .. err1.message)
      else
        fn(resp)
      end
    end)
  end)
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
