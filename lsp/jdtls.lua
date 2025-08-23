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
}
