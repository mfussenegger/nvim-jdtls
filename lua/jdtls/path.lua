local M = {}

local is_windows = vim.loop.os_uname().version:match('Windows')

M.sep = is_windows and '\\' or '/'

function M.join(...)
  if vim.fs.joinpath then
    return vim.fs.joinpath(...)
  end
  local result = table.concat(vim.tbl_flatten {...}, M.sep):gsub(M.sep .. '+', M.sep)
  return result
end

return M
