local api = vim.api
local request = vim.lsp.buf_request
local M = {}


--- Takes a workspaceEdit and nils versions of textDocuments within the
--- documentChanges if the version is zero.
---
--- Workaround for https://github.com/eclipse/eclipse.jdt.ls/issues/1695
--- Will be removed once it is no longer necessary
function M._nil_version_if_zero(edit)
  if not edit or not edit.documentChanges then
    return edit
  end
  for _, change in pairs(edit.documentChanges) do
    local text_document = change.textDocument
    if text_document and text_document.version and text_document.version == 0 then
      text_document.version = nil
    end
  end
  return edit
end


function M.apply_workspace_edit(edit)
  return vim.lsp.util.apply_workspace_edit(M._nil_version_if_zero(edit))
end


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
    local match = line:match('package ([a-z\\.]+);')
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
