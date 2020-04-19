if exists('g:nvim_jdtls')
  finish
endif
let g:nvim_jdtls = 1

au BufReadCmd jdt://* call jdtls#FileUrlEdit(expand("<amatch>"))
