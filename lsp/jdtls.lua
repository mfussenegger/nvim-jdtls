return {
  root_markers = {".git", "gradlew", "mvnw"},
  cmd = {"jdtls"},
  filetypes = {"java"},
  init_options = {
    extendedClientCapabilities = require("jdtls.capabilities")
  },
  settings = {
    java = vim.empty_dict(),
  },
  on_attach = function (client, bufnr)
    return require("jdtls.setup")._on_attach(client, bufnr)
  end,
}
