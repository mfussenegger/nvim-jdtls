local api = vim.api
local M = {}


function M.execute_command(command, callback, bufnr)
  local clients = {}
  local candidates = vim.lsp.get_active_clients({ bufnr = bufnr })
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

  local co
  if not callback then
    co = coroutine.running()
    if co then
      callback = function(err, resp)
        coroutine.resume(co, err, resp)
      end
    end
  end
  clients[1].request('workspace/executeCommand', command, callback, bufnr)
  if co then
    return coroutine.yield()
  end
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
  local bufnr = api.nvim_get_current_buf()
  local uri = vim.uri_from_bufnr(bufnr)
  coroutine.wrap(function()
    local is_test_file_cmd = {
      command = 'java.project.isTestFile',
      arguments = { uri }
    };
    local options
    if vim.startswith(uri, "jdt://") then
      options = vim.fn.json_encode({ scope = "runtime" })
    else
      local err, is_test_file = M.execute_command(is_test_file_cmd, nil, bufnr)
      assert(not err, vim.inspect(err))
      options = vim.fn.json_encode({
        scope = is_test_file and 'test' or 'runtime';
      })
    end
    local cmd = {
      command = 'java.project.getClasspaths';
      arguments = { uri, options };
    }
    local err1, resp = M.execute_command(cmd, nil, bufnr)
    if err1 then
      print('Error executing java.project.getClasspaths: ' .. err1.message)
    else
      fn(resp)
    end
  end)()
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
