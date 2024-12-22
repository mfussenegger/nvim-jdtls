local M = {}
local async = require("jdtls.async")
local api = vim.api

---@class jdtls.coverage.CoverageResult
---@field lineCoverages jdtls.coverage.LineCoverage[]
---@field methodCoverages jdtls.coverage.MethodCoverage[]
---@field uriString string

---@class jdtls.coverage.LineCoverage
---@field branchCoverages table
---@field hit integer
---@field lineNumber integer

---@class jdtls.coverage.MethodCoverage
---@field hit integer
---@field lineNumber integer
---@field name string

---@param bufnr integer
---@param msg string|string[]
local function append(bufnr, msg)
  if type(msg) ~= "table" then
    msg = { msg }
  end
  api.nvim_buf_set_lines(bufnr, -1, -1, true, msg)
  vim.bo[bufnr].modified = false
end


local function create_impact_map()
  assert(coroutine.running(), "Must run in coroutine")
  ---@type vim.lsp.Client
  local client = assert(vim.lsp.get_clients({ name = "jdtls" })[1], "Must have jdtls client running")
  local win = api.nvim_get_current_win()
  local bufnr = api.nvim_get_current_buf()
  vim.cmd.new()
  local progressbuf = api.nvim_get_current_buf()
  api.nvim_buf_set_name(progressbuf, "jdtls-coverage-progress://" .. progressbuf)
  api.nvim_win_set_buf(win, bufnr)
  append(
    progressbuf,
    {
      "Starting coverage data generation. This may take some time.",
      "Deleting this buffer will interrupt the operation",
      ""
    }
  )
  local cmd_context = { bufnr = bufnr }

  local find_projects = {
    command = "vscode.java.test.findJavaProjects",
    arguments = { vim.uri_from_fname(client.config.root_dir) }
  }
  local resume = async.resumecb()
  client:exec_cmd(find_projects, cmd_context, resume)
  local err, projects = coroutine.yield()
  assert(not err, err)

  local coverage_map = {}
  for i, project in ipairs(projects or {}) do
    local find_tests = {
      command = "vscode.java.test.findTestPackagesAndTypes",
      arguments = { project.jdtHandler }
    }
    local tests
    client:exec_cmd(find_tests, cmd_context, resume)
    err, tests = coroutine.yield()
    if err then
      vim.notify(vim.inspect(err), vim.log.levels.ERROR)
    end
    assert(not err, err)

    local all_tests = {}
    for _, pkg in ipairs(tests) do
      for _, child in ipairs(pkg.children) do
        table.insert(all_tests, child)
      end
    end
    local msg = string.format("Found %d tests in %s. Generating coverage data ...", #all_tests, project.projectName)
    if i > 1 then
      append(progressbuf, "")
    end
    append(progressbuf, msg)


    ---@type lsp.Command
    local get_coverage = {
      title = "getCoverageDetail",
      command = "vscode.java.test.jacoco.getCoverageDetail",
      arguments = {
        project.projectName,
        "<unknown-basepath>", -- set below
      }
    }

    local coverage
    for _, test in ipairs(all_tests) do
      if not api.nvim_buf_is_valid(progressbuf) then
        vim.notify(
          "Progress monitoring buffer disappeared, aborting coverage data generation",
          vim.log.levels.WARN
        )
        return
      end

      append(progressbuf, "Running " .. test.fullName)
      local testbuf = vim.uri_to_bufnr(test.uri)
      vim.fn.bufload(testbuf)
      vim.lsp.buf_attach_client(testbuf, client.id)

      require("jdtls.dap").create_class_coverage({ bufnr = testbuf }, resume)
      local basepath = coroutine.yield()
      if basepath then
        get_coverage.arguments[2] = basepath .. "/target"

        client:exec_cmd(get_coverage, cmd_context, resume)
        err, coverage = coroutine.yield()
        if err then
          vim.notify(vim.inspect(err), vim.log.levels.ERROR)
        end

        assert(not err, err)
        ---@cast coverage jdtls.coverage.CoverageResult[]
        for _, cov in ipairs(assert(coverage)) do
          local uri = vim.uri_from_fname(cov.uriString:sub(#"file:/"))
          local covering_tests = coverage_map[uri]
          if not covering_tests then
            covering_tests = {}
            coverage_map[uri] = covering_tests
          end
          local total_hits = 0
          for _, method_cov in ipairs(cov.methodCoverages) do
            total_hits = total_hits + method_cov.hit
          end
          if total_hits > 0 then
            table.insert(covering_tests, test.uri)
          end
        end
      end
    end
  end

  append(progressbuf, "Coverage data generation finished")
  local coverage_json = vim.json.encode(coverage_map)
  local f = io.open("/tmp/coverage.json", "w+")
  if f then
    f:write(coverage_json)
    f:close()
  end
end


--- Creates coverage data and generates a map from covered files to test suites
---
--- This will run all test suites sequentially and can take a long time
function M.create_impact_map()
  async.run(create_impact_map)
end


function M.test_impacted()
end

function M.get_impacted()
  local f = io.open("/tmp/coverage.json", "r")
  if not f then
    error("no coverage data found")
  end
  local content = f:read("*a")
  local coverage = vim.json.decode(content)
  local result = vim.system({"git", "status", "--porcelain"}, { text = true }):wait()
  local impacted = {}
  for line in vim.gsplit(result.stdout, "\n", { plain = true }) do
    if vim.startswith(line, " M ") then
      line = line:sub(4)
    end
    local fname = line
    local uri = vim.uri_from_fname(vim.fn.fnamemodify(fname, ":p"))
    local impacted_tests = coverage[uri]
    if impacted_tests then
      for _, test in ipairs(impacted_tests) do
        local path = vim.fn.fnamemodify(vim.uri_to_fname(test), ":.")
        impacted[path] = true
      end
    end
  end
  return vim.tbl_keys(impacted)
end


return M
