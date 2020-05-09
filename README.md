# nvim-jdtls

Extensions for the built-in [Language Server Protocol][1] support in [Neovim][2] (>= 0.5) for [eclipse.jdt.ls][3].

**Warning**: This is early state. Neovim 0.5 hasn't been released yet, so APIs can change and things may break.


## Extensions

- [x] Command to organize imports
- [x] Open class file contents
- [x] Code action extensions (`java.apply.workspaceEdit`).
- [x] `toString` generation.
- [x] `hashCode` and `equals` generation.
- [x] `javap` command to show bytecode of current file
- [x] Integration with [nvim-dap][5]


## Installation

- Requires [Neovim HEAD/nightly][4]
- nvim-jdtls is a plugin. Install it like any other Vim plugin.
- Call `:packadd nvim-jdtls` if you install `nvim-jdtls` to `'packpath'`.


## Usage

`nvim-jdtls` doesn't contain logic to spawn a LSP client for [eclipse.jdt.ls][3], see `:help lsp` for information on how to launch a LSP client.
To make use of all the functionality `nvim-jdtls` provides, you need to override some of the `lsp` callbacks, set some extra capabilities and set a couple of initialization options.

The callbacks:

```lua
  local jdtls = require 'jdtls'
  vim.lsp.callbacks['workspace/applyEdit'] = jdtls.workspace_apply_edit,
```


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
capabilities.workspace = {
  applyEdit = true;
}
```


Initialization options:


```lua
config['init_options'] = {
  extendedClientCapabilities = {
    classFileContentsSupport = true;
    generateToStringPromptSupport = true;
    hashCodeEqualsPromptSupport = true;
  };
}
```


You may also want to create mappings for the code action command and to organize imports:

```
nnoremap <A-CR> <Cmd>lua require'jdtls'.code_action()<CR>
nnoremap <A-o> <Cmd>lua require'jdtls'.organize_imports()<CR>
nnoremap <leader>df <Cmd>lua require'jdtls'.test_class()<CR>
nnoremap <leader>dn <Cmd>lua require'jdtls'.test_nearest_method()<CR>
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
