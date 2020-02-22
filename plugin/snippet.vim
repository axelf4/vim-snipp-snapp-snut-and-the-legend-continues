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
		let [_, lnum, col; rest] = getcurpos()
		let col -= 2 " Take care of foo

		let parsed = s:ReadSnippetBody(g:snippetDef)
		let c = col " Current column
		let current_lnum = lnum
		let replacement = []
		let placeholders = []
		for eline in parsed
			let current_line = ''
			for item in eline
				if item.type ==# 'text'
					let current_line ..= item.text
					let c += item.text->len()
				elseif item.type ==# 'placeholder'
					let text = item.initial
					" TODO Handle multiline text
					eval placeholders->add(#{lnum: current_lnum, col: c, length: text->len()})
					let current_line ..= text
					let c += text->len()
				else
					throw 'Bad type'
				endif
			endfor

			eval replacement->add(current_line)
			let current_lnum += 1
		endfor

		" TODO: Handle indent
		call s:Edit(lnum, col, lnum, col + 3, replacement)
		call cursor(lnum, col) " Set cursor to start

		echom placeholders
		for placeholder in placeholders
			call prop_add(placeholder.lnum, placeholder.col, #{
						\ length: placeholder.length,
						\ type: 'placeholder',
						\ })
		endfor

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

	" Leave user editing the next tab stop
	let save_virtualedit = &virtualedit
	try
		set virtualedit=onemore
		echom 'prop' prop
		call cursor(prop.lnum, prop.col) " Position cursor at start
		let zero_len = prop.length == 0
		if zero_len
			startinsert
		else
			execute 'normal! gh' | " Start Select mode
			call cursor(prop.lnum, prop.col + prop.length) " Position cursor at end
			execute "normal! \<C-O>\<C-H>" | " Go back one char
		endif
	finally
		let &virtualedit = save_virtualedit
	endtry
endfunction

" {text} is a List of lines
function s:ReadSnippetBody(text) abort
	function! s:ParseLine(i, line) abort
		let result = []
		let line = a:line
		while 1
			let res = matchlist(line, '\([^$]*\)\%($\%({\(\d\+\)\%(:\([^}]*\)\)\?}\)\(.*\)\)\?')
			echom res
			let [match, before, digit, initial, after; rest] = res
			if empty(match) | break | endif
			if !empty(before)
				eval result->add(#{type: 'text', text: before})
			endif
			if !empty(digit)
				eval result->add(#{type: 'placeholder', id: str2nr(digit), initial: initial})
			endif
			let line = after
		endwhile
		return result
	endfunction

	let result = a:text->copy()->map(funcref('s:ParseLine'))

	" Add tab stop after snippet
	eval result[-1]->add(#{type: 'placeholder', id: 0, initial: ''})

	return result
endfunction

let snippetDef =<< trim END
console.log(${1:foo})fesfe
END

inoremap <script> <Plug>SnipExpandOrJump <Esc>:call <SID>ExpandOrJump()<CR>

" Can use <C-R>= in insmode to not move cursor
imap <unique> <expr> <Tab> <SID>ShouldTrigger() ? "\<Plug>SnipExpandOrJump"
			\ : "\<Tab>"
