" Wayland clipboard integration for terminal Vim using wl-clipboard.
" Requires: wl-copy, wl-paste (wl-clipboard)

if empty($WAYLAND_DISPLAY)
  finish
endif

if executable('wl-copy') && executable('wl-paste')
  let g:clipboard = {
        \ 'name': 'wl-clipboard',
        \ 'copy': {
        \   '+': 'wl-copy --type text/plain;charset=utf-8',
        \   '*': 'wl-copy --primary --type text/plain;charset=utf-8',
        \ },
        \ 'paste': {
        \   '+': 'wl-paste --no-newline',
        \   '*': 'wl-paste --primary --no-newline',
        \ },
        \ 'cache_enabled': 0,
        \ }
endif
