if vim.g.nvim_jdtls then
  return
end
vim.g.nvim_jdtls = 1

vim.api.nvim_create_user_command("JdtWipeDataAndRestart", function()
  require("jdtls.setup").wipe_data_and_restart()
end, {})

vim.api.nvim_create_user_command("JdtShowLogs", function()
  require("jdtls.setup").show_logs()
end, {})

local jdtls_handler_group = vim.api.nvim_create_augroup("JdtlsHandlers", { clear = true })

local function register_handlers()
  vim.api.nvim_clear_autocmds({ group = jdtls_handler_group })

  local function handle_class_file(path)
    local success, result = pcall(require("jdtls").open_classfile, path)
    if not success then
      return false
    end
    return result
  end

  local patterns = {
    "jdt://*",
    "*.class",
  }

  for _, pattern in ipairs(patterns) do
    vim.api.nvim_create_autocmd("BufReadCmd", {
      pattern = pattern,
      group = jdtls_handler_group,
      callback = function()
        local path = vim.fn.expand("<amatch>")
        return handle_class_file(path)
      end,
    })
  end
end

local filetype_group = vim.api.nvim_create_augroup("JavaFiletypeHandlers", { clear = true })
vim.api.nvim_create_autocmd("FileType", {
  pattern = "java",
  group = filetype_group,
  callback = function()
    register_handlers()
  end,
})

if vim.bo.filetype == "java" then
  register_handlers()
end
