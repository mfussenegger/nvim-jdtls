local M = {}
local ns = vim.api.nvim_create_namespace("junit")

-- Add missing constants
local TestLevel = {
  Workspace = 1,
  WorkspaceFolder = 2,
  Project = 3,
  Package = 4,
  Class = 5,
  Method = 6,
}

local LegacyTestLevel = {
  Root = 0,
  Folder = 1,
  Package = 2,
  Class = 3,
  Method = 4,
}

local MessageId = {
  TestStart = "%TESTS",
  TestEnd = "%TESTE",
  TestFailed = "%FAILED",
  TestError = "%ERROR",
  TraceStart = "%TRACES",
  TraceEnd = "%TRACEE",
  IGNORE_TEST_PREFIX = "@Ignore: ",
  ASSUMPTION_FAILED_TEST_PREFIX = "@AssumptionFailure: ",
}

local config = {
  success_symbol = "✔️ ",
  error_symbol = "❌",
}

function M.setup(testsConfig)
  testsConfig = testsConfig or {}
  config.success_symbol = testsConfig.success_symbol or config.success_symbol
  config.error_symbol = testsConfig.error_symbol or config.error_symbol
end

local function parse_test_case(line)
  local matches = vim.fn.matchlist(line, "\\v\\d+,(\\@AssumptionFailure: |\\@Ignore: )?(.*)(\\[\\d+\\])?\\((.*)\\)")
  if #matches == 0 then
    return nil
  end
  local method_name = matches[3]
  local param_start = method_name:find("%(")
  if param_start then
    method_name = method_name:sub(1, param_start - 1)
  end

  return {
    fq_class = matches[5],
    method = method_name,
  }
end

local trace_exclude_patterns = {
  "%sat com%.carrotsearch%.randomizedtesting",
  "%sat java%.base/jdk%.internal%.reflect%.DirectMethodHandleAccessor%.invoke",
  "%sat java%.base/java%.lang%.reflect%.Method%.invoke",
  "%sat org%.junit%.rules%.",
}

local function include(line)
  for _, pattern in ipairs(trace_exclude_patterns) do
    if line:find(pattern) then
      return false
    end
  end
  return true
end

local function parse(content, tests)
  local lines = vim.split(content, "\n")
  local tracing = false
  local test = nil
  for _, line in ipairs(lines) do
    if vim.startswith(line, MessageId.TestStart) then
      test = parse_test_case(line)
      if test then
        test.traces = {}
        test.failed = false
      end
    elseif vim.startswith(line, MessageId.TestEnd) then
      if test then
        table.insert(tests, test)
      end
      test = nil
    elseif vim.startswith(line, MessageId.TestFailed) or vim.startswith(line, MessageId.TestError) then
      if not test then
        local parts = vim.split(line, ",")
        local fq_class_from_error = parts[2]
        if fq_class_from_error then
          local class_end = fq_class_from_error:find("#")
          if class_end then
            fq_class_from_error = fq_class_from_error:sub(1, class_end - 1)
          end
        end
        test = {
          fq_class = fq_class_from_error or "UnknownClass",
          traces = {},
        }
      end
      test.failed = true
    elseif vim.startswith(line, MessageId.TraceStart) then
      tracing = true
    elseif vim.startswith(line, MessageId.TraceEnd) then
      tracing = false
    elseif tracing and test and include(line) then
      table.insert(test.traces, line)
    end
  end
  if test then
    table.insert(tests, test)
  end
end

M.__parse = parse

local function mk_buf_loop(sock, handle_buffer)
  local buffer = ""
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

local function flatten_lenses_recursive(lenses_tree, flattened_list)
  flattened_list = flattened_list or {}
  for _, lens in ipairs(lenses_tree) do
    table.insert(flattened_list, lens)
    if lens.children then
      flatten_lenses_recursive(lens.children, flattened_list)
    end
  end
  return flattened_list
end

local function get_test_start_line_num(all_available_lenses_flat, test)
  for _, lens_item in ipairs(all_available_lenses_flat) do
    local range = lens_item.location and lens_item.location.range or lens_item.range
    if not range then
      goto continue
    end

    local lens_full_name = lens_item.fullName or lens_item.classFullName
    if not lens_full_name then
      goto continue
    end

    if test.method then
      local is_method_lens = lens_item.testLevel == TestLevel.Method or lens_item.level == LegacyTestLevel.Method
      if is_method_lens then
        local class_part, method_part = lens_full_name:match("([^#]+)#(.*)")
        if class_part and method_part then
          local param_start = method_part:find("%(")
          if param_start then
            method_part = method_part:sub(1, param_start - 1)
          end
          if class_part == test.fq_class and method_part == test.method then
            return range.start.line
          end
        end
      end
    else
      local is_class_lens = lens_item.testLevel == TestLevel.Class or lens_item.level == LegacyTestLevel.Class
      if is_class_lens and lens_full_name == test.fq_class then
        return range.start.line
      end
    end
    ::continue::
  end
  return nil
