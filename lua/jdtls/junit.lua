local repl = require('dap.repl')
local M = {}


local MessageId = {
  TestStart = '%TESTS',
  TestEnd = '%TESTE',
  TestFailed = '%FAILED',
  TestError = '%ERROR',
  TraceStart = '%TRACES',
  TraceEnd = '%TRACEE',
  IGNORE_TEST_PREFIX = '@Ignore: ',
  ASSUMPTION_FAILED_TEST_PREFIX = '@AssumptionFailure: ',
}


local function parse_test_case(line)
  local matches = vim.fn.matchlist(line, '\\v\\d+,(\\@AssumptionFailure: |\\@Ignore: )?(.*)(\\[\\d+\\])?\\((.*)\\)')
  if #matches == 0 then
    return nil
  end
  return {
    fq_class = matches[5],
    method = matches[3],
  }
end

local function parse(buf, tests)
  local lines = vim.split(buf, '\n')
  local tracing = false
  local test = nil
  for _, line in ipairs(lines) do
    if vim.startswith(line, MessageId.TestStart) then
      test = parse_test_case(line)
      if test then
        test.traces = {}
        test.failed = false
      else
        print('Could not parse line: ', line)
      end
    elseif vim.startswith(line, MessageId.TestEnd) then
      table.insert(tests, test)
      test = nil
    elseif vim.startswith(line, MessageId.TestFailed) or vim.startswith(line, MessageId.TestError) then
      assert(test, "Encountered TestFailed/TestError, but no TestStart encounterd")
      test.failed = true
    elseif vim.startswith(line, MessageId.TraceStart) then
      tracing = true
    elseif vim.startswith(line, MessageId.TraceEnd) then
      tracing = false
    elseif tracing and test then
      table.insert(test.traces, line)
    end
  end
end


local function mk_buf_loop(sock, handle_buffer)
  buffer = ''
  return function(err, chunk)
    assert(not err, err)
    if chunk then
      buffer = buffer .. chunk
    else
      sock:close()
      handle_buffer(buffer)
    end
  end
end


function M.mk_test_results()
  local tests = {}
  local handle_buffer = function(buf)
    parse(buf, tests)
  end
  return {
    show = function()
      for _, test in ipairs(tests) do
        if test.failed then
          repl.append(test.fq_class .. '#' .. test.method, '$')
          for _, msg in ipairs(test.traces) do
            repl.append(msg, '$')
          end
        end
      end
    end;
    mk_reader = function(sock)
      return vim.schedule_wrap(mk_buf_loop(sock, handle_buffer))
    end;
  }
end


return M
