local junit = require 'jdtls.junit'
describe('jdtls.junit', function()
  it('can parse result of successful test', function()
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
  it('can parse test result with initialization failure', function()
    local lines = {
      '%TESTC  1 v2',
      '%TSTTREE1,test_foo(io.foo.FooTest),false,1,false,-1,test_foo(io.foo.FooTest),,',
      '%ERROR  2,io.foo.FooTest',
      '%TRACES ',
      'java.lang.UnsupportedOperationException: foo',
      '\tat java.base/java.lang.Thread.run(Thread.java:833)',
      '',
      '%TRACEE ',
      '%RUNTIME698',
    }
    local tests = {}
    junit.__parse(table.concat(lines, '\n'), tests)
    local expected = {
      {
        failed = true,
        fq_class = 'io.foo.FooTest',
        traces = {
          'java.lang.UnsupportedOperationException: foo',
          '\tat java.base/java.lang.Thread.run(Thread.java:833)',
          '',
        },
      },
    }
    assert.are.same(expected, tests)
  end)
end)