end

function M.mk_test_results(bufnr, shared, class_to_file_map)
  local tests = shared or {}
  local file_map = class_to_file_map or {}

  local handle_buffer = function(buf)
    parse(buf, tests)
  end

  return {
    show = function(lens_or_lenses_tree)
      local items = {}
      local repl = require("dap.repl")
      local num_failures = 0
      local failures = {}
      local results = {}

      -- Determine if this is a package test (multiple classes)
      local is_package_test = type(lens_or_lenses_tree) == "table" and #lens_or_lenses_tree > 1

      -- Clear diagnostics and quickfix for both single class and package tests
      vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
      vim.diagnostic.reset(ns, bufnr)

      -- Clear quickfix list at the start
      vim.fn.setqflist({}, "r", { title = "jdtls-tests", items = {} })

      -- For single class tests, handle visual markers normally
      local all_lenses_flat = {}
      if not is_package_test then
        if lens_or_lenses_tree.children then
          all_lenses_flat = flatten_lenses_recursive(lens_or_lenses_tree.children)
        else
          all_lenses_flat = flatten_lenses_recursive({ lens_or_lenses_tree })
        end
      end

      for _, test in ipairs(tests) do
        local start_line_num = nil

        -- Only try to find line numbers for single class tests
        if not is_package_test then
          start_line_num = get_test_start_line_num(all_lenses_flat, test)
        end

        if test.failed then
          num_failures = num_failures + 1

          if start_line_num ~= nil then
            table.insert(results, {
              lnum = start_line_num,
              success = false,
            })
          end

          -- Display name
          local display_name = test.method
          if is_package_test then
            local class_name = test.fq_class:match("([^%.]+)$") or test.fq_class
            display_name = class_name .. (test.method and ("#" .. test.method) or "")
          end

          repl.append(config.error_symbol .. " " .. (display_name or test.fq_class), "$")

          -- Add to quickfix with proper file paths
          for _, msg in ipairs(test.traces) do
            local pattern = test.method and string.format("at %s.%s", test.fq_class, test.method)
              or string.format("at %s", test.fq_class)
            local match = msg:match(pattern .. "%(([%w%p]*:%d+)%)")

            if match then
              local file_line = vim.split(match, ":")
              local filename = file_line[1]
              local lnum = file_line[2]

              -- For package tests, try to resolve the full file path
              local full_filename = filename
              if is_package_test and file_map[test.fq_class] then
                full_filename = file_map[test.fq_class]
              end

              table.insert(items, {
                filename = full_filename,
                lnum = lnum,
                text = (display_name or test.fq_class) .. ": " .. test.traces[1],
              })

              -- Only add diagnostics for single class tests
              if not is_package_test and start_line_num ~= nil then
                local cause = table.concat(test.traces, "\n")
                table.insert(failures, {
                  bufnr = bufnr,
                  lnum = tonumber(lnum) - 1,
                  col = 0,
                  severity = vim.diagnostic.severity.ERROR,
                  source = "junit",
                  message = cause,
                })
              end
              break
            end
            repl.append("  " .. msg, "$")
          end
        else
          if start_line_num ~= nil then
            table.insert(results, {
              lnum = start_line_num,
              success = true,
            })
          end

          local display_name = test.method
          if is_package_test then
            local class_name = test.fq_class:match("([^%.]+)$") or test.fq_class
            display_name = class_name .. (test.method and ("#" .. test.method) or "")
          end

          repl.append(config.success_symbol .. " " .. (display_name or test.fq_class), "$")
        end
      end

      -- Only set diagnostics and markers for single class tests
      if not is_package_test then
        vim.diagnostic.set(ns, bufnr, failures, {})

        for _, result in ipairs(results) do
          local symbol = result.success and config.success_symbol or config.error_symbol
          vim.api.nvim_buf_set_extmark(bufnr, ns, result.lnum, 0, {
            virt_text = { { symbol } },
            invalidate = true,
          })
        end
      end

      local total_tests = #tests
      if num_failures > 0 then
        vim.fn.setqflist({}, "r", {
          title = "jdtls-tests",
          items = items,
        })
        local msg = string.format(
          "Tests finished: %d passed, %d failed (%d total)",
          total_tests - num_failures,
          num_failures,
          total_tests
        )
        if is_package_test then
          msg = msg .. " - Use quickfix list to navigate to failures"
        end
        print(msg)
      else
        print(string.format("Tests finished: All %d tests passed %s", total_tests, config.success_symbol))
      end

      return items, tests
    end,
    mk_reader = function(sock)
      return vim.schedule_wrap(mk_buf_loop(sock, handle_buffer))
    end,
  }
end

return M
