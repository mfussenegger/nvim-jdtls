# nvim-jdtls

Extensions for the built-in [Language Server Protocol][1] support in [Neovim][2] (>= 0.6.0) for [eclipse.jdt.ls][3].

## Audience

This project follows the [KISS principle][kiss] and targets users with some
experience with Neovim, Java and its build tools Maven or Gradle who prefer
configuration as code over GUI configuration. Ease of use is not the main
priority.

If you prioritize ease of use over simplicity, you may want to use an
alternative:

- [coc-java](https://github.com/neoclide/coc-java)
- [vscode](https://code.visualstudio.com/)
- [IntelliJ IDEA](https://www.jetbrains.com/idea/)
- [Eclipse](https://www.eclipse.org/ide/)

## Extensions

- [x] `organize_imports` function to organize imports
- [x] `extract_variable` function to introduce a local variable
- [x] `extract_variable_all` function to introduce a local variable and replace all occurrences.
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
  - [x] Signature refactoring
- [x] `javap` command to show bytecode of current file
- [x] `jol` command to show memory usage of current file (`jol_path` must be set)
- [x] `jshell` command to open up `jshell` with `classpath` from project set
- [x] Debugger support via [nvim-dap][5]
- [x] Optional vscode-java-test extensions
  - [x] Generate tests via `require("jdtls.tests").generate()`
  - [x] Jump to tests or subjects via `require("jdtls.tests").goto_subjects()`

Take a look at [a demo](https://github.com/mfussenegger/nvim-jdtls/issues/3) to
see some of the functionality in action.

## Plugin Installation

- Requires Neovim (Latest stable (recommended) or nightly)
- nvim-jdtls is a plugin. Install it like any other Vim plugin:
  - `git clone https://github.com/mfussenegger/nvim-jdtls.git ~/.config/nvim/pack/plugins/start/nvim-jdtls`
  - Or with [vim-plug][14]: `Plug 'mfussenegger/nvim-jdtls'`
  - Or with [packer.nvim][15]: `use 'mfussenegger/nvim-jdtls'`
  - Or any other plugin manager


## Language Server Installation

Install [eclipse.jdt.ls][3] by following their [Installation instructions](https://github.com/eclipse/eclipse.jdt.ls#installation).


## Configuration (quickstart)

Add the following to `~/.config/nvim/ftplugin/java.lua` (See `:help base-directory`):

```lua
local config = {
    cmd = {'/path/to/jdt-language-server/bin/jdtls'},
    root_dir = vim.fs.dirname(vim.fs.find({'gradlew', '.git', 'mvnw'}, { upward = true })[1]),
}
require('jdtls').start_or_attach(config)
```

**Important**:

- eclipse.jdt.ls requires Java 17
- The `jdtls` script requires Python 3.9
- You'll have to teach eclipse.jdt.ls about your JDK installations by setting
  up `runtimes` if your projects use a different Java version than the one
  you're using for eclipse.jdt.ls itself. See `Java XY language features are
  not available` in the troubleshooting section further below to learn how to
  do that.

This should get you started, but will create temporary eclipse data folders
when you open a project. Please read the `Configuration (verbose)` section if
you want more control over the configuration or want to understand how things
work.

## Configuration (verbose)

To configure `nvim-jdtls`, add the following in `ftplugin/java.lua` within the
Neovim configuration base directory (e.g. `~/.config/nvim/ftplugin/java.lua`,
see `:help base-directory`).

Watch out for the 💀, it indicates that you must adjust something.


```lua
-- See `:help vim.lsp.start_client` for an overview of the supported `config` options.
local config = {
  -- The command that starts the language server
  -- See: https://github.com/eclipse/eclipse.jdt.ls#running-from-the-command-line
  cmd = {

    -- 💀
    'java', -- or '/path/to/java17_or_newer/bin/java'
            -- depends on if `java` is in your $PATH env variable and if it points to the right version.

    '-Declipse.application=org.eclipse.jdt.ls.core.id1',
    '-Dosgi.bundles.defaultStartLevel=4',
    '-Declipse.product=org.eclipse.jdt.ls.core.product',
    '-Dlog.protocol=true',
    '-Dlog.level=ALL',
    '-Xmx1g',
    '--add-modules=ALL-SYSTEM',
    '--add-opens', 'java.base/java.util=ALL-UNNAMED',
    '--add-opens', 'java.base/java.lang=ALL-UNNAMED',

    -- 💀
    '-jar', '/path/to/jdtls_install_location/plugins/org.eclipse.equinox.launcher_VERSION_NUMBER.jar',
         -- ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^                                       ^^^^^^^^^^^^^^
         -- Must point to the                                                     Change this to
         -- eclipse.jdt.ls installation                                           the actual version


    -- 💀
    '-configuration', '/path/to/jdtls_install_location/config_SYSTEM',
                    -- ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^        ^^^^^^
                    -- Must point to the                      Change to one of `linux`, `win` or `mac`
                    -- eclipse.jdt.ls installation            Depending on your system.


    -- 💀
    -- See `data directory configuration` section in the README
    '-data', '/path/to/unique/per/project/workspace/folder'
  },

  -- 💀
  -- This is the default if not provided, you can remove it. Or adjust as needed.
  -- One dedicated LSP server & client will be started per unique root_dir
  root_dir = require('jdtls.setup').find_root({'.git', 'mvnw', 'gradlew'}),

  -- Here you can configure eclipse.jdt.ls specific settings
  -- See https://github.com/eclipse/eclipse.jdt.ls/wiki/Running-the-JAVA-LS-server-from-the-command-line#initialize-request
  -- for a list of options
  settings = {
    java = {
    }
  },

  -- Language server `initializationOptions`
  -- You need to extend the `bundles` with paths to jar files
  -- if you want to use additional eclipse.jdt.ls plugins.
  --
  -- See https://github.com/mfussenegger/nvim-jdtls#java-debug-installation
  --
  -- If you don't plan on using the debugger or other eclipse.jdt.ls plugins you can remove this
  init_options = {
    bundles = {}
  },
}
-- This starts a new client & server,
-- or attaches to an existing client & server depending on the `root_dir`.
require('jdtls').start_or_attach(config)
```

The `ftplugin/java.lua` logic is executed each time a `FileType` event
triggers. This happens every time you open a `.java` file or when you invoke
`:set ft=java`:

You can also find more [complete configuration examples in the Wiki][11].

If you have trouble getting jdtls to work, please read the
[Troubleshooting](#troubleshooting) section.

### data directory configuration

`eclipse.jdt.ls` stores project specific data within the folder set via the
`-data` flag. If you're using `eclipse.jdt.ls` with multiple different projects
you must use a dedicated data directory per project.

An example how you could accomplish that is to infer the workspace directory
name from the current working directory:


```lua
-- If you started neovim within `~/dev/xy/project-1` this would resolve to `project-1`
local project_name = vim.fn.fnamemodify(vim.fn.getcwd(), ':p:h:t')

local workspace_dir = '/path/to/workspace-root/' .. project_name
--                                               ^^
--                                               string concattenation in Lua

local config = {
  cmd = {
    ...,

    '-data', workspace_dir,

    ...,
  }
}
```

`...` is not valid Lua in this context. It is meant as placeholder for the
other options from the [Configuration](#configuration) section above.)

### nvim-lspconfig and nvim-jdtls differences

Both [nvim-lspconfig][9] and nvim-jdtls use the client built into neovim:

```txt
  ┌────────────┐           ┌────────────────┐
  │ nvim-jdtls │           │ nvim-lspconfig │
  └────────────┘           └────────────────┘
       |                         |
      start_or_attach           nvim_lsp.jdtls.setup
       │                              |
       │                             setup java filetype hook
       │    ┌─────────┐                  │
       └───►│ vim.lsp │◄─────────────────┘
            └─────────┘
                .start_client
                .buf_attach_client
```

Some differences between the two:

- The `setup` of lspconfig creates a `java` `filetype` hook itself and provides
  some defaults for the `cmd` of the `config`.
- `nvim-jdtls` delegates the choice when to call `start_or_attach` to the user.
- `nvim-jdtls` adds some logic to handle `jdt://` URIs. These are necessary to
  load source code from third party libraries or the JDK.
- `nvim-jdtls` adds some additional handlers and sets same extra capabilities
  to enable all the extensions.

You could use either to start the `eclipse.jdt.ls` client, but it is
recommended to use the `start_or_attach` method from `nvim-jdtls` because of
the additional capabilities it configures and because of the `jdt://` URI
handling.

You **must not** use both at the same time for java. You'd end up with two
clients and two language server instances.

### UI picker customization

**Tip**: You can get a better UI for code-actions and other functions by
overriding the `jdtls.ui` picker. See [UI Extensions][10].

## Usage

`nvim-jdtls` extends the capabilities of the built-in LSP support in
Neovim, so all the functions mentioned in `:help lsp` will work.

`nvim-jdtls` provides some extras, for those you'll want to create additional
mappings:

```vimL
nnoremap <A-o> <Cmd>lua require'jdtls'.organize_imports()<CR>
nnoremap crv <Cmd>lua require('jdtls').extract_variable()<CR>
vnoremap crv <Esc><Cmd>lua require('jdtls').extract_variable(true)<CR>
nnoremap crc <Cmd>lua require('jdtls').extract_constant()<CR>
vnoremap crc <Esc><Cmd>lua require('jdtls').extract_constant(true)<CR>
vnoremap crm <Esc><Cmd>lua require('jdtls').extract_method(true)<CR>


" If using nvim-dap
" This requires java-debug and vscode-java-test bundles, see install steps in this README further below.
nnoremap <leader>df <Cmd>lua require'jdtls'.test_class()<CR>
nnoremap <leader>dn <Cmd>lua require'jdtls'.test_nearest_method()<CR>
```

`nvim-jdtls` also adds several commands if the server starts up correctly:

- `JdtCompile`
- `JdtSetRuntime`
- `JdtUpdateConfig`
- `JdtUpdateDebugConfig` (if `dap` and java-debug bundles are available)
- `JdtUpdateHotcode`     (if `dap` and java-debug bundles are available)
- `JdtBytecode`
- `JdtJol`
- `JdtJshell`
- `JdtRestart`


## API Reference

See `:help jdtls`

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
- Set or extend the `initializationOptions` (= `init_options` of the `config` from [configuration](#Configuration-verbose)) as follows:


```lua
config['init_options'] = {
  bundles = {
    vim.fn.glob("path/to/java-debug/com.microsoft.java.debug.plugin/target/com.microsoft.java.debug.plugin-*.jar", 1)
  };
}
```

### nvim-dap setup

`nvim-jdtls` will automatically register a `java` debug adapter with nvim-dap,
if nvim-dap is available.

If you're using a plugin manager with explicit dependency manager, make sure
that `nvim-dap` is listed as dependency for `nvim-jdtls` for this to work.


### nvim-dap configuration

`nvim-jdtls` includes functionality to discover main classes and create `nvim-dap` configuration entries for them.

To discover the main classes you have to call `require('jdtls.dap').setup_dap_main_class_configs()` or use the `JdtUpdateDebugConfigs` command. It will only discover classes once eclipse.jdt.ls fully loaded the project. Depending on the project that may take a while. Because of that, calling `require('jdtls.dap').setup_dap_main_class_configs()` as part of an `on_attach` handler may not work well.

For manual configuration see [nvim-dap Adapter Installation Wiki](https://github.com/mfussenegger/nvim-dap/wiki/Java).

To get an overview of all available `attach` and `launch` options, take a look at [java-debug options](https://github.com/microsoft/vscode-java-debug#options). Keep in mind that any `java.debug` options are settings of the vscode-java client extension and not understood by the debug-adapter itself.

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
  vim.fn.glob("path/to/java-debug/com.microsoft.java.debug.plugin/target/com.microsoft.java.debug.plugin-*.jar", 1),
};

-- This is the new part
vim.list_extend(bundles, vim.split(vim.fn.glob("/path/to/microsoft/vscode-java-test/server/*.jar", 1), "\n"))
config['init_options'] = {
  bundles = bundles;
}
```

## Troubleshooting

### The client exits with an error / eclipse.jdt.ls stopped working

This can have two reasons:

1) Your `cmd` definition in the [Configuration](#configuration) is wrong.

- Check the log files. Use `:JdtShowLogs` or open the log file manually. `:lua
  print(vim.fn.stdpath('cache'))` lists the path, there should be a `lsp.log`.
  You may have to increase the log level. See `:help vim.lsp.set_log_level()`.

- Ensure you can start the language server standalone by invoking the `cmd`
  defined in the configuration manually within a terminal.

2) The data folder got corrupted.

Wipe the folder and ensure that it is in a dedicated directory and not within
your project repository. See [data directory
configuration](#data-directory-configuration). You can use
`:JdtWipeDataAndRestart` to do this.


### Nothing happens when opening a Java file and I can't use any `vim.lsp.buf` functions

This can have several reasons:

1) You didn't follow [Configuration](#configuration) closely and aren't
invoking `require('jdtls').start_or_attach(config)` as part of a `java`
`filetype` event. Go back to the configuration section and follow it closely.

2) You made a mistake in your configuration and there is a failure happening
when you open the file. Try `:set ft=java` and look at the `:messages` output.

3) eclipse.jdt.ls is starting but it cannot recognize your project, or it
cannot import it properly. Try running `:JdtCompile full` or `:lua
require('jdtls').compile('full')`. It should open the `quickfix` list with errors
if eclipse.jdt.ls started but cannot handle your project.

Check the log files. Use `:JdtShowLogs` or open the log file manually. `:lua
print(vim.fn.stdpath('cache'))` lists the path, there should be a `lsp.log`.
You may have to increase the log level. See `:help vim.lsp.set_log_level()`.


### Error: Unable to access jarfile

Either the file doesn't exist or you're using `~` characters in your path.
Neovim doesn't automatically expand `~` characters in the `cmd` definition. You
either need to write them out or wrap the fragments in `vim.fn.expand` calls.

### Unrecognized option: --add-modules=ALL-SYSTEM

Eclipse.jdt.ls requires at least Java 17. You're using a lower version.

### is a non-project file, only syntax errors are reported

You're opening a single file without having a Gradle or Maven project.
You need to use Gradle or Maven for the full functionality.

### Java XY language features are not available

You need to set the language level via the Gradle or Maven configuration.

If you're starting eclipse.jdt.ls with a Java version that's different from the
one the project uses, you need to configure the available Java runtimes. Add
them to the `config` from the [configuration section](#configuration):

```lua
local config = {
  ..., -- not valid Lua, this is a placeholder for your other properties.
  settings = {
    java = {
      configuration = {
        -- See https://github.com/eclipse/eclipse.jdt.ls/wiki/Running-the-JAVA-LS-server-from-the-command-line#initialize-request
        -- And search for `interface RuntimeOption`
        -- The `name` is NOT arbitrary, but must match one of the elements from `enum ExecutionEnvironment` in the link above
        runtimes = {
          {
            name = "JavaSE-11",
            path = "/usr/lib/jvm/java-11-openjdk/",
          },
          {
            name = "JavaSE-17",
            path = "/usr/lib/jvm/java-17-openjdk/",
          },
        }
      }
    }
  }
}
```

You can also change the language level at runtime using the `:JdtSetRuntime`
command.


### Diagnostics and completion suggestions are slow

Completion requests can be quite expensive on big projects. If you're using
some kind of auto-completion plugin that triggers completion requests
automatically, consider deactivating it or tuning it so it is less aggressive.
Triggering a completion request on each typed character is likely overloading
[eclipse.jdt.ls][3].


### Newly added dependencies are not found

You can try running `:JdtUpdateConfig` to refresh the configuration. If that
doesn't work you'll need to restart the language server.

### Language server doesn't find classes that should be there

The language server supports [gradle](https://gradle.org/) and
[maven](https://maven.apache.org/ref/3.8.4/) as build tools. Your project
should either have a `pom.xml` or `settings.gradle` and `build.gradle` file to
declare the dependencies.

As an alternative you could manually specify the dependencies within your
nvim-jdtls configuration like the following, but this is not recommended.

```lua
config.settings = {
    java = {
      project = {
        referencedLibraries = {
          '/path/to/dependencyA.jar',
          '/path/to/dependencyB.jar',
        },
      }
    }
  }
```

If you modify files outside of Neovim (for example with a git checkout), the
language client and language server may not detect these changes and the state
of the file on disk diverges with the mental model of the language server. If
that happens, you need to open all changed files within Neovim and reload them
with `:e!` to synchronize the state.

### Indentation settings from eclipse formatting configuration are not recognized

This is expected. The Neovim `shiftwidth` and `tabstop` settings have a higher
priority.


[1]: https://microsoft.github.io/language-server-protocol/
[2]: https://neovim.io/
[3]: https://github.com/eclipse/eclipse.jdt.ls
[5]: https://github.com/mfussenegger/nvim-dap
[6]: https://github.com/microsoft/java-debug
[7]: https://github.com/microsoft/vscode-java-test
[9]: https://github.com/neovim/nvim-lspconfig
[10]: https://github.com/mfussenegger/nvim-jdtls/wiki/UI-Extensions
[11]: https://github.com/mfussenegger/nvim-jdtls/wiki/Sample-Configurations
[14]: https://github.com/junegunn/vim-plug
[15]: https://github.com/wbthomason/packer.nvim
[kiss]: https://en.wikipedia.org/wiki/KISS_principle
