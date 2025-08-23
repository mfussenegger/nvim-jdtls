if vim.g.nvim_jdtls then
  return
end
vim.g.nvim_jdtls = 1

local api = vim.api
local group = api.nvim_create_augroup("jdtls", {})
for _, pattern in ipairs({"jdt://", "*.class"}) do
  api.nvim_create_autocmd("BufReadCmd", {
    group = group,
    pattern = pattern,
    ---@param args vim.api.keyset.create_autocmd.callback_args
    callback = function (args)
      require('jdtls').open_classfile(vim.fn.expand(args.match))
    end
  })
end
api.nvim_create_user_command("JdtWipeDataAndRestart", function ()
  require('jdtls.setup').wipe_data_and_restart()
end, {})
api.nvim_create_user_command("JdtShowLogs", function ()
  require('jdtls.setup').show_logs()
end, {})
