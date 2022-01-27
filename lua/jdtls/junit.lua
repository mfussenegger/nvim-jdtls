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

local function parse(content, tests)
  local lines = vim.split(content, '\n')
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
      -- Can get test failure without test start if it is a class initialization failure
      if not test then
        test = {
          fq_class = vim.split(line, ',')[2],
          traces = {},
        }
      end
      test.failed = true
    elseif vim.startswith(line, MessageId.TraceStart) then
      tracing = true
    elseif vim.startswith(line, MessageId.TraceEnd) then
      tracing = false
    elseif tracing and test then
      table.insert(test.traces, line)
    end
  end
  if test then
    table.insert(tests, test)
  end
end

M.__parse = parse


local function mk_buf_loop(sock, handle_buffer)
  local buffer = ''
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


function M.mk_test_results(bufnr)
  local tests = {}
  local handle_buffer = function(buf)
    parse(buf, tests)
  end
  return {
    show = function()
      local items = {}
      local repl = require('dap.repl')
      local num_failures = 0
      for _, test in ipairs(tests) do
        if test.failed then
          num_failures = num_failures + 1
          if test.method then
            repl.append('❌' .. test.method, '$')
          end
          for _, msg in ipairs(test.traces) do
            local match = msg:match(string.format('at %s.%s', test.fq_class, test.method) .. '%(([%a%p]*:%d+)%)')
            if match then
              local lnum = vim.split(match, ':')[2]
              local trace = table.concat(test.traces, '\n')
              if #trace > 140 then
                trace = trace:sub(1, 140) .. '...'
              end
              table.insert(items, {
                bufnr = bufnr,
                lnum = lnum,
                text = test.method .. ' ' .. trace
              })
            end
            repl.append(msg, '$')
          end
        else
          repl.append('✔️ ' .. test.method, '$')
        end
      end

      if num_failures > 0 then
        vim.fn.setqflist({}, 'r', {
          title = 'jdtls-tests',
          items = items,
        })
        print(
          'Tests finished. Results printed to dap-repl.',
          #items > 0 and 'Errors added to quickfix list' or '',
          string.format('(❌%d / %d)', num_failures, #tests)
        )
      else
        print('Tests finished. Results printed to dap-repl. All', #tests, 'succeeded')
      end
      return items
    end;
    mk_reader = function(sock)
      return vim.schedule_wrap(mk_buf_loop(sock, handle_buffer))
    end;
  }
end


return M
