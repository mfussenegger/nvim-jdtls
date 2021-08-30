local api = vim.api
local request = vim.lsp.buf_request
local M = {}


function M.mk_handler(fn)
  return function(...)
    local count = select('#', ...)
    local config_or_client_id = select(4, ...)
    local is_new = type(config_or_client_id) ~= 'number' or count == 4
    if is_new then
      fn(...)
    else
      local err = select(1, ...)
      local method = select(2, ...)
      local result = select(3, ...)
      local client_id = select(4, ...)
      local bufnr = select(5, ...)
      local config = select(6, ...)
      fn(err, result, { method = method, client_id = client_id, bufnr = bufnr }, config)
    end
  end
end


function M.execute_command(command, callback)
  request(0, 'workspace/executeCommand', command, M.mk_handler(function(err, resp)
    if callback then
      callback(err, resp)
    elseif err then
      print("Could not execute code action: " .. err.message)
    end
  end))
end


function M.with_java_executable(mainclass, project, fn)
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
  assert(pkgname, 'Could not find package name for current class')
  local classname = vim.fn.fnamemodify(vim.fn.expand('%'), ':t:r')
  return pkgname .. '.' .. classname
end


return M
