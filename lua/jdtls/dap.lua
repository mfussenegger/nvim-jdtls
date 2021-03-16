local api = vim.api
local uv = vim.loop
local util = require('jdtls.util')
local resolve_classname = util.resolve_classname
local with_java_executable = util.with_java_executable
local M = {}


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
  util.execute_command({command = 'vscode.java.resolveMainClass'}, function(err, mainclasses)
    assert(not err, err and (err.message or vim.inspect(err)))

    if not config.projectName then
      for _, entry in ipairs(mainclasses) do
        if entry.mainClass == config.mainClass then
          config.projectName = entry.projectName
          break
        end
      end
    end
    assert(config.projectName, "projectName is missing")
    with_java_executable(config.mainClass, config.projectName, function(java_exec)
      config.javaExec = config.javaExec or java_exec
      local params = {
        command = 'vscode.java.resolveClasspath',
        arguments = { config.mainClass, config.projectName }
      }
      util.execute_command(params, function(err1, paths)
        assert(not err1, err1 and (err1.message or vim.inspect(err1)))
        config.modulePaths = config.modulePaths or paths[1]
        config.classPaths = config.classPaths or vim.tbl_filter(
          function(x)
            return vim.fn.isdirectory(x) == 1 or vim.fn.filereadable(x) == 1
          end,
          paths[2]
        )
        on_config(config)
      end)
    end)
  end)
end


local function start_debug_adapter(callback)
  util.execute_command({command = 'vscode.java.startDebugSession'}, function(err0, port)
    assert(not err0, vim.inspect(err0))

    callback({
      type = 'server';
      host = '127.0.0.1';
      port = port;
      enrich_config = enrich_dap_config;
    })
  end)
end


local TestKind = {
  None = -1,
  JUnit = 0,
  JUnit5 = 1,
  TestNG = 2
}


local TestLevel = {
  Root = 0,
  Folder = 1,
  Package = 2,
  Class = 3,
  Method = 4,
}


local function make_junit_request_args(lens, uri)
  local methodname = ''
  local name_parts = vim.split(lens.fullName, '#')
  local classname = name_parts[1]
  if #name_parts > 1 then
    methodname = name_parts[2]
    if lens.paramTypes and #lens.paramTypes > 0 then
      methodname = string.format('%s(%s)', methodname, table.concat(lens.paramTypes, ','))
    end
  end
  local req_arguments = {
    uri = uri;
    -- Got renamed to fullName in https://github.com/microsoft/vscode-java-test/commit/57191b5367ae0a357b80e94f0def9e46f5e77796
    -- keep it for BWC (hopefully that works?)
    classFullName = classname;
    fullName = classname;
    testName = methodname;
    project = lens.project;
    scope = lens.level;
    testKind = lens.kind;
  }
  if lens.kind == TestKind.JUnit5 and lens.level == TestLevel.Method then
    req_arguments['start'] = lens.location.range['start']
    req_arguments['end'] = lens.location.range['end']
  end
  return req_arguments
end


local function fetch_lenses(context, on_lenses)
  local cmd_codelens = {
    command = 'vscode.java.test.search.codelens';
    arguments = { context.uri };
  }
  util.execute_command(cmd_codelens, function(err0, codelens)
    if err0 then
      print('Error fetching codelens: ' .. (err0.message or vim.inspect(err0)))
    else
      on_lenses(codelens)
    end
  end)
end

local function fetch_launch_args(lens, context, on_launch_args)
  local req_arguments = make_junit_request_args(lens, context.uri)
  local cmd_junit_args = {
    command = 'vscode.java.test.junit.argument';
    arguments = { vim.fn.json_encode(req_arguments) };
  }
  util.execute_command(cmd_junit_args, function(err, launch_args)
    if err then
      print('Error retrieving launch arguments: ' .. (err.message or vim.inspect(err)))
    else
      on_launch_args(launch_args)
    end
  end)
end


local function get_method_lens_above_cursor(lenses, lnum)
  local result
  for _, lens in pairs(lenses) do
    if lens.level == TestLevel.Method and lens.location.range.start.line <= lnum then
      if result == nil then
        result = lens
      elseif lens.location.range.start.line > result.location.range.start.line then
        result = lens
      end
    end
  end
  return result
end


local function get_first_class_lens(lenses)
  for _, lens in pairs(lenses) do
    if lens.level == TestLevel.Class then
      return lens
    end
  end
end


