" Vim plugin for snippets

highlight Placeholder ctermbg=darkblue

call prop_type_add('placeholder', #{
			\ highlight: 'Placeholder',
			\ start_incl: 1,
			\ end_incl: 1,
			\ })

" Replace the specified range with the given text.
"
" Start is inclusive, while end is exclusive.
" {text} is the replacement consisting of a List of lines.
"
" Tries to respect text properties.
function s:Edit(lnum, col, end_lnum, end_col, text) abort
	if a:end_lnum < a:lnum || (a:lnum == a:end_lnum && a:end_col < a:col)
		throw 'Start is past end?'
	endif

	let [save_cursor, save_selection] = [getcurpos(), &selection]
	try
		call cursor(a:lnum, a:col) " Position cursor at start
		set selection=exclusive
		normal! v
		call cursor(a:end_lnum, a:end_col) " Position cursor at end
		" Replace with first and last line
		execute 'normal! c'
					\ .. (a:text->empty() ? '' : a:text[0]
					\ .. (a:text->len() > 1 ? "\<CR>" .. a:text[-1] : ''))
		" Set middle section
		call append(a:lnum, repeat([''], a:text->len() - 2))
		eval a:text[1:-2]->setline(a:lnum + 1)
	finally
		" TODO: Better to leave cursor at start?
		call setpos('.', save_cursor)
		let &selection = save_selection
	endtry
endfunction

function s:ShouldTrigger() abort
	let s:should_expand = 0
	let cword = matchstr(getline('.'), '\v\w+%' . col('.') . 'c')
	if cword ==# 'fin'
		let s:should_expand = 1
		return 1
	endif

	" Search forward from cursor for tab stop
	let prop = prop_find(#{
				\ type: 'placeholder',
				\ skipstart: 0,
				\ }, 'f')
	echom prop
	if prop->empty()
		return
	else
		return 1
	endif
endfunction

" Try to expand a snippet or jump to the next tab stop.
"
" Returns false if failed.
function s:ExpandOrJump(...) abort
	let did_expand = 0
	if s:should_expand
		let snippet = ["1111111111", "2222", '333333']

		let [_, lnum, col; rest] = getcurpos()
		" TODO: Handle indent
		call s:Edit(lnum, col - 2, lnum, col + 1, snippet)
		call cursor(lnum, col - 2) " Set cursor to start

		call prop_add(lnum, col - 2, #{
					\ length: 3,
					\ type: 'placeholder',
					\ })

		let did_expand = 1
	endif

	" Search forward from cursor for tab stop
	let prop = prop_find(#{
				\ type: 'placeholder',
				\ skipstart: !did_expand,
				\ }, 'f')
	if prop->empty()
		return
	endif

	call cursor(prop.lnum, prop.col) " Position cursor at start
	let zero_len = prop.length == 0
	if zero_len
		normal! i
	else
		execute 'normal! gh' | " Start Select mode
		call cursor(prop.lnum, prop.col + prop.length) " Position cursor at end
		execute "normal! \<C-O>\<C-H>" | " Go back one char
	endif
endfunction

inoremap <script> <Plug>SnipExpandOrJump <Esc>:call <SID>ExpandOrJump()<CR>

" Can use <C-R>= in insmode to not move cursor
imap <unique> <expr> <Tab> <SID>ShouldTrigger() ? "\<Plug>SnipExpandOrJump"
			\ : "\<Tab>"
