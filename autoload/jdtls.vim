
function! jdtls#FileUrlEdit(url)
  call luaeval('require("jdtls").open_jdt_link(_A)', a:url)
endfunction
