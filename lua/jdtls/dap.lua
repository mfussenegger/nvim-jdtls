---@mod jdtls.dap nvim-dap support for jdtls

local api = vim.api
local uv = vim.loop
local util = require('jdtls.util')
local resolve_classname = util.resolve_classname
local with_java_executable = util.with_java_executable
local M = {}
local default_config_overrides = {}

---@diagnostic disable-next-line: deprecated
local get_clients = vim.lsp.get_clients or vim.lsp.get_active_clients

local function fetch_needs_preview(mainclass, project, cb, bufnr)
  local params = {
    command = 'vscode.java.checkProjectSettings',
    arguments = vim.fn.json_encode({
      className = mainclass,
      projectName = project,
      inheritedOptions = true,
      expectedOptions = { ['org.eclipse.jdt.core.compiler.problem.enablePreviewFeatures'] = 'enabled' }
    })
  }
  util.execute_command(params, function(err, use_preview)
    assert(not err, err and (err.message or vim.inspect(err)))
    cb(use_preview)
  end, bufnr)
end


local function enrich_dap_config(config_, on_config)
  if config_.mainClass
    and config_.projectName
    and config_.modulePaths ~= nil
    and config_.classPaths ~= nil
    and config_.javaExec then
    on_config(config_)
    return
  end
  local config = vim.deepcopy(config_)
  if not config.mainClass then
    config.mainClass = resolve_classname()
  end
  local bufnr = api.nvim_get_current_buf()
  util.execute_command({command = 'vscode.java.resolveMainClass'}, function(err, mainclasses)
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
    config.projectName = config.projectName or ''
    with_java_executable(config.mainClass, config.projectName, function(java_exec)
      config.javaExec = config.javaExec or java_exec
      local params = {
        command = 'vscode.java.resolveClasspath',
        arguments = { config.mainClass, config.projectName }
      }
      util.execute_command(params, function(err1, paths)
        assert(not err1, err1 and (err1.message or vim.inspect(err1)))
        if paths then
          config.modulePaths = config.modulePaths or paths[1]
          config.classPaths = config.classPaths or vim.tbl_filter(
            function(x)
              return vim.fn.isdirectory(x) == 1 or vim.fn.filereadable(x) == 1
            end,
            paths[2]
          )
        else
          vim.notify("Could not resolve classpaths. Project may have compile errors or unresolved dependencies", vim.log.levels.WARN)
        end
        on_config(config)
      end, bufnr)
    end, bufnr)
  end, bufnr)
end


local function start_debug_adapter(callback, config)
  -- User could trigger debug session for another project, open in another buffer
  local jdtls = vim.tbl_filter(function(client)
    return client.name == 'jdtls'
      and client.config
      and client.config.root_dir == config.cwd
  end, get_clients())[1]
  local bufnr = vim.lsp.get_buffers_by_client_id(jdtls and jdtls.id)[1] or vim.api.nvim_get_current_buf()
  util.execute_command({command = 'vscode.java.startDebugSession'}, function(err0, port)
    assert(not err0, vim.inspect(err0))

    callback({
      type = 'server';
      host = '127.0.0.1';
      port = port;
      enrich_config = enrich_dap_config;
    })
  end, bufnr)
end


local TestKind = {
  None = -1,
  JUnit = 0,
  JUnit5 = 1,
  TestNG = 2
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
  local methodname = ''
  local name_parts = vim.split(lens.fullName, '#')
  local classname = name_parts[1]
  if #name_parts > 1 then
    methodname = name_parts[2]
    if lens.paramTypes and #lens.paramTypes > 0 then
      methodname = string.format('%s(%s)', methodname, table.concat(lens.paramTypes, ','))
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
      req_arguments.testNames = { lens.fullName, }
    elseif lens.testLevel then
      req_arguments.testNames = { lens.jdtHandler, }
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
      req_arguments['start'] = lens.location.range['start']
      req_arguments['end'] = lens.location.range['end']
    end
  end
  return req_arguments
end


local function fetch_candidates(context, on_candidates)
  local cmd_codelens = 'vscode.java.test.search.codelens'
  local cmd_find_tests = 'vscode.java.test.findTestTypesAndMethods'
  local client = nil
  local params = {
    arguments = { context.uri };
  }
  for _, c in ipairs(get_clients({ bufnr = context.bufnr })) do
    local command_provider = c.server_capabilities.executeCommandProvider
    local commands = type(command_provider) == 'table' and command_provider.commands or {}
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
      'No LSP client found that supports resolving possible test cases. '
        .. 'Did you add the JAR files of vscode-java-test to `config.init_options.bundles`?')
    vim.notify(msg, vim.log.levels.WARN)
    return
  end

  local handler = function(err, result)
    if err then
      vim.notify('Error fetching test candidates: ' .. (err.message or vim.inspect(err)), vim.log.levels.ERROR)
    else
      on_candidates(result or {})
    end
  end
  client.request('workspace/executeCommand', params, handler, context.bufnr)
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
    command = 'vscode.java.test.junit.argument';
    arguments = { vim.fn.json_encode(req_arguments) };
  }
  util.execute_command(cmd_junit_args, function(err, launch_args)
    if err then
      print('Error retrieving launch arguments: ' .. (err.message or vim.inspect(err)))
    elseif not launch_args then
      error((
        'Server must return launch_args as response to "vscode.java.test.junit.argument" command. '
        .. 'Check server logs via `:JdtShowlogs`. Sent: ' .. vim.inspect(req_arguments)))
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
      local options = vim.fn.json_encode({ scope = 'test'; })
      local cmd = {
        command = 'java.project.getClasspaths';
        arguments = { vim.uri_from_bufnr(0), options };
      }
      util.execute_command(cmd, function(err1, resp)
        assert(not err1, vim.inspect(err1))
        launch_args.classpath = merge_unique(launch_args.classpath, resp.classpaths)
        on_launch_args(launch_args)
      end, context.bufnr)
    end
  end, context.bufnr)
