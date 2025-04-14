if exists('g:nvim_jdtls')
  finish
endif
let g:nvim_jdtls = 1

au BufReadCmd jdt://* lua require('jdtls').open_classfile(vim.fn.expand('<amatch>'))
au BufReadCmd *.class lua require("jdtls").open_classfile(vim.fn.expand("<amatch>"))
command! JdtWipeDataAndRestart lua require('jdtls.setup').wipe_data_and_restart()
command! JdtShowLogs lua require('jdtls.setup').show_logs()

augroup record_latest_jdtls_buf
  autocmd!
  au BufEnter * lua require("jdtls.setup").record_latest_jdtls_buf()
augroup end
