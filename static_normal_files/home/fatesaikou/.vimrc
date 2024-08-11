set cursorline
set nocompatible              " be iMproved, required
filetype off                  " required

" set the runtime path to include Vundle and initialize
set rtp+=~/.vim/bundle/Vundle.vim
call vundle#begin()
" alternatively, pass a path where Vundle should install plugins
"call vundle#begin('~/some/path/here')

" let Vundle manage Vundle, required
Plugin 'VundleVim/Vundle.vim'

" The following are examples of different formats supported.
" Keep Plugin commands between vundle#begin/end.
" plugin on GitHub repo
Plugin 'junegunn/vim-easy-align'
Plugin 'tpope/vim-fugitive'
" plugin from http://vim-scripts.org/vim/scripts.html
Plugin 'L9'
" Git plugin not hosted on GitHub
"Plugin 'git://git.wincent.com/command-t.git'
""""""
" <CR>        open the selected file
" <C-CR>      open the selected file in a new split window
" <C-s>       open the selected file in a new split window
" <C-v>       open the selected file in a new vertical split window
" <C-t>       open the selected file in a new tab
"
""""""
" git repos on your local machine (i.e. when working on your own plugin)
" The sparkup vim script is in a subdirectory of this repo called vim.
" Pass the path to set the runtimepath properly.
Plugin 'rstacruz/sparkup', {'rtp': 'vim/'}
" Install L9 and avoid a Naming conflict if you've already installed a
" different version somewhere else.

Plugin 'The-NERD-tree'

Plugin 'vim-airline/vim-airline'
Plugin 'vim-airline/vim-airline-themes'

Plugin 'scrooloose/syntastic'

Plugin 'fatih/molokai'
Plugin 'AndrewRadev/splitjoin.vim'
Plugin 'SirVer/ultisnips'

Plugin 'cocopon/iceberg.vim'
Plugin 'ctrlpvim/ctrlp.vim'

Plugin 'othree/html5.vim'
Plugin 'pangloss/vim-javascript'
Plugin 'evanleck/vim-svelte', {'branch': 'main'}

call vundle#end()

" Linter
Plugin 'nvie/vim-flake8'

" All of your Plugins must be added before the following line
filetype plugin indent on    " required
" To ignore plugin indent changes, instead use:
"filetype plugin on
"
" Brief help
" :PluginList       - lists configured plugins
" :PluginInstall    - installs plugins; append `!` to update or just :PluginUpdate
" :PluginSearch foo - searches for foo; append `!` to refresh local cache
" :PluginClean      - confirms removal of unused plugins; append `!` to auto-approve removal
"
" see :h vundle for more details or wiki for FAQ
" Put your non-Plugin stuff after this line

" Plugin Settings
"   airline_settings
let g:airline#extensions#tabline#enabled = 1
"   syntastic_settings
let g:syntastic_cpp_check_header = 1
let g:syntastic_cpp_checkers = ['clang_check']
let g:syntastic_cpp_compiler = 'clang++'
let g:syntastic_cpp_compiler_options = ' -std=c++11 -stdlib=libc++ -I'
let g:syntastic_python_checkers=['pyflakes']
let g:syntastic_python_pylint_args='--disable=C0111,R0903,C0301'
let g:syntastic_java_checkers=['javac']
let g:syntastic_java_javac_config_file_enabled = 1
set statusline=
set statusline+=%1*\[%n]                                  "buffernr
set statusline+=%2*\ %<%F\                                "File+path
set statusline+=%3*\ %=\ %{''.(&fenc!=''?&fenc:&enc).''}\ "Encoding
set statusline+=%4*\ %{(&bomb?\",BOM\":\"\")}\            "Encoding2
set statusline+=%5*\ %{&ff}\                              "FileFormat (dos/unix..)
set statusline+=%6*\ row:%l/%L\ col:%03c\ (%03p%%)\             "Rownumber/total (%)
set statusline+=%0*\ \ %m%r%w\ %P\ \                      "Modified? Readonly? Top/bot.
hi User2 ctermfg=3  ctermbg=0
hi User6 ctermfg=3  ctermbg=4
set laststatus=2

" Set F-*'s
map <F2> :NERDTreeToggle<CR>
   
" Basic Settings"
set background=dark
set nobackup
set nocp
set ai
set ts=4
set sw=4
set et
set encoding=utf-8
set fileencodings=utf-8,big5
set list
set listchars=tab:\|\ "eol:_
set ru
set nu
set hlsearch
set backspace=indent,eol,start
let NERDTreeShowHidden=1
" set t_Co=256
syntax on
" colorscheme afterglow
colorscheme iceberg

" Mapping
nmap ,n :bn!<CR>
nmap ,p :bp!<CR>
vmap <Leader>a <Plug>(EasyAlign)
nmap <Leader>a <Plug>(EasyAlign)
nmap <Leader>f :CtrlP<CR>

set nofixendofline