local function make_config(lens, launch_args)
  local args = table.concat(launch_args.programArguments, ' ');
  return {
    name = 'Launch Java Test: ' .. lens.fullName;
    type = 'java';
    request = 'launch';
    mainClass = launch_args.mainClass;
    projectName = launch_args.projectName;
    cwd = launch_args.workingDirectory;
    classPaths = launch_args.classpath;
    modulePaths = launch_args.modulepath;
    args = args;
    vmArgs = table.concat(launch_args.vmArguments, ' ');
    noDebug = false;
  }
end


local function make_context()
  local bufnr = api.nvim_get_current_buf()
  return {
    bufnr = bufnr,
    win = api.nvim_get_current_win(),
    uri = vim.uri_from_bufnr(bufnr)
  }
end


local function run(lens, config, context, opts)
  local ok, dap = pcall(require, 'dap')
  if not ok then
    vim.notify('`nvim-dap` must be installed to run and debug methods')
    return
  end
  config = vim.tbl_extend('force', config, opts.config or {})
  local test_results
  local server = nil
  local junit = require('jdtls.junit')
  print('Running', lens.fullName)
  dap.run(config, {
    before = function(conf)
      server = uv.new_tcp()
      test_results = junit.mk_test_results(context.bufnr)
      server:bind('127.0.0.1', 0)
      server:listen(128, function(err2)
        assert(not err2, err2)
        local sock = vim.loop.new_tcp()
        server:accept(sock)
        sock:read_start(test_results.mk_reader(sock))
      end)
      conf.args = conf.args:gsub('-port ([0-9]+)', '-port ' .. server:getsockname().port);
      return conf
    end;
    after = function()
      server:shutdown()
      server:close()
      test_results.show()
    end;
  })
end


--- API of these methods is unstable and might change in the future
M.experimental = {
  run = run,
  fetch_lenses = fetch_lenses,
  fetch_launch_args = fetch_launch_args,
  make_context = make_context,
  make_config = make_config,
}


function M.test_class(opts)
  opts = opts or {}
  local context = make_context()
  fetch_lenses(context, function(lenses)
    local lens = get_first_class_lens(lenses)
    if not lens then
      vim.notify('No test class found')
      return
    end
    fetch_launch_args(lens, context, function(launch_args)
      local config = make_config(lens, launch_args)
      run(lens, config, context, opts)
    end)
  end)
end


function M.test_nearest_method(opts)
  opts = opts or {}
  local lnum = api.nvim_win_get_cursor(0)[1]
  local context = make_context()
  fetch_lenses(context, function(lenses)
    local lens = get_method_lens_above_cursor(lenses, lnum)
    if not lens then
      vim.notify('No suitable test method found')
      return
    end
    fetch_launch_args(lens, context, function(launch_args)
      local config = make_config(lens, launch_args)
      run(lens, config, context, opts)
    end)
  end)
end


function M.pick_test(opts)
  opts = opts or {}
  local context = make_context()
  fetch_lenses(context, function(lenses)
    require('jdtls.ui').pick_one_async(
      lenses,
      'Tests> ',
      function(lens) return lens.fullName end,
      function(lens)
        if not lens then
          return
        end
        fetch_launch_args(lens, context, function(launch_args)
          local config = make_config(lens, launch_args)
          run(lens, config, context, opts)
        end)
      end
    )
  end)
end


local original_configurations = nil
function M.setup_dap()
  local status, dap = pcall(require, 'dap')
  if not status then
    print('nvim-dap is not available')
    return
  end
  if dap.adapters.java and original_configurations then
    return
  end

  dap.adapters.java = start_debug_adapter
  original_configurations = dap.configurations.java or {}
  local configurations = vim.deepcopy(original_configurations)
  dap.configurations.java = configurations

  util.execute_command({command = 'vscode.java.resolveMainClass'}, function(err0, mainclasses)
    if err0 then
      print('Could not resolve mainclasses: ' .. err0.message)
      return
    end

    for _, mc in pairs(mainclasses) do
      local mainclass = mc.mainClass
      local project = mc.projectName

      with_java_executable(mainclass, project, function(java_exec)
        util.execute_command({command = 'vscode.java.resolveClasspath', arguments = { mainclass, project }}, function(err2, paths)
          if err2 then
            print(string.format('Could not resolve classpath and modulepath for %s/%s: %s', project, mainclass, err2.message))
            return
          end
          local config = {
            type = 'java';
            name = 'Launch ' .. mainclass;
            projectName = project;
            mainClass = mainclass;
            modulePaths = paths[1];
            classPaths = paths[2];
            javaExec = java_exec;
            request = 'launch';
            console = 'integratedTerminal';
          }
          table.insert(configurations, config)
        end)
      end)
    end
  end)
end



return M
