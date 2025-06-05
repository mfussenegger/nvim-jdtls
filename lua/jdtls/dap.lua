---@mod jdtls.dap nvim-dap support for jdtls

local api = vim.api
local uv = vim.loop
local util = require("jdtls.util")
local resolve_classname = util.resolve_classname
local with_java_executable = util.with_java_executable
local M = {}
local default_config_overrides = {}

local function fetch_needs_preview(mainclass, project, cb, bufnr)
  local params = {
    command = "vscode.java.checkProjectSettings",
    arguments = vim.fn.json_encode({
      className = mainclass,
      projectName = project,
      inheritedOptions = true,
      expectedOptions = { ["org.eclipse.jdt.core.compiler.problem.enablePreviewFeatures"] = "enabled" },
    }),
  }
  util.execute_command(params, function(err, use_preview)
    assert(not err, err and (err.message or vim.inspect(err)))
    cb(use_preview)
  end, bufnr)
end

local function enrich_dap_config(config_, on_config)
  if
    config_.mainClass
    and config_.projectName
    and config_.modulePaths ~= nil
    and config_.classPaths ~= nil
    and config_.javaExec
  then
    on_config(config_)
    return
  end
  local config = vim.deepcopy(config_)
  if not config.mainClass then
    config.mainClass = resolve_classname()
  end
  local bufnr = api.nvim_get_current_buf()
  util.execute_command({ command = "vscode.java.resolveMainClass" }, function(err, mainclasses)
    assert(not err, err and (err.message or vim.inspect(err)))

    if not config.projectName then
      if not mainclasses then
        local msg = "Could not resolve classpaths. Project may have compile errors or unresolved dependencies"
        vim.notify(msg, vim.log.levels.WARN)
      else
        for _, entry in ipairs(mainclasses) do
          if entry.mainClass == config.mainClass then
            config.projectName = entry.projectName
            break
          end
        end
      end
    end
    config.projectName = config.projectName or ""
    with_java_executable(config.mainClass, config.projectName, function(java_exec)
      config.javaExec = config.javaExec or java_exec
      local params = {
        command = "vscode.java.resolveClasspath",
        arguments = { config.mainClass, config.projectName },
      }
      util.execute_command(params, function(err1, paths)
        assert(not err1, err1 and (err1.message or vim.inspect(err1)))
        if paths then
          config.modulePaths = config.modulePaths or paths[1]
          config.classPaths = config.classPaths
            or vim.tbl_filter(function(x)
              return vim.fn.isdirectory(x) == 1 or vim.fn.filereadable(x) == 1
            end, paths[2])
        else
          vim.notify(
            "Could not resolve classpaths. Project may have compile errors or unresolved dependencies",
            vim.log.levels.WARN
          )
        end
        on_config(config)
      end, bufnr)
    end, bufnr)
  end, bufnr)
end

local function start_debug_adapter(callback, config)
  -- User could trigger debug session for another project, open in another buffer
  local jdtls = vim.tbl_filter(function(client)
    return client.name == "jdtls" and client.config and client.config.root_dir == config.cwd
  end, util.get_clients())[1]
  local bufnr = vim.lsp.get_buffers_by_client_id(jdtls and jdtls.id)[1] or vim.api.nvim_get_current_buf()
  util.execute_command({ command = "vscode.java.startDebugSession" }, function(err0, port)
    assert(not err0, vim.inspect(err0))

    callback({
      type = "server",
      host = "127.0.0.1",
      port = port,
      enrich_config = enrich_dap_config,
    })
  end, bufnr)
end

local TestKind = {
  None = -1,
  JUnit = 0,
  JUnit5 = 1,
  TestNG = 2,
}

local LegacyTestLevel = {
  Root = 0,
  Folder = 1,
  Package = 2,
  Class = 3,
  Method = 4,
}

local TestLevel = {
  Workspace = 1,
  WorkspaceFolder = 2,
  Project = 3,
  Package = 4,
  Class = 5,
  Method = 6,
}

