local api = vim.api
local request = vim.lsp.buf_request
local M = {}


function M.execute_command(command, callback)
  request(0, 'workspace/executeCommand', command, function(err, _, resp)
    if callback then
      callback(err, resp)
    elseif err then
      print("Could not execute code action: " .. err.message)
    end
  end)
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
