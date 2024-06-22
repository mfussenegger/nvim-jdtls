local M = {}
local ns = vim.api.nvim_create_namespace('junit')

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
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  vim.diagnostic.reset(ns, bufnr)
  local tests = {}

  local handle_buffer = function(buf)
    parse(buf, tests)
  end

  local function get_test_start_line_num(lenses, test)
    if test.method ~= nil then
      if #lenses > 0 then
        for _, v in ipairs(lenses) do
          if vim.startswith(v.label, test.method) then
            return v.range.start.line
          end
        end
      else
        if vim.startswith(lenses.label, test.method) then
          return lenses.range.start.line
        end
      end
    end
    return nil
  end

  return {
    show = function(lens)
      local items = {}
      local repl = require('dap.repl')
      local num_failures = 0
      local lenses = lens.children or lens
      local failures = {}
      local error_symbol = '❌'
      local success_symbol = '✔️ '
      for _, test in ipairs(tests) do
        local start_line_num = get_test_start_line_num(lenses, test)
        if test.failed then
          num_failures = num_failures + 1
          if start_line_num ~= nil then
            vim.api.nvim_buf_set_extmark(bufnr, ns, start_line_num, 0, {
              virt_text = { { '\t\t' .. error_symbol } },
            })
          end

          if test.method then
            repl.append(error_symbol .. ' ' .. test.method, '$')
          end
          local testMatch
          for _, msg in ipairs(test.traces) do
            local match = msg:match(string.format('at %s.%s', test.fq_class, test.method) .. '%(([%w%p]*:%d+)%)')
            if match then
              testMatch = true
              local lnum = vim.split(match, ':')[2]
              local trace = table.concat(test.traces, '\n')
              local cause = trace:sub(1, trace:find(msg, 1, true) - 1)
              if #trace > 140 then
                trace = trace:sub(1, 140) .. '...'
              end
              table.insert(items, {
                bufnr = bufnr,
                lnum = lnum,
                text = test.method .. ' ' .. trace,
              })
              table.insert(failures, {
                bufnr = bufnr,
                lnum = tonumber(lnum) - 1,
                col = 0,
                severity = vim.diagnostic.severity.ERROR,
                source = 'junit',
                message = cause,
              })
              break
            end
            repl.append(msg, '$')
          end
          if not testMatch then
            for _, msg in ipairs(test.traces) do
              local match = msg:match(string.format('at %s', test.fq_class) .. '[%w%p]+%(([%a%p]*:%d+)%)')
              if match then
                local lnum = vim.split(match, ':')[2]
                local trace = table.concat(test.traces, '\n')
                local cause = trace:sub(1, trace:find(msg, 1, true) - 1)
                table.insert(failures, {
                  bufnr = bufnr,
                  lnum = tonumber(lnum) - 1,
                  col = 0,
                  severity = vim.diagnostic.severity.ERROR,
                  source = 'junit',
                  message = cause,
                })
                break
              end
            end
          end
        else
          if start_line_num ~= nil then
            vim.api.nvim_buf_set_extmark(bufnr, ns, start_line_num, 0, {
              virt_text = { { '\t\t' .. success_symbol } },
            })
          end
          repl.append(success_symbol .. ' ' .. test.method, '$')
        end
      end
      vim.diagnostic.set(ns, bufnr, failures, {})

      if num_failures > 0 then
        vim.fn.setqflist({}, 'r', {
          title = 'jdtls-tests',
          items = items,
        })
        print(
          'Tests finished. Results printed to dap-repl.',
          #items > 0 and 'Errors added to quickfix list' or '',
          string.format('(%s %d / %d)', error_symbol, num_failures, #tests)
        )
      else
        print('Tests finished. Results printed to dap-repl.', success_symbol, #tests, 'succeeded')
      end
      return items
    end,
    mk_reader = function(sock)
      return vim.schedule_wrap(mk_buf_loop(sock, handle_buffer))
    end,
  }
end

return M
