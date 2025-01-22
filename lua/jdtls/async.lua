local M = {}


--- Runs the given function in a coroutine, shows uncaught errors using vim.notify
---
---@param fn function
function M.run(fn)
  local co, is_main = coroutine.running()
  if co and not is_main then
    fn()
  else
    coroutine.wrap(function()
      xpcall(fn, function(err)
        local msg = debug.traceback(err, 2)
        vim.notify(msg, vim.log.levels.ERROR)
      end)
    end)()
  end
end


return M
