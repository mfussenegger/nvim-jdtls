local M = {}

local is_windows = vim.loop.os_uname().version:match('Windows')

M.sep = is_windows and '\\' or '/'

function M.join(...)
  local result = table.concat(vim.tbl_flatten {...}, M.sep):gsub(M.sep .. '+', M.sep)
  return result
end

return M
