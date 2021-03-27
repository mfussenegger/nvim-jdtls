if exists('g:nvim_jdtls')
  finish
endif
let g:nvim_jdtls = 1

au BufReadCmd jdt://* lua require('jdtls').open_jdt_link(vim.fn.expand('<amatch>'))