local function make_request_args(lens, uri)
  local methodname = ""
  local name_parts = vim.split(lens.fullName, "#")
  local classname = name_parts[1]
  if #name_parts > 1 then
    methodname = name_parts[2]
    if lens.paramTypes and #lens.paramTypes > 0 then
      methodname = string.format("%s(%s)", methodname, table.concat(lens.paramTypes, ","))
    end
  end
  -- Format changes with https://github.com/microsoft/vscode-java-test/pull/1257
  local new_api = lens.testKind ~= nil
  local req_arguments
  if new_api then
    req_arguments = {
      testKind = lens.testKind,
      projectName = lens.projectName,
      testLevel = lens.testLevel,
    }
    if lens.testKind == TestKind.TestNG or lens.testLevel == TestLevel.Class then
      req_arguments.testNames = { lens.fullName }
    elseif lens.testLevel then
      req_arguments.testNames = { lens.jdtHandler }
    end
  else
    req_arguments = {
      uri = uri,
      -- Got renamed to fullName in https://github.com/microsoft/vscode-java-test/commit/57191b5367ae0a357b80e94f0def9e46f5e77796
      -- Include both for BWC
      classFullName = classname,
      fullName = classname,
      testName = methodname,
      project = lens.project,
      projectName = lens.project,
      scope = lens.level,
      testKind = lens.kind,
    }
    if lens.level == LegacyTestLevel.Method then
      req_arguments["start"] = lens.location.range["start"]
      req_arguments["end"] = lens.location.range["end"]
    end
  end
  return req_arguments
end

local function fetch_candidates(context, on_candidates)
  local cmd_codelens = "vscode.java.test.search.codelens"
  local cmd_find_tests = "vscode.java.test.findTestTypesAndMethods"
  local client = nil
  local params = {
    arguments = { context.uri },
  }
  local clients = util.get_clients({ bufnr = context.bufnr })
  if not next(clients) then
    clients = util.get_clients({ name = "jdtls" })
  end
  for _, c in ipairs(clients) do
    local command_provider = c.server_capabilities.executeCommandProvider
    local commands = type(command_provider) == "table" and command_provider.commands or {}
    if vim.tbl_contains(commands, cmd_codelens) then
      params.command = cmd_codelens
      client = c
      break
    elseif vim.tbl_contains(commands, cmd_find_tests) then
      params.command = cmd_find_tests
      client = c
      break
    end
  end
  if not client then
    local msg = (
      "No LSP client found that supports resolving possible test cases. "
      .. "Did you add the JAR files of vscode-java-test to `config.init_options.bundles`?"
    )
    vim.notify(msg, vim.log.levels.WARN)
    return
  end

  local handler = function(err, result)
    if err then
      vim.notify("Error fetching test candidates: " .. (err.message or vim.inspect(err)), vim.log.levels.ERROR)
    else
      on_candidates(result or {})
    end
  end
  client:request("workspace/executeCommand", params, handler, context.bufnr)
end

local function merge_unique(xs, ys)
  local result = {}
  local seen = {}
  local both = {}
  vim.list_extend(both, xs or {})
  vim.list_extend(both, ys or {})

  for _, x in pairs(both) do
    if not seen[x] then
      table.insert(result, x)
      seen[x] = true
    end
  end

  return result
end