end


local function get_method_lens_above_cursor(lenses_tree, lnum)
  local result = {
    best_match = nil
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
  local vscode_runner = 'com.microsoft.java.test.runner-jar-with-dependencies.jar'
  local client = get_clients({name='jdtls'})[1]
  local bundles = client and client.config.init_options.bundles or {}
  for _, jar_path in pairs(bundles) do
    local parts = vim.split(jar_path, '/')
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
    name = lens.fullName;
    type = 'java';
    request = 'launch';
    mainClass = launch_args.mainClass;
    projectName = launch_args.projectName;
    cwd = launch_args.workingDirectory;
    classPaths = launch_args.classpath;
    modulePaths = launch_args.modulepath;
    vmArgs = table.concat(launch_args.vmArguments, ' ');
    noDebug = false;
  }
  config = vim.tbl_extend('force', config, config_overrides or default_config_overrides)
  if lens.testKind == TestKind.TestNG or lens.kind == TestKind.TestNG then
    local jar = testng_runner()
    if jar then
      config.mainClass = 'com.microsoft.java.test.runner.Launcher'
      config.args = string.format('testng %s', lens.fullName)
      table.insert(config.classPaths, jar);
    else
      local msg = (
        "Using basic TestNG integration. "
        .. "For better test results add com.microsoft.java.test.runner-jar-with-dependencies.jar to one of the `bundles` folders")
      vim.notify(msg)
      config.mainClass = 'org.testng.TestNG'
      -- id is in the format <project>@<class>#<method>
      local parts = vim.split(lens.id, '@')
      parts  = vim.split(parts[2], '#')
      if #parts > 1 then
        config.args = string.format('-testclass %s -methods %s.%s', parts[1], parts[1], parts[2])
      else
        config.args = string.format('-testclass %s', parts[1])
      end
    end
  else
    config.args = table.concat(launch_args.programArguments, ' ');
  end
  return config
end



---@param bufnr? integer
---@return JdtDapContext
local function make_context(bufnr)
  bufnr = assert((bufnr == nil or bufnr == 0) and api.nvim_get_current_buf() or bufnr)
  return {
    bufnr = bufnr,
    uri = vim.uri_from_bufnr(bufnr)
  }
end


local function maybe_repeat(lens, config, context, opts, items)
  if not opts.until_error then
    return
  end
  if opts.until_error > 0 and #items == 0 then
    print('`until_error` set and no tests failed. Repeating.', opts.until_error)
    opts.until_error = opts.until_error - 1
    local repeat_test = function()
      M.experimental.run(lens, config, context, opts)
    end
    vim.defer_fn(repeat_test, 2000)
  elseif opts.until_error <= 0 then
    print('Stopping repeat, `until_error` reached', opts.until_error)
  end
end


