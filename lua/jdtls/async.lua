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


--- Create a callback function that resumes the given coroutine
--- or the coroutine that was running when called
---
---@param co thread?
function M.resumecb(co)
  if not co then
    local current_co, is_main = coroutine.running()
    assert(current_co and not is_main, "resumecb must be called within a coroutine")
    co = current_co
  end
  return function(...)
    if coroutine.status(co) == "suspended" then
      coroutine.resume(co, ...)
    else
      local args = {...}
      vim.schedule(function()
        assert(
          coroutine.status(co) == "suspended",
          "Illegal use of resumecb(), Callee must have yielded")
        coroutine.resume(co, unpack(args))
      end)
    end
  end
end


return M