local function fetch_launch_args(lens, context, on_launch_args)
  local req_arguments = make_request_args(lens, context.uri)
  local cmd_junit_args = {
    command = "vscode.java.test.junit.argument",
    arguments = { vim.fn.json_encode(req_arguments) },
  }
  util.execute_command(cmd_junit_args, function(err, launch_args)
    if err then
      print("Error retrieving launch arguments: " .. (err.message or vim.inspect(err)))
    elseif not launch_args then
      error(
        (
          'Server must return launch_args as response to "vscode.java.test.junit.argument" command. '
          .. "Check server logs via `:JdtShowlogs`. Sent: "
          .. vim.inspect(req_arguments)
        )
      )
    elseif launch_args.errorMessage then
      vim.notify(launch_args.errorMessage, vim.log.levels.WARN)
    else
      -- forward/backward compat with format change in
      -- https://github.com/microsoft/vscode-java-test/commit/5a78371ad60e86f858eace7726f0980926b6c31d
      if launch_args.body then
        launch_args = launch_args.body
      end

      -- the classpath in the launch_args might be missing some classes
      -- See https://github.com/microsoft/vscode-java-test/issues/1073
      --
      -- That is why `java.project.getClasspaths` is used as well.
      local options = vim.fn.json_encode({ scope = "test" })
      local cmd = {
        command = "java.project.getClasspaths",
        arguments = { vim.uri_from_bufnr(context.bufnr), options },
      }
      util.execute_command(cmd, function(err1, resp)
        if err1 then
          local msg =
            string.format("%s bufnr=%d fname=%s", err1.message, context.bufnr, api.nvim_buf_get_name(context.bufnr))
          error(msg)
        end
        launch_args.classpath = merge_unique(launch_args.classpath, resp.classpaths)
        on_launch_args(launch_args)
      end, context.bufnr)
    end
  end, context.bufnr)
end

local function get_method_lens_above_cursor(lenses_tree, lnum)
  local result = {
    best_match = nil,
  }
  local find_nearest
  find_nearest = function(lenses)
    for _, lens in pairs(lenses) do
      local is_method = lens.level == LegacyTestLevel.Method or lens.testLevel == TestLevel.Method
      local range = lens.location and lens.location.range or lens.range
      local line = range.start.line
      local best_match_line
      if result.best_match then
        local best_match = assert(result.best_match)
        best_match_line = best_match.location and best_match.location.range.start.line or best_match.range.start.line
      end
      if is_method and line <= lnum and (best_match_line == nil or line > best_match_line) then
        result.best_match = lens
      end
      if lens.children then
        find_nearest(lens.children)
      end
    end
  end
  find_nearest(lenses_tree)
  return result.best_match
end

local function get_first_class_lens(lenses)
  for _, lens in pairs(lenses) do
    -- compatibility for versions prior to
    -- https://github.com/microsoft/vscode-java-test/pull/1257
    if lens.level == LegacyTestLevel.Class then
      return lens
    end
    if lens.testLevel == TestLevel.Class then
      return lens
    end
  end
end

