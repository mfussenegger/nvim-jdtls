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
  - `git clone https://codeberg.org/mfussenegger/nvim-jdtls.git ~/.config/nvim/pack/plugins/start/nvim-jdtls`
  - Or with [vim-plug][14]: `Plug 'mfussenegger/nvim-jdtls'`
  - Or with [packer.nvim][15]: `use 'mfussenegger/nvim-jdtls'`
  - Or any other plugin manager


## Language Server Installation

Install [eclipse.jdt.ls][3] by following their [Installation instructions](https://github.com/eclipse/eclipse.jdt.ls#installation).

## Configuration

To configure jdtls you have several options. Pick one from below.

**Important**:

- If using the `jdtls` script from eclipse.jdt.ls you need Python 3.9 installed.
- eclipse.jdt.ls itself requires Java 21
- eclipse.jdt.ls can handle projects using a different JDK than the one
  you use to run eclipse.jdt.ls. Any JDK >= 8 is supported but you need
  to configure `runtimes` for eclipse.jdt.ls to discover them. See
  `Java XY language features are not available` in the troubleshooting
  section further below to learn how to do that.
- Please also read the [data directory configuration](#data-directory-configuration) section.

### Via lsp.config

Add the following to your `init.lua`:

```lua
vim.lsp.enable("jdtls")
```

A `jdtls` executable must be available in `$PATH` for this approach to work.

If you need to customize `settings`, use:

```lua
vim.lsp.config("jdtls", {
  settings = {
    java = {
        -- Custom eclipse.jdt.ls options go here
    },
  },
})
vim.lsp.enable("jdtls")
```

See `:help lsp-config` for more information.


### Via ftplugin

- Make sure you don't have `jdtls` enabled via `vim.lsp.enable("jdtls")` if using this approach.
- Add the following to `~/.config/nvim/ftplugin/java.lua` (See `:help base-directory`):

```lua
-- See `:help vim.lsp.start` for an overview of the supported `config` options.
local config = {
  name = "jdtls",


  -- `cmd` defines the executable to launch eclipse.jdt.ls.
  -- `jdtls` must be available in $PATH and you must have Python3.9 for this to work.
  --
  -- As alternative you could also avoid the `jdtls` wrapper and launch
  -- eclipse.jdt.ls via the `java` executable
  -- See: https://github.com/eclipse/eclipse.jdt.ls#running-from-the-command-line
  cmd = {"jdtls"},


  -- `root_dir` must point to the root of your project.
  -- See `:help vim.fs.root`
  root_dir = vim.fs.root(0, {'gradlew', '.git', 'mvnw'})


  -- Here you can configure eclipse.jdt.ls specific settings
  -- See https://github.com/eclipse/eclipse.jdt.ls/wiki/Running-the-JAVA-LS-server-from-the-command-line#initialize-request
  -- for a list of options
  settings = {
    java = {
    }
  },


  -- This sets the `initializationOptions` sent to the language server
  -- If you plan on using additional eclipse.jdt.ls plugins like java-debug
  -- you'll need to set the `bundles`
  --
  -- See https://codeberg.org/mfussenegger/nvim-jdtls#java-debug-installation
  --
  -- If you don't plan on any eclipse.jdt.ls plugins you can remove this
  init_options = {
    bundles = {}
  },
}
require('jdtls').start_or_attach(config)
```

The `ftplugin/java.lua` logic is executed each time a `FileType` event
triggers. This happens every time you open a `.java` file or when you invoke
`:set ft=java`:

If you have trouble getting jdtls to work, please read the
[Troubleshooting](#troubleshooting) section.
You can also find more [complete configuration examples in the Wiki][11].


### data directory configuration

`jdtls` takes a `-data` option which defines the location where eclipse.jdt.ls
stores index data for each project it loads.

If the option is not explicitly set, `jdtls` stored the data in a sub-folder
within [tempdir](https://docs.python.org/3/library/tempfile.html#tempfile.gettempdir).
The sub-folder name is derived from `cwd`.

If your system wipes the temporary directory on a shutdown/boot it means
eclipse.jdt.ls will have to reindex your projects after each boot. To avoid
that you can set a `-data` location explicitly. For example like this:


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

Install `java-debug`. If there is a package in your package manager of choice use that, if not, use one of the following methods:

---

#### Via Maven

```bash
MAVEN_OPTS="-Dmaven.repo.local=/tmp/m2" mvn dependency:get "-Dartifact=com.microsoft.java:com.microsoft.java.debug.plugin:0.53.1"
```

The artifact you need is `/tmp/m2/com/microsoft/java/com.microsoft.java.debug.plugin/0.53.1/com.microsoft.java.debug.plugin-0.53.1.jar`

(Replace `0.53.1` with the current java-debug version)

#### From Open VSX Registry

- Download [Debugger for Java](https://open-vsx.org/extension/vscjava/vscode-java-debug)
- Unpack it using `unzip`

The artifact you need will be in `vscjava.vscode-java-debug-*/extension/server/`

#### From source

- Clone [java-debug][6]
- Navigate into the cloned repository (`cd java-debug`)
- Run `./mvnw clean install`

The build artifacts will be in `com.microsoft.java.debug.plugin/target/`.

---


### java-debug bundle configuration

- Set or extend the `initializationOptions` (= `init_options` of the `config` from [configuration](#Configuration)) as follows:

```lua
local bundles = {
  vim.fn.glob("path/to/com.microsoft.java.debug.plugin-*.jar", 1)
}
config['init_options'] = {
  bundles = bundles
}
```

### nvim-dap setup

`nvim-jdtls` will automatically register a `java` debug adapter with nvim-dap,
if nvim-dap is available.

If you're using a plugin manager with explicit dependency manager, make sure
that `nvim-dap` is listed as dependency for `nvim-jdtls` for this to work.


### nvim-dap configuration

Running `:DapNew` will automatically discover main classes in your
project if the `java-debug` bundles are installed and configured
correctly.

If you need additional configurations you can either add project local
configurations in `.vscode/launch.json` or extend the
`dap.java.configurations` list. See `:help dap-configuration`.

To get an overview of all available `attach` and `launch` options, take
a look at [java-debug options][java-debug-options]. Keep
in mind that any `java.debug` options are settings of the vscode-java
client extension and not understood by the debug-adapter itself.


### vscode-java-test installation

Install `vscode-java-test`. If there is a package in your package manager of choice use that, if not, use one of the following methods:

---

#### From Open VSX Registry


- Download [vscode-java-test](https://open-vsx.org/extension/vscjava/vscode-java-debug)
- Unpack it using `unzip`

The artifacts you need are in `dist/server` within the unpacked folder.

#### From source

To be able to debug junit tests, it is necessary to install the bundles from [vscode-java-test][7]:

- Clone the repository
- Navigate into the folder (`cd vscode-java-test`)
- Run `npm install`
- Run `npm run build-plugin`
- Extend the bundles in the nvim-jdtls config:

---


### vscode-java-test configuration


```lua

-- This bundles definition is the same as in the previous section (java-debug installation)
local bundles = {
  vim.fn.glob("path/to/com.microsoft.java.debug.plugin-*.jar", 1)
}


-- This is the new part
local java_test_bundles = vim.split(vim.fn.glob("/path/to/vscode-java-test/server/*.jar", 1), "\n")
local excluded = {
  "com.microsoft.java.test.runner-jar-with-dependencies.jar",
  "jacocoagent.jar",
}
for _, java_test_jar in ipairs(java_test_bundles) do
  local fname = vim.fn.fnamemodify(java_test_jar, ":t")
  if not vim.tbl_contains(excluded, fname) then
    table.insert(bundles, java_test_jar)
  end
end
-- End of the new part


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

Eclipse.jdt.ls requires at least Java 21. You're using a lower version.

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
[5]: https://codeberg.org/mfussenegger/nvim-dap
[6]: https://github.com/microsoft/java-debug
[7]: https://github.com/microsoft/vscode-java-test
[9]: https://github.com/neovim/nvim-lspconfig
[10]: https://codeberg.org/mfussenegger/nvim-jdtls/wiki/UI-Extensions
[11]: https://codeberg.org/mfussenegger/nvim-jdtls/wiki/Sample-Configurations
[14]: https://github.com/junegunn/vim-plug
[15]: https://github.com/wbthomason/packer.nvim
[kiss]: https://en.wikipedia.org/wiki/KISS_principle
[aur]: https://aur.archlinux.org/
[aur-java-debug]: https://aur.archlinux.org/packages/java-debug
[java-debug-options]: https://github.com/microsoft/vscode-java-debug#options
