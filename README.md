# nvim-jdtls

Extensions for the built-in [Language Server Protocol][1] support in [Neovim][2] (>= 0.5) for [eclipse.jdt.ls][3].

**Warning**: This is early state. Neovim 0.5 hasn't been released yet, so APIs can change and things may break.


## Extensions

- [x] `organize_imports` command to organize imports
- [x] `extract_variable` command to introduce a local variable
- [x] `extract_method` command to extract a block of code into a method
- [x] Open class file contents
- [x] Code action extensions
  - [x] Generate constructors
  - [x] Generate `toString` function
  - [x] `hashCode` and `equals` generation.
  - [x] Extract variables or methods
- [x] `javap` command to show bytecode of current file
- [x] `jol` command to show memory usage of current file (`jol_path` must be set)
- [x] `jshell` command to open up jshell with classpath from project set
- [x] Integration with [nvim-dap][5]


Take a look at [a demo](https://github.com/mfussenegger/nvim-jdtls/issues/3) to
see some of the functionality in action.


## Installation

- Requires [Neovim HEAD/nightly][4]
- nvim-jdtls is a plugin. Install it like any other Vim plugin.
- Call `:packadd nvim-jdtls` if you install `nvim-jdtls` to `'packpath'`.


## Usage

`nvim-jdtls` doesn't contain logic to spawn a LSP client for [eclipse.jdt.ls][3], see `:help lsp` for information on how to launch a LSP client.

To make use of all the functionality `nvim-jdtls` provides, you need to set some extra capabilities and set a couple of initialization options.

Additional capabilities:

```lua
local capabilities = vim.lsp.protocol.make_client_capabilities()
capabilities.textDocument.codeAction = {
  dynamicRegistration = false;
  codeActionLiteralSupport = {
    codeActionKind = {
      valueSet = {
        "source.generate.toString",
        "source.generate.hashCodeEquals"
      };
    };
  };
}
```


Initialization options:


```lua
config['init_options'] = {
  extendedClientCapabilities = require('jdtls').extendedClientCapabilities;
}
```



You may want to create some mappings and commands to make the functionality of `nvim-jdtls` accessible:

```
nnoremap <A-CR> <Cmd>lua require('jdtls').code_action()<CR>
vnoremap <A-CR> <Esc><Cmd>lua require('jdtls').code_action(true)<CR>
nnoremap <leader>r <Cmd>lua require('jdtls').code_action(false, 'refactor')<CR>

nnoremap <A-o> <Cmd>lua require'jdtls'.organize_imports()<CR>
nnoremap crv <Cmd>lua require('jdtls').extract_variable()<CR>
vnoremap crv <Esc><Cmd>lua require('jdtls').extract_variable(true)<CR>
vnoremap crm <Esc><Cmd>lua require('jdtls').extract_method(true)<CR>


-- For nvim-dap
nnoremap <leader>df <Cmd>lua require'jdtls'.test_class()<CR>
nnoremap <leader>dn <Cmd>lua require'jdtls'.test_nearest_method()<CR>


command! -buffer JdtCompile lua require('jdtls').compile()
command! -buffer JdtUpdateConfig lua require('jdtls').update_project_config()
command! -buffer JdtJol lua require('jdtls').jol()
command! -buffer JdtBytecode lua require('jdtls').javap()
command! -buffer JdtJshell lua require('jdtls').jshell()
```


## nvim-dap


`nvim-jdtls` provides integration with [nvim-dap][5].


For this to work, [eclipse.jdt.ls][3] needs to load the [java-debug][6] extension.
To do so, clone [java-debug][6] and run `./mvnw clean install` in the cloned directory, then extend the `initializationOptions` with which you start [eclipse.jdt.ls][3]:

```lua
config['init_options'] = {
  bundles = {
    vim.fn.glob("path/to/java-debug/com.microsoft.java.debug.plugin/target/com.microsoft.java.debug.plugin-*.jar")
  };
}
```

You also need to call `require('jdtls').setup_dap()` to have it register a `java` adapter for `nvim-dap` and to create configurations for all discovered main classes:

```lua
config['on_attach'] = function(client, bufnr)
  require('jdtls').setup_dap()
end
```


Furthermore, `nvim-jdtls` supports running and debugging tests. For this to work the bundles from [vscode-java-test][7] need to be installed: 

- Clone the repo
- Run `npm install`
- Run `npm run build-plugin`
- Extend the bundles:


```lua
local bundles = {
  vim.fn.glob("path/to/java-debug/com.microsoft.java.debug.plugin/target/com.microsoft.java.debug.plugin-*.jar"),
};
vim.list_extend(bundles, vim.split(vim.fn.glob("/path/to/microsoft/vscode-java-test/server/*.jar"), "\n"))
config['init_options'] = {
  bundles = bundles;
}
```


[1]: https://microsoft.github.io/language-server-protocol/
[2]: https://neovim.io/
[3]: https://github.com/eclipse/eclipse.jdt.ls
[4]: https://github.com/neovim/neovim/releases/tag/nightly
[5]: https://github.com/mfussenegger/nvim-dap
[6]: https://github.com/microsoft/java-debug
[7]: https://github.com/microsoft/vscode-java-test