---@param opts JdtTestOpts
local function run(lens, config, context, opts)
  local ok, dap = pcall(require, 'dap')
  if not ok then
    vim.notify('`nvim-dap` must be installed to run and debug methods')
    return
  end
  config = vim.tbl_extend('force', config, opts.config or {})
  local test_results
  local server = nil

  if lens.kind == TestKind.TestNG or lens.testKind == TestKind.TestNG  then
    local testng = require('jdtls.testng')
    local run_opts = {}
    if config.mainClass == "com.microsoft.java.test.runner.Launcher" then
      function run_opts.before(conf)
        server = assert(uv.new_tcp(), "uv.new_tcp() must return handle")
        test_results = testng.mk_test_results(context.bufnr)
        server:bind('127.0.0.1', 0)
        server:listen(128, function(err2)
          assert(not err2, err2)
          local sock = assert(vim.loop.new_tcp(), "uv.new_tcp must return handle")
          server:accept(sock)
          sock:read_start(test_results.mk_reader(sock))
        end)
        conf.args = string.format('%s %s', server:getsockname().port, conf.args)
        return conf
      end

      function run_opts.after()
        if server then
          server:shutdown()
          server:close()
        end
        test_results.show(lens, context)
        if opts.after_test then
          opts.after_test()
        end
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

  local junit = require('jdtls.junit')
  dap.run(config, {
    before = function(conf)
      server = assert(uv.new_tcp(), "uv.new_tcp() must return handle")
      test_results = junit.mk_test_results(context.bufnr)
      server:bind('127.0.0.1', 0)
      server:listen(128, function(err2)
        assert(not err2, err2)
        local sock = assert(vim.loop.new_tcp(), "uv.new_tcp must return handle")
        server:accept(sock)
        sock:read_start(test_results.mk_reader(sock))
      end)
      conf.args = conf.args:gsub('-port ([0-9]+)', '-port ' .. server:getsockname().port);
      return conf
    end;
    after = function()
      if server then
        server:shutdown()
        server:close()
      end
      local items = test_results.show()
      maybe_repeat(lens, config, context, opts, items)
      if opts.after_test then
        opts.after_test(items)
      end
    end;
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
      vim.notify('No test class found')
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
      vim.notify('No suitable test method found')
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
    table.insert(list,  v)
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

    require('jdtls.ui').pick_one_async(
      candidates,
      'Tests> ',
      function(lens) return lens.fullName end,
      function(lens)
        if not lens then
          return
        end
        fetch_launch_args(lens, context, function(launch_args)
          local config = make_config(lens, launch_args, opts.config_overrides)
          run(lens, config, context, opts)
        end)
      end
    )
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
  if type(opts) == 'function' then
    vim.notify('First argument to `fetch_main_configs` changed to a `opts` table', vim.log.levels.WARN)
    callback = opts
    opts = {}
  end
  local configurations = {}
  local bufnr = api.nvim_get_current_buf()
  local jdtls = get_clients({ bufnr = bufnr, name = "jdtls"})[1]
  local root_dir = jdtls and jdtls.config and jdtls.config.root_dir
  util.execute_command({command = 'vscode.java.resolveMainClass'}, function(err, mainclasses)
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
          util.execute_command({command = 'vscode.java.resolveClasspath', arguments = { mainclass, project }}, function(err1, paths)
            remaining = remaining - 1
            if err1 then
              print(string.format('Could not resolve classpath and modulepath for %s/%s: %s', project, mainclass, err1.message))
              return
            end
            local config = {
              cwd = root_dir;
              type = 'java';
              name = 'Launch ' .. (project or '') .. ': ' .. mainclass;
              projectName = project;
              mainClass = mainclass;
              modulePaths = paths[1];
              classPaths = paths[2];
              javaExec = java_exec;
              request = 'launch';
              console = 'integratedTerminal';
              vmArgs = use_preview and '--enable-preview' or nil;
            }
            config = vim.tbl_extend('force', config, opts.config_overrides or default_config_overrides)
            table.insert(configurations, config)
            if remaining == 0 then
              callback(configurations)
            end
          end, bufnr)
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
  local status, dap = pcall(require, 'dap')
  if not status then
    print('nvim-dap is not available')
    return
  end
  if opts.verbose then
    vim.notify('Fetching debug configurations')
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
      vim.notify(string.format('Updated %s debug configuration(s)', #configurations))
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
  local status, dap = pcall(require, 'dap')
  if not status then
    print('nvim-dap is not available')
    return
  end
  if dap.adapters.java then
    return
  end
  opts = opts or {}
  default_config_overrides = opts.config_overrides or {}
  dap.listeners.before['event_hotcodereplace']['jdtls'] = function(session, body)
    if body.changeType == hotcodereplace_type.BUILD_COMPLETE then
      if opts.hotcodereplace == 'auto' then
        vim.notify('Applying code changes')
        session:request('redefineClasses', nil, function(err)
          assert(not err, vim.inspect(err))
        end)
      end
    elseif body.message then
      vim.notify(body.message)
    end
  end
  dap.adapters.java = start_debug_adapter
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

return M
