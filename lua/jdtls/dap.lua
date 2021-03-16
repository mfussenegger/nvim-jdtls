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


local function run_test_codelens(choose_lens, no_match_msg, opts)
  opts = opts or {}
  local status, dap = pcall(require, 'dap')
  if not status then
    print('nvim-dap is not available')
    return
  end
  local bufnr = api.nvim_get_current_buf()
  local uri = vim.uri_from_bufnr(0)
  local cmd_codelens = {
    command = 'vscode.java.test.search.codelens';
    arguments = { uri };
  }
  util.execute_command(cmd_codelens, function(err0, codelens)
    if err0 then
      print('Error fetching codelens: ' .. (err0.message or vim.inspect(err0)))
      return
    end
    local choice = choose_lens(codelens)
    if not choice then
      print(no_match_msg)
      return
    end

    local methodname = ''
    local name_parts = vim.split(choice.fullName, '#')
    local classname = name_parts[1]
    if #name_parts > 1 then
      methodname = name_parts[2]
      if choice.paramTypes and #choice.paramTypes > 0 then
        methodname = string.format('%s(%s)', methodname, table.concat(choice.paramTypes, ','))
      end
    end
    local req_arguments = {
      uri = uri;
      -- Got renamed to fullName in https://github.com/microsoft/vscode-java-test/commit/57191b5367ae0a357b80e94f0def9e46f5e77796
      -- keep it for BWC (hopefully that works?)
      classFullName = classname;
      fullName = classname;
      testName = methodname;
      project = choice.project;
      scope = choice.level;
      testKind = choice.kind;
    }
    if choice.kind == TestKind.JUnit5 and choice.level == TestLevel.Method then
      req_arguments['start'] = choice.location.range['start']
      req_arguments['end'] = choice.location.range['end']
    end
    local cmd_junit_args = {
      command = 'vscode.java.test.junit.argument';
      arguments = { vim.fn.json_encode(req_arguments) };
    }
    util.execute_command(cmd_junit_args, function(err1, launch_args)
      if err1 then
        print('Error retrieving launch arguments: ' .. (err1.message or vim.inspect(err1)))
        return
      end
      local args = table.concat(launch_args.programArguments, ' ');
      local config = {
        name = 'Launch Java Test: ' .. choice.fullName;
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
      local test_results
      local server = nil
      local junit = require('jdtls.junit')
      print('Running', classname, methodname)
      dap.run(config, {
        before = function(conf)
          server = uv.new_tcp()
          test_results = junit.mk_test_results(bufnr)
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
          local items = test_results.show()
          if opts.until_error and #items == 0 then
            print('`until_error` set and no tests failed. Repeating.')
            vim.defer_fn(dap.run_last, 1000)
          end
        end;
      })
    end)
  end)
end


function M.test_class(opts)
  local choose_lens = function(codelens)
    for _, lens in pairs(codelens) do
      if lens.level == TestLevel.Class then
        return lens
      end
    end
  end
  run_test_codelens(choose_lens, 'No test class found', opts)
end


function M.test_nearest_method(opts)
  local lnum = api.nvim_win_get_cursor(0)[1]
  local choose_lens = function(codelens)
    local candidates = {}
    for _, lens in pairs(codelens) do
      if lens.level == TestLevel.Method and lens.location.range.start.line <= lnum then
        table.insert(candidates, lens)
      end
    end
    if #candidates == 0 then return end
    table.sort(candidates, function(a, b)
      return a.location.range.start.line > b.location.range.start.line
    end)
    return candidates[1]
  end
  run_test_codelens(choose_lens, 'No suitable test method found', opts)
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
