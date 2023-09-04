local ns = vim.api.nvim_create_namespace('testng')
local M = {}

local function parse(content, tests)
  local lines = vim.split(content, '\n')
  local test = nil
  for _, line in ipairs(lines) do
    if vim.startswith(line, '@@<TestRunner-') then
      line = line.sub(line, 15)
      line = line:sub(1, -13)
      test = vim.json.decode(line)
      if test.name ~= 'testStarted' then
        table.insert(tests, test)
      end
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
  local tests = {}
  local handle_buffer = function(buf)
    parse(buf, tests)
  end
  local function get_test_line_nr(lenses, name)
    for _, v in ipairs(lenses) do
      if v.fullName == name then
        return v.range.start.line
      end
    end
    return nil
  end
  return {
    show = function(lens)
      local items = {}
      local repl = require('dap.repl')

      -- error = '✘',
      -- warn = '▲',
      -- hint = '⚑',
      -- info = '»'
      local lenses = lens.children or lens
      local failed = {}
      for _, test in ipairs(tests) do
        local lnum = get_test_line_nr(lenses, test.attributes.name)
        if lnum == nil then
          goto continue
        end
        local testName = vim.split(test.attributes.name, '#')[2]
        if test.name == 'testFailed' then
          table.insert(failed, {
            bufnr = bufnr,
            lnum = lnum,
            col = 0,
            severity = vim.diagnostic.severity.ERROR,
            source = 'testng',
            message = test.attributes.message,
            user_data = {}
          })
          repl.append('❌ ' .. testName .. ' failed')
          repl.append(test.attributes.message)
          repl.append(test.attributes.trace)
        elseif test.name == 'testFinished' then
          local text = { '✔️ ' }
          vim.api.nvim_buf_set_extmark(bufnr, ns, lnum, 0, {
            virt_text = { text },
          })
          repl.append('✔️  ' .. testName .. ' passed')
        end
          ::continue::
      end
      vim.diagnostic.set(ns, bufnr, failed, {})
      return items
    end,
    mk_reader = function(sock)
      return vim.schedule_wrap(mk_buf_loop(sock, handle_buffer))
    end,
  }
end

return M