--- Return path to com.microsoft.java.test.runner-jar-with-dependencies.jar if found in bundles
---
---@return string? path
local function testng_runner()
  local vscode_runner = "com.microsoft.java.test.runner-jar-with-dependencies.jar"
  local client = util.get_clients({ name = "jdtls" })[1]
  local bundles = client and client.config.init_options.bundles or {}
  for _, jar_path in pairs(bundles) do
    local parts = vim.split(jar_path, "/")
    if parts[#parts] == vscode_runner then
      return jar_path
    end
    local basepath = vim.fs.dirname(jar_path)
    if basepath then
      for name, _ in vim.fs.dir(basepath) do
        if name == vscode_runner then
          return vim.fs.joinpath(basepath, name)
        end
      end
    end
  end
  return nil
end

local function make_config(lens, launch_args, config_overrides)
  local config = {
    name = lens.fullName,
    type = "java",
    request = "launch",
    mainClass = launch_args.mainClass,
    projectName = launch_args.projectName,
    cwd = launch_args.workingDirectory,
    classPaths = launch_args.classpath,
    modulePaths = launch_args.modulepath,
    vmArgs = table.concat(launch_args.vmArguments, " "),
    noDebug = false,
  }
  config = vim.tbl_extend("force", config, config_overrides or default_config_overrides)
  if lens.testKind == TestKind.TestNG or lens.kind == TestKind.TestNG then
    local jar = testng_runner()
    if jar then
      config.mainClass = "com.microsoft.java.test.runner.Launcher"
      config.args = string.format("testng %s", lens.fullName)
      table.insert(config.classPaths, jar)
    else
      local msg = (
        "Using basic TestNG integration. "
        .. "For better test results add com.microsoft.java.test.runner-jar-with-dependencies.jar to one of the `bundles` folders"
      )
      vim.notify(msg)
      config.mainClass = "org.testng.TestNG"
      -- id is in the format <project>@<class>#<method>
      local parts = vim.split(lens.id, "@")
      parts = vim.split(parts[2], "#")
      if #parts > 1 then
        config.args = string.format("-testclass %s -methods %s.%s", parts[1], parts[1], parts[2])
      else
        config.args = string.format("-testclass %s", parts[1])
      end
    end
  else
    config.args = table.concat(launch_args.programArguments, " ")
  end
  return config
end

---@param bufnr? integer
---@return JdtDapContext
local function make_context(bufnr)
  bufnr = assert((bufnr == nil or bufnr == 0) and api.nvim_get_current_buf() or bufnr)
  return {
    bufnr = bufnr,
    uri = vim.uri_from_bufnr(bufnr),
  }
end

local function maybe_repeat(lens, config, context, opts, items)
  if not opts.until_error then
    return
  end
  if opts.until_error > 0 and #items == 0 then
    print("`until_error` set and no tests failed. Repeating.", opts.until_error)
    opts.until_error = opts.until_error - 1
    local repeat_test = function()
      M.experimental.run(lens, config, context, opts)
    end
    vim.defer_fn(repeat_test, 2000)
  elseif opts.until_error <= 0 then
    print("Stopping repeat, `until_error` reached", opts.until_error)
  end
end

---@param opts JdtTestOpts
local function run(lens, config, context, opts)
  local ok, dap = pcall(require, "dap")
  if not ok then
    vim.notify("`nvim-dap` must be installed to run and debug methods")
    return
  end
  config = vim.tbl_extend("force", config, opts.config or {})
  local test_results
  local server = nil

  if lens.kind == TestKind.TestNG or lens.testKind == TestKind.TestNG then
    local testng = require("jdtls.testng")
    local run_opts = {}
    if config.mainClass == "com.microsoft.java.test.runner.Launcher" then
      function run_opts.before(conf)
        server = assert(uv.new_tcp(), "uv.new_tcp() must return handle")
        test_results = opts.test_results or testng.mk_test_results(context.bufnr)
        server:bind("127.0.0.1", 0)
        server:listen(128, function(err2)
          assert(not err2, err2)
          local sock = assert(vim.loop.new_tcp(), "uv.new_tcp must return handle")
          server:accept(sock)
          sock:read_start(test_results.mk_reader(sock))
        end)
        conf.args = string.format("%s %s", server:getsockname().port, conf.args)
        return conf
      end

      function run_opts.after()
        if server then
          server:shutdown()
          server:close()
        end
        -- Add delay to ensure all test output is processed
        vim.defer_fn(function()
          if not opts.test_results then
            test_results.show(lens, context)
          end
          if opts.after_test then
            opts.after_test()
          end
        end, 100)
      end
    else
      function run_opts.after()
        if opts.after_test then
          opts.after_test()
        end
      end
    end
    dap.run(config, run_opts)
    return
  end

  local junit = require("jdtls.junit")
  dap.run(config, {
    before = function(conf)
      server = assert(uv.new_tcp(), "uv.new_tcp() must return handle")
      test_results = opts.test_results or junit.mk_test_results(context.bufnr)
      server:bind("127.0.0.1", 0)
      server:listen(128, function(err2)
        assert(not err2, err2)
        local sock = assert(vim.loop.new_tcp(), "uv.new_tcp must return handle")
        server:accept(sock)
        sock:read_start(test_results.mk_reader(sock))
      end)
      conf.args = conf.args:gsub("-port ([0-9]+)", "-port " .. server:getsockname().port)
      return conf
    end,
    after = function()
      if server then
        server:shutdown()
        server:close()
      end

      -- Add delay to ensure all test output is processed before showing results
      vim.defer_fn(function()
        local items, tests
        if not opts.test_results then
          items, tests = test_results.show(lens)
          maybe_repeat(lens, config, context, opts, items)
        end

        if opts.after_test then
          opts.after_test(items, tests)
        end
      end, 100)
    end,
  })
end

--- API of these methods is unstable and might change in the future
M.experimental = {
  run = run,
  fetch_lenses = fetch_candidates,
  fetch_launch_args = fetch_launch_args,
  make_context = make_context,
  make_config = make_config,
}

--- Debug the test class in the current buffer
--- @param opts JdtTestOpts|nil
function M.test_class(opts)
  opts = opts or {}
  local context = make_context(opts.bufnr)
  fetch_candidates(context, function(lenses)
    local lens = get_first_class_lens(lenses)
    if not lens then
      vim.notify("No test class found")
      return
    end
    fetch_launch_args(lens, context, function(launch_args)
      local config = make_config(lens, launch_args, opts.config_overrides)
      run(lens, config, context, opts)
    end)
  end)
end

--- Debug the nearest test method in the current buffer
--- @param opts nil|JdtTestOpts
function M.test_nearest_method(opts)
  opts = opts or {}
  local context = make_context(opts.bufnr)
  local lnum = opts.lnum or api.nvim_win_get_cursor(0)[1]
  fetch_candidates(context, function(lenses)
    local lens = get_method_lens_above_cursor(lenses, lnum)
    if not lens then
      vim.notify("No suitable test method found")
      return
    end
    fetch_launch_args(lens, context, function(launch_args)
      local config = make_config(lens, launch_args, opts.config_overrides)
      run(lens, config, context, opts)
    end)
  end)
end

local function populate_candidates(list, lenses)
  for _, v in pairs(lenses) do
    table.insert(list, v)
    if v.children ~= nil then
      populate_candidates(list, v.children)
    end
  end
end

--- Prompt for a test method from the current buffer to run
---@param opts nil|JdtTestOpts
function M.pick_test(opts)
  opts = opts or {}
  local context = make_context(opts.bufnr)

  fetch_candidates(context, function(lenses)
    local candidates = {}
    populate_candidates(candidates, lenses)

    require("jdtls.ui").pick_one_async(candidates, "Tests> ", function(lens)
      return lens.fullName
    end, function(lens)
      if not lens then
        return
      end
      fetch_launch_args(lens, context, function(launch_args)
        local config = make_config(lens, launch_args, opts.config_overrides)
        run(lens, config, context, opts)
      end)
    end)
  end)
end

local hotcodereplace_type = {
  ERROR = "ERROR",
  WARNING = "WARNING",
  STARTING = "STARTING",
  END = "END",
  BUILD_COMPLETE = "BUILD_COMPLETE",
}

--- Discover executable main functions in the project
---@param opts nil|JdtMainConfigOpts See |JdtMainConfigOpts|
---@param callback fun(configurations: table[])
function M.fetch_main_configs(opts, callback)
  opts = opts or {}
  if type(opts) == "function" then
    vim.notify("First argument to `fetch_main_configs` changed to a `opts` table", vim.log.levels.WARN)
    callback = opts
    opts = {}
  end
  local configurations = {}
  local bufnr = api.nvim_get_current_buf()
  local jdtls = util.get_clients({ bufnr = bufnr, name = "jdtls" })[1]
  local root_dir = jdtls and jdtls.config and jdtls.config.root_dir
  util.execute_command({ command = "vscode.java.resolveMainClass" }, function(err, mainclasses)
    assert(not err, vim.inspect(err))

    local remaining = #mainclasses
    if remaining == 0 then
      callback(configurations)
      return
    end
    for _, mc in pairs(mainclasses) do
      local mainclass = mc.mainClass
      local project = mc.projectName
      with_java_executable(mainclass, project, function(java_exec)
        fetch_needs_preview(mainclass, project, function(use_preview)
          util.execute_command(
            { command = "vscode.java.resolveClasspath", arguments = { mainclass, project } },
            function(err1, paths)
              remaining = remaining - 1
              if err1 then
                print(
                  string.format(
                    "Could not resolve classpath and modulepath for %s/%s: %s",
                    project,
                    mainclass,
                    err1.message
                  )
                )
                return
              end
              local config = {
                cwd = root_dir,
                type = "java",
                name = "Launch " .. (project or "") .. ": " .. mainclass,
                projectName = project,
                mainClass = mainclass,
                modulePaths = paths[1],
                classPaths = paths[2],
                javaExec = java_exec,
                request = "launch",
                console = "integratedTerminal",
                vmArgs = use_preview and "--enable-preview" or nil,
              }
              config = vim.tbl_extend("force", config, opts.config_overrides or default_config_overrides)
              table.insert(configurations, config)
              if remaining == 0 then
                callback(configurations)
              end
            end,
            bufnr
          )
        end, bufnr)
      end, bufnr)
    end
  end, bufnr)
end

---@class JdtMainConfigOpts
---@field config_overrides nil|JdtDapConfig Overrides for the |dap-configuration|, see |JdtDapConfig|

--- Discover main classes in the project and setup |dap-configuration| entries for Java for them.
---@param opts nil|JdtSetupMainConfigOpts See |JdtSetupMainConfigOpts|
function M.setup_dap_main_class_configs(opts)
  opts = opts or {}
  local status, dap = pcall(require, "dap")
  if not status then
    print("nvim-dap is not available")
    return
  end
  if dap.providers and dap.providers.configs then
    -- If users call this manually disable the automatic discovery on dap.continue()
    dap.providers.configs["jdtls"] = nil
  end
  if opts.verbose then
    vim.notify("Fetching debug configurations")
  end
  local on_ready = opts.on_ready or function() end
  M.fetch_main_configs(opts, function(configurations)
    local dap_configurations = dap.configurations.java or {}
    for _, config in ipairs(configurations) do
      for i, existing_config in pairs(dap_configurations) do
        if config.name == existing_config.name and config.cwd == existing_config["cwd"] then
          table.remove(dap_configurations, i)
        end
      end
      table.insert(dap_configurations, config)
    end
    dap.configurations.java = dap_configurations
    if opts.verbose then
      vim.notify(string.format("Updated %s debug configuration(s)", #configurations))
    end
    on_ready()
  end)
end

---@class JdtSetupMainConfigOpts : JdtMainConfigOpts
---@field verbose nil|boolean Print notifications on start and once finished. Default is false.
---@field on_ready nil|function Callback called when the configurations got updated

--- Register a |dap-adapter| for java. Requires nvim-dap
---@param opts nil|JdtSetupDapOpts See |JdtSetupDapOpts|
function M.setup_dap(opts)
  local status, dap = pcall(require, "dap")
  if not status then
    print("nvim-dap is not available")
    return
  end
  if dap.adapters.java then
    return
  end
  opts = opts or {}
  default_config_overrides = opts.config_overrides or {}

  -- Silence warnings for custom events from java-debug
  dap.listeners.before["event_processid"]["jdtls"] = function() end
  dap.listeners.before["event_telemetry"]["jdtls"] = function() end

  dap.listeners.before["event_hotcodereplace"]["jdtls"] = function(session, body)
    if body.changeType == hotcodereplace_type.BUILD_COMPLETE then
      if opts.hotcodereplace == "auto" then
        vim.notify("Applying code changes")
        session:request("redefineClasses", nil, function(err)
          assert(not err, vim.inspect(err))
        end)
      end
    elseif body.message then
      vim.notify(body.message)
    end
  end
  dap.adapters.java = start_debug_adapter

  if dap.providers and dap.providers.configs then
    dap.providers.configs["jdtls"] = function(bufnr)
      if vim.bo[bufnr].filetype ~= "java" then
        return {}
      end
      local co = coroutine.running()
      local resumed = false
      vim.defer_fn(function()
        if not resumed then
          resumed = true
          coroutine.resume(co, {})
          vim.schedule(function()
            vim.notify("Discovering main classes took too long", vim.log.levels.INFO)
          end)
        end
      end, 2000)
      M.fetch_main_configs(nil, function(configs)
        if not resumed then
          resumed = true
          coroutine.resume(co, configs)
        end
      end)
      return coroutine.yield()
    end
  end
end
---@class JdtSetupDapOpts
---@field config_overrides JdtDapConfig These will be used as default overrides for |jdtls.dap.test_class|, |jdtls.dap.test_nearest_method| and discovered main classes
---@field hotcodereplace? string "auto"

---@class JdtDapContext
---@field bufnr number
---@field win number
---@field uri string uri equal to vim.uri_from_bufnr(bufnr)

---@class JdtDapConfig
---@field cwd string|nil working directory for the test
---@field vmArgs string|nil vmArgs for the test
---@field noDebug boolean|nil If the test should run in debug mode

---@class JdtTestOpts
---@field config nil|table Skeleton used for the |dap-configuration|
---@field config_overrides nil|JdtDapConfig Overrides for the |dap-configuration|, see |JdtDapConfig|
---@field until_error number|nil Number of times the test should be repeated if it doesn't fail
---@field after_test nil|function Callback triggered after test run
---@field bufnr? number Buffer that contains the test
---@field lnum? number 1-indexed line number. Used to find nearest test. Defaults to cursor position of the current window.

function M.pick_test_package(opts)
  opts = opts or {}
  local util = require("jdtls.util")
  local ui = require("jdtls.ui")
  local context = make_context(opts.bufnr)
  local bufnr = context.bufnr
  local current_path = vim.fs.dirname(vim.api.nvim_buf_get_name(bufnr))

  local jdtls_client = util.get_clients({ bufnr = bufnr, name = "jdtls" })[1]
  local root_dir = jdtls_client and jdtls_client.config.root_dir or nil
  if not root_dir then
    vim.notify("Could not detect project root.")
    return
  end

  -- Find all Java files in the project
  local java_files = vim.fn.glob(root_dir .. "/**/src/test/java/**/*.java", true, true)
  if vim.tbl_isempty(java_files) then
    vim.notify("No Java test files found in project.")
    return
  end

  -- Build package hierarchy from Java files
  local packages = {}
  local package_to_files = {}

  for _, file in ipairs(java_files) do
    -- Extract package from file path
    local java_src_pattern = ".*/src/.*/java/(.*)/[^/]+%.java$"
    local package_path = file:match(java_src_pattern)

    if package_path then
      local package_name = package_path:gsub("/", ".")

      -- Build all parent packages
      local parts = vim.split(package_name, ".", { plain = true })
      for i = 1, #parts do
        local partial_package = table.concat(parts, ".", 1, i)
        if not packages[partial_package] then
          packages[partial_package] = true
          package_to_files[partial_package] = {}
        end

        -- Only add files to their exact package
        if i == #parts then
          table.insert(package_to_files[partial_package], file)
        end
      end
    end
  end

  -- Convert to sorted list
  local package_list = vim.tbl_keys(packages)
  table.sort(package_list)

  -- Filter to only show packages that contain the current file's package or are parent packages
  local current_file = vim.api.nvim_buf_get_name(bufnr)
  local current_package = ""
  local java_src_pattern = ".*/src/.*/java/(.*)/[^/]+%.java$"
  local current_package_path = current_file:match(java_src_pattern)
  if current_package_path then
    current_package = current_package_path:gsub("/", ".")
  end

  -- Filter packages to show current package and its parents
  local filtered_packages = {}
  for _, pkg in ipairs(package_list) do
    if current_package:find("^" .. vim.pesc(pkg)) or pkg:find("^" .. vim.pesc(current_package)) then
      table.insert(filtered_packages, pkg)
    end
  end

  -- If no filtered packages, show all
  if #filtered_packages == 0 then
    filtered_packages = package_list
  end

  ui.pick_one_async(filtered_packages, "Pick package to test:", function(pkg)
    return pkg
  end, function(selected_package)
    if not selected_package then
      return
    end

    -- Find all files in the selected package and its subpackages
    local files_to_test = {}
    for pkg, files in pairs(package_to_files) do
      if pkg:find("^" .. vim.pesc(selected_package)) then
        vim.list_extend(files_to_test, files)
      end
    end

    if vim.tbl_isempty(files_to_test) then
      vim.notify("No Java files found in selected package.")
      return
    end

    local class_lenses = {}
    local class_to_file_map = {}
    local processed = 0
    local total_files = #files_to_test

    for _, file in ipairs(files_to_test) do
      local file_uri = vim.uri_from_fname(file)
      util.execute_command(
        { command = "vscode.java.test.findTestTypesAndMethods", arguments = { file_uri } },
        function(_, items)
          local function find_class_lenses(items_list)
            for _, lens in ipairs(items_list or {}) do
              if lens.level == LegacyTestLevel.Class or lens.testLevel == TestLevel.Class then
                local className = lens.fullName or lens.classFullName or ""
                if className ~= "" and not class_lenses[className] then
                  lens.uri = file_uri
                  class_lenses[className] = { lens = lens, file = file }
                  class_to_file_map[className] = file
                end
              end
              if lens.children then
                find_class_lenses(lens.children)
              end
            end
          end
          find_class_lenses(items)
          processed = processed + 1
          if processed == total_files then
            local class_lens_list = vim.tbl_values(class_lenses)
            if #class_lens_list == 0 then
              vim.notify("No test classes found in selected package.")
              return
            end

            -- Rest of the function remains the same...
            local junit = require("jdtls.junit")
            local shared_tests = {}
            local shared_results = junit.mk_test_results(bufnr, shared_tests, class_to_file_map)
            local completed_runs = 0
            local total_runs = #class_lens_list

            local function on_test_complete()
              completed_runs = completed_runs + 1
              if completed_runs == total_runs then
                vim.defer_fn(function()
                  local all_lenses = vim.tbl_map(function(item)
                    return item.lens
                  end, class_lens_list)
                  local final_items, final_tests = shared_results.show(all_lenses)
                  if #final_items > 0 then
                    vim.cmd("copen")
                  end
                end, 200)
              end
            end

            local current_index = 1
            local function run_next_test()
              if current_index > #class_lens_list then
                return
              end
              local lens_info = class_lens_list[current_index]
              local lens = lens_info.lens
              local file = lens_info.file
              local file_bufnr = vim.fn.bufnr(file, false)
              local ctx = make_context(file_bufnr ~= -1 and file_bufnr or bufnr)
              fetch_launch_args(lens, ctx, function(launch_args)
                local config = make_config(lens, launch_args, opts.config_overrides)
                local test_opts = vim.tbl_deep_extend("force", opts, {
                  test_results = shared_results,
                  after_test = function()
                    current_index = current_index + 1
                    on_test_complete()
                    if current_index <= #class_lens_list then
                      vim.defer_fn(run_next_test, 1000)
                    end
                  end,
                })
                run(lens, config, ctx, test_opts)
              end)
            end
            vim.notify(
              string.format("Starting tests for %d classes in package %s...", #class_lens_list, selected_package)
            )
            run_next_test()
          end
        end,
        bufnr
      )
    end
  end)
end

return M
