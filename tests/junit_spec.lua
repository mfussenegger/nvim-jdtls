describe('jdtls.junit', function()
  it('can parse test results', function()
    local junit = require 'jdtls.junit'
    local lines = {
      '%TESTC  1 v2',
      '%TSTTREE1,test_foo(io.bar.BarTest),false,1,false,-1,test_foo(io.bar.BarTest),,',
      '%TESTS  1,test_foo(io.bar.BarTest)',
      '%TESTE  1,test_foo(io.bar.BarTest)',
      '%RUNTIME2078',
    }
    local tests = {}
    junit.__parse(table.concat(lines, '\n'), tests)
    local expected = {
      {
        failed = false,
        fq_class = 'io.bar.BarTest',
        method = 'test_foo',
        traces = {},
      },
    }
    assert.are.same(expected, tests)
  end)
end)
