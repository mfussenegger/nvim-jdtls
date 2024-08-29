local util = require("jdtls.util")
local M = {}
M.M2E_SELECTED_PROFILES = "org.eclipse.m2e.core.selectedProfiles"

function M.update_settings(settings, bufnr)
  local params = {
    command = "java.project.updateSettings",
    arguments = {
      vim.uri_from_bufnr(bufnr),
      settings,
    },
  }
  return util.execute_command(params)
end

function M.get_settings(settings, callback, bufnr)
  local params = {
    command = "java.project.getSettings",
    arguments = {
      vim.uri_from_bufnr(bufnr),
      settings,
    },
  }
  return util.execute_command(params, callback)
end

function M.set_maven_active_profiles(active_profiles, bufnr)
  return M.update_settings({
    [M.M2E_SELECTED_PROFILES] = active_profiles,
  }, bufnr)
end

function M.show_maven_active_profiles(bufnr)
  return M.get_settings({
    M.M2E_SELECTED_PROFILES,
  }, function(err, resp)
    if err then
      print("Could not resolve maven active profiles: " .. vim.inspect(err))
    else
      local profiles = resp[M.M2E_SELECTED_PROFILES]
      if profiles then
        print("Active profiles: " .. profiles)
      else
        print("No active profiles")
      end
    end
  end, bufnr)
end
return M
