local M = {}

local is_windows = vim.loop.os_uname().version:match('Windows')

M.sep = is_windows and '\\' or '/'

if is_windows then
  M.is_fs_root = function(path)
    return path:match('^%a:$')
  end
else
  M.is_fs_root = function(path)
    return path == '/'
  end
end

function M.join(...)
  local result = table.concat(vim.tbl_flatten {...}, M.sep):gsub(M.sep .. '+', M.sep)
  return result
end

return M
