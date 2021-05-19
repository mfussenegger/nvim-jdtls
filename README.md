# nvim-jdtls

Extensions for the built-in [Language Server Protocol][1] support in [Neovim][2] (>= 0.5) for [eclipse.jdt.ls][3].

**Warning**: This is early state. Neovim 0.5 hasn't been released yet, so APIs can change and things may break.


## Extensions

- [x] `organize_imports` function to organize imports
- [x] `extract_variable` function to introduce a local variable
- [x] `extract_constant` function to extract a constant
- [x] `extract_method` function to extract a block of code into a method
- [x] Open class file contents
- [x] Code action extensions
  - [x] Generate constructors
  - [x] Generate `toString` function
  - [x] `hashCode` and `equals` generation.
  - [x] Extract variables or methods
  - [x] Generate delegate methods
  - [x] Move package, instance method, static method or type
- [x] `javap` command to show bytecode of current file
- [x] `jol` command to show memory usage of current file (`jol_path` must be set)
- [x] `jshell` command to open up jshell with classpath from project set
- [x] Debugger support via [nvim-dap][5]


Take a look at [a demo](https://github.com/mfussenegger/nvim-jdtls/issues/3) to
see some of the functionality in action.


## Plugin Installation

- Requires [Neovim HEAD/nightly][4]
- nvim-jdtls is a plugin. Install it like any other Vim plugin.
- Call `:packadd nvim-jdtls` if you install `nvim-jdtls` to `'packpath'`.


## Language Server Installation

For ``nvim-jdtls`` to work, [eclipse.jdt.ls][3] needs to be installed.

To build eclipse.jdt.ls from source, switch to a folder of your choice and run:


```bash
git clone https://github.com/eclipse/eclipse.jdt.ls.git
cd eclipse.jdt.ls
./mvnw clean verify
```

Create a launch script with the following contents. **But don't forget to adapt
the paths**.

- `$HOME/dev/eclipse` needs to be changed to the folder where you cloned the
repository.
- `/usr/lib/jvm/java-14-openjdk/bin/java` needs to be changed to point to your
  Java installation.

If you're using Java < 9, remove the `add-modules` and `-add-opens` options.


```bash
#!/usr/bin/env bash

# NOTE:
# This doesn't work as is on Windows. You'll need to create an equivalent `.bat` file instead
#
# NOTE:
# If you're not using Linux you'll need to adjust the `-configuration` option
# to point to the `config_mac' or `config_win` folders depending on your system.

JAR="$HOME/dev/eclipse/eclipse.jdt.ls/org.eclipse.jdt.ls.product/target/repository/plugins/org.eclipse.equinox.launcher_*.jar"
GRADLE_HOME=$HOME/gradle /usr/lib/jvm/java-14-openjdk/bin/java \
  -Declipse.application=org.eclipse.jdt.ls.core.id1 \
  -Dosgi.bundles.defaultStartLevel=4 \
  -Declipse.product=org.eclipse.jdt.ls.core.product \
  -Dlog.protocol=true \
  -Dlog.level=ALL \
  -Xms1g \
  -Xmx2G \
  -jar $(echo "$JAR") \
  -configuration "$HOME/dev/eclipse/eclipse.jdt.ls/org.eclipse.jdt.ls.product/target/repository/config_linux" \
  -data "${1:-$HOME/workspace}" \
  --add-modules=ALL-SYSTEM \
  --add-opens java.base/java.util=ALL-UNNAMED \
  --add-opens java.base/java.lang=ALL-UNNAMED
```

The script must be placed in a folder that is part of `$PATH`. To verify that
the installation worked, launch it in a shell. You should get the following
output:

```text
Content-Length: 126

{"jsonrpc":"2.0","method":"window/logMessage","params":{"type":3,"message":"Sep 16, 2020, 8:10:53 PM Main thread is waiting"}}
```


## Configuration


To use `nvim-jdtls`, you need to setup a LSP client. In your `init.vim` add the
following:

```vimL
if has('nvim-0.5')
  augroup lsp
    au!
    au FileType java lua require('jdtls').start_or_attach({cmd = {'java-lsp.sh'}})
  augroup end
endif
```

`java-lsp.sh` needs to be changed to the name of the shell script created earlier.

The argument passed to `start_or_attach` is the same `config` mentioned in
`:help vim.lsp.start_client`. You may want to configure some settings via
`init_options` or `settings`. See the [eclipse.jdt.ls Wiki][8] for an overview
of available options.

You can also find more [complete configuration examples in the Wiki][11].


### root_dir configuration

For the language server to work correctly it is important that the `root_dir`
in the `config` is set correctly. By default `start_or_attach` sets the
`root_dir` automatically by looking for marker files relative to each file
you're opening. The markers default to `.git`, `mvnw` and `gradlew`. If no
parent directory contains any of the markers, it will fallback to the current
working directory.

`nvim-jdtls` contains a `find_root` function which you could use to customize the `root_dir`:

```lua
-- find_root looks for parent directories relative to the current buffer containing one of the given arguments.
require('jdtls').start_or_attach({cmd = {'java-lsp.sh'}, root_dir = require('jdtls.setup').find_root({'gradle.build', 'pom.xml'})})
```


### data directory configuration

`eclipse.jdt.ls` stores project specific data within the folder set via the
`-data` flag in the `java-lsp.sh` script. If you're using `eclipse.jdt.ls` with
multiple different projects you should use a dedicated data directory per
project. You can do that by adding a second argument to the `cmd` property of
the `config` passed to `start_or_attach`. An example:


```lua
start_or_attach({cmd = {'java-lsp.sh', '/home/user/workspace/' .. vim.fn.fnamemodify(vim.fn.getcwd(), ':p:h:t')}})
```


### lspconfig

**Warning**: Using [nvim-lspconfig][9] in addition to the setup here is not
required.

You can use it to configure other servers, but you **must not** call
`require'nvim_lsp'.jdtls.setup{}`. You'd end up running *two* clients and two
language servers if you do that.


### UI picker customization

**Tip**: You can get a better UI for code-actions and other functions by
overriding the `jdtls.ui` picker. See [UI Extensions][10].


## Usage

`nvim-jdtls` extends the capabilities of the built-in LSP support in
Neovim, so all the functions mentioned in `:help lsp` will work.

`nvim-jdtls` provides some extras, for those you'll want to create additional
mappings:

```vimL
-- `code_action` is a superset of vim.lsp.buf.code_action and you'll be able to
-- use this mapping also with other language servers
nnoremap <A-CR> <Cmd>lua require('jdtls').code_action()<CR>
vnoremap <A-CR> <Esc><Cmd>lua require('jdtls').code_action(true)<CR>
nnoremap <leader>r <Cmd>lua require('jdtls').code_action(false, 'refactor')<CR>

nnoremap <A-o> <Cmd>lua require'jdtls'.organize_imports()<CR>
nnoremap crv <Cmd>lua require('jdtls').extract_variable()<CR>
vnoremap crv <Esc><Cmd>lua require('jdtls').extract_variable(true)<CR>
nnoremap crc <Cmd>lua require('jdtls').extract_constant()<CR>
vnoremap crc <Esc><Cmd>lua require('jdtls').extract_constant(true)<CR>
vnoremap crm <Esc><Cmd>lua require('jdtls').extract_method(true)<CR>


-- If using nvim-dap
-- This requires java-debug and vscode-java-test bundles, see install steps in this README further below.
nnoremap <leader>df <Cmd>lua require'jdtls'.test_class()<CR>
nnoremap <leader>dn <Cmd>lua require'jdtls'.test_nearest_method()<CR>
```


Some methods are better exposed via commands. As a shortcut you can also call
`:lua require('jdtls.setup').add_commands()` to declare these. It's recommended to call `add_commands` within the `on_attach` handler that can be set on the `config` table which is passed to `start_or_attach`.


```vimL
command! -buffer JdtCompile lua require('jdtls').compile()
command! -buffer JdtUpdateConfig lua require('jdtls').update_project_config()
command! -buffer JdtJol lua require('jdtls').jol()
command! -buffer JdtBytecode lua require('jdtls').javap()
command! -buffer JdtJshell lua require('jdtls').jshell()
```


## Debugger (via nvim-dap)


`nvim-jdtls` provides integration with [nvim-dap][5].

Once setup correctly, it enables the following additional functionality:

1. Debug applications via explicit configurations
2. Debug automatically discovered main classes
3. Debug junit tests. Either whole classes or individual test methods

For 1 & 2 to work, [eclipse.jdt.ls][3] needs to load the [java-debug][6]
extension. For 3 to work, it also needs to load the [vscode-java-test][7] extension.

For usage instructions once installed, read the [nvim-dap][5] help.
Debugging junit test classes or methods will be possible via these two functions:

```lua
require'jdtls'.test_class()
require'jdtls'.test_nearest_method()
```

### java-debug installation

- Clone [java-debug][6]
- Navigate into the cloned repository (`cd java-debug`)
- Run `./mvnw clean install`
- Extend the `initializationOptions` with which you start [eclipse.jdt.ls][3] as follows:


```lua
config['init_options'] = {
  bundles = {
    vim.fn.glob("path/to/java-debug/com.microsoft.java.debug.plugin/target/com.microsoft.java.debug.plugin-*.jar")
  };
}
```

### nvim-dap setup

You also need to call `require('jdtls').setup_dap()` to have it register a
`java` adapter for `nvim-dap` and to create configurations for all discovered
main classes.

To do that, extend the configuration for `nvim-jdtls` with:

```lua
config['on_attach'] = function(client, bufnr)
  -- With `hotcodereplace = 'auto' the debug adapter will try to apply code changes
  -- you make during a debug session immediately.
  -- Remove the option if you do not want that.
  require('jdtls').setup_dap({ hotcodereplace = 'auto' })
end
```

### vscode-java-test installation

To be able to debug junit tests, it is necessary to install the bundles from [vscode-java-test][7]:

- Clone the repository
- Navigate into the folder (`cd vscode-java-test`)
- Run `npm install`
- Run `npm run build-plugin`
- Extend the bundles in the nvim-jdtls config:


```lua

-- This bundles definition is the same as in the previous section (java-debug installation)
local bundles = {
  vim.fn.glob("path/to/java-debug/com.microsoft.java.debug.plugin/target/com.microsoft.java.debug.plugin-*.jar"),
};

-- This is the new part
vim.list_extend(bundles, vim.split(vim.fn.glob("/path/to/microsoft/vscode-java-test/server/*.jar"), "\n"))
config['init_options'] = {
  bundles = bundles;
}
```

## Troubleshooting

### vim.lsp.buf functions don't do anything

This can have two reasons:

1. The client and server aren't starting up correctly.

You can check if the client is running with `:lua print(vim.inspect(vim.lsp.buf_get_clients()))`, it should output a lot of information.
If it doesn't, verify:

- That the language server can be started standalone. (Run the `java-lsp.sh` in a terminal)
- That there are no configuration errors. (Run `:set ft=java` and `:messages` after opening a Java file)
- Check the log files (`:lua print(vim.fn.stdpath('cache'))` lists the path, there should be a `lsp.log`)


2. Eclipse.jdt.ls can't compile your project or it cannot load your project and resolve the class paths.

- Run `:JdtCompile` for incremental compilation or `:JdtCompile full` for full
  compilation. If there are any errors in the project, it will open the
  quickfix list with the errors.

- Check the log files (`:lua print(vim.fn.stdpath('cache'))` lists the path, there should be a `lsp.log`)
- If there is nothing, try changing the log level. See `:help vim.lsp.set_log_level()`


### Diagnostics and completion suggestions are slow

Completion requests can be quite expensive on big projects. If you're using
some kind of autoc-ompletion plugin that triggers completion requests
automatically, consider deactivating it or tuning it so it is less aggressive.
Triggering a completion request on each typed character is likely overloading
[eclipse.jdt.ls][3].


### Newly added dependencies are not found

You can try running `:JdtUpdateConfig` to refresh the configuration. If that
doesn't work you'll need to restart the language server.

### Language server doesn't find classes that should be there

The language server has its own mental model of which files exists based on
what the client tells it. If you modify files outside of neovim, then the
language server won't be notified of the changes. This can happen for example
if you switch to a different branch with git.

If the language server doesn't get a notification about a new file, you might
get errors, telling you that a class cannot be resolved. If that is the case,
open the file and save it. Then the language server will be notified about the
new file and it should start to recognize the classes within the file.


### After updating eclipse.jdt.ls it doesn't work properly anymore

Try wiping your workspace folder and restart Neovim and the language server.

(the workspace folder is the path you used as argument to `-data` in your
`java-lsp.sh`).


[1]: https://microsoft.github.io/language-server-protocol/
[2]: https://neovim.io/
[3]: https://github.com/eclipse/eclipse.jdt.ls
[4]: https://github.com/neovim/neovim/releases/tag/nightly
[5]: https://github.com/mfussenegger/nvim-dap
[6]: https://github.com/microsoft/java-debug
[7]: https://github.com/microsoft/vscode-java-test
[8]: https://github.com/eclipse/eclipse.jdt.ls/wiki/Running-the-JAVA-LS-server-from-the-command-line
[9]: https://github.com/neovim/nvim-lspconfig
[10]: https://github.com/mfussenegger/nvim-jdtls/wiki/UI-Extensions
[11]: https://github.com/mfussenegger/nvim-jdtls/wiki/Sample-Configurations
