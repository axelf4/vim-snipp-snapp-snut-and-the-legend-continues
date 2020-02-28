" Vim plugin for snippets
if !(has('textprop') && has("patch-8.2.324"))
	throw 'Incompatible Vim version!'
endif

highlight Placeholder ctermbg=darkblue

call prop_type_add('placeholder', #{
			\ highlight: 'Placeholder',
			\ start_incl: 1,
			\ end_incl: 1,
			\ })

let s:next_placeholder_id = 0
" Map from placeholder ID:s to their respective snippet instances.
let s:placeholder2instance = {}

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

	return s:JumpForward(#{dry_run: 1}) " Return whether can jump forward
endfunction

function s:SelectText(lnum, col, end_lnum, end_col) abort
	let save_virtualedit = &virtualedit
	try
		set virtualedit=onemore
		call cursor(a:lnum, a:col) " Position cursor at start
		let zero_len = a:lnum == a:end_lnum && a:col == a:end_col
		if zero_len
			startinsert
		else
			execute 'normal! gh' | " Start Select mode
			call cursor(a:end_lnum, a:end_col) " Position cursor at end
			execute "normal! \<C-O>\<C-H>" | " Go back one char
		endif
	finally
		let &virtualedit = save_virtualedit
	endtry
endfunction

function s:SelectProp(prop) abort
	" TODO Add support for multiline props
	call s:SelectText(a:prop.lnum, a:prop.col, a:prop.lnum, a:prop.col + a:prop.length)
endfunction

" Try to expand a snippet or jump to the next tab stop.
"
" Returns false if failed.
function s:ExpandOrJump(...) abort
	if s:should_expand
		let [_, lnum, col; rest] = getcurpos()
		let col -= 2 " Take care of foo

		let snippet = s:ReadSnippetBody(g:snippetDef)
		let placeholders = []

		let builder = #{col: col, lnum: lnum, text: [""]}
		let indent = getline(lnum)->matchstr('^\s*')
		function builder.append(string) abort
			let self.text[-1] ..= a:string
			let self.col += a:string->len()
		endfunction
		function builder.newLine() abort closure
			eval self.text->add(indent)
			let self.lnum += 1
			let self.col = 1 + indent->len()
		endfunction

		echom snippet.content

		function! s:HandleContent(content) abort closure
			let first = 1
			for eline in a:content
				if !first | call builder.newLine() | endif
				let first = 0

				for item in eline
					if item.type ==# 'text'
						call builder.append(item.text)
					elseif item.type ==# 'placeholder'
						let [start_lnum, start_col] = [builder.lnum, builder.col]
						call s:HandleContent(item.initial)
						eval placeholders->add(#{
									\ lnum: start_lnum, col: start_col,
									\ end_lnum: builder.lnum, end_col: builder.col,
									\ number: item.id,
									\ })
					else
						throw 'Bad type'
					endif
				endfor
			endfor
		endfunction
		call s:HandleContent(snippet.content)

		call s:Edit(lnum, col, lnum, col + 3, builder.text)

		let first_placeholder_id = s:next_placeholder_id
		let s:next_placeholder_id += placeholders->len()
		let instance = #{
					\ first_placeholder_id: first_placeholder_id,
					\ num_placeholders: placeholders->len(),
					\ }
		let first_placeholder = placeholders->len() > 1 ? 1 : 0

		for placeholder in placeholders
			let placeholder_id = first_placeholder_id + placeholder.number
			call prop_add(placeholder.lnum, placeholder.col, #{
						\ end_lnum: placeholder.end_lnum, end_col: placeholder.end_col,
						\ type: 'placeholder',
						\ id: placeholder_id,
						\ })
			let s:placeholder2instance[placeholder_id] = instance

			if placeholder.number == first_placeholder
				call s:SelectText(placeholder.lnum, placeholder.col,
							\ placeholder.end_lnum, placeholder.end_col)
			endif
		endfor

		eval b:snippet_stack->add(instance)
		return 1
	endif

	return s:JumpForward()
endfunction

function s:PopActiveSnippet() abort
	if b:snippet_stack->empty() | throw 'Popping empty stack?' | endif
	echom 'Popping currently active snippet'
	let instance = b:snippet_stack->remove(-1)

	for placeholder_id in range(instance.first_placeholder_id,
				\ instance.first_placeholder_id + instance.num_placeholders - 1)
		call prop_remove(#{id: placeholder_id, all: 1})
		eval s:placeholder2instance->remove(placeholder_id)
	endfor
endfunction

" Return whether placeholder {id} belongs to snippet {instance}.
function s:HasPlaceholder(instance, id) abort
	return a:instance.first_placeholder_id <= a:id
				\ && a:instance.first_placeholder_id + a:instance.num_placeholders - 1 >= a:id
endfunction

function s:PopUntilBecomesCurrent(id)
	while !(b:snippet_stack[-1]->s:HasPlaceholder(a:id))
		call s:PopActiveSnippet()
	endwhile
endfunction

" Return all placeholder properties that contain the cursor.
function s:CurrentPlaceholder(lnum, ...) abort
	let col = a:000->get(0, -1) " Second argument is optionally a column

	let props = prop_list(a:lnum)->filter({_, v -> v.type ==# 'placeholder'})

	if col != -1
		eval props->filter({_, v -> v.col <= col && v.col + v.length >= col})
	endif

	" Sort after specificity
	eval props->sort({a, b -> b.id - a.id})

	return props
endfunction

let s:NextPlaceholderId = {id, instance -> id >= instance.num_placeholders - 1
			\ ? 0 : id + 1}

function s:JumpForward(...) abort
	let opts = a:000->get(0, {})
	let dry_run = opts->get('dry_run', 0)

	let current_props = s:CurrentPlaceholder(line('.'), col('.'))
	echom current_props
	for placeholder_prop in current_props
		call s:PopUntilBecomesCurrent(placeholder_prop.id)
		let current_instance = b:snippet_stack[-1]
		let number = placeholder_prop.id - current_instance.first_placeholder_id

		while 1
			let number = s:NextPlaceholderId(number, current_instance)
			" Search forward/backward from cursor for tab stop
			" TODO optimze direction
			for direction in ['f', 'b']
				" FIXME Cannot provide a type='placeholder' here because it is an OR...
				let prop = prop_find(#{
							\ id: current_instance.first_placeholder_id + number,
							\ skipstart: 0,
							\ }, direction)
				if !empty(prop)
					" Found property to jump to!
					if dry_run | return 1 | endif

					" If jumping to last placeholder: Snippet is done!
					if number == 0 | call s:PopActiveSnippet() | endif

					echom 'Jumping to prop:' prop
					call s:SelectProp(prop) " Leave user editing the next tab stop

					return 1
				endif
			endfor
		endwhile
	endfor

	return 0
endfunction

" {text} is a List of lines
function s:ReadSnippetBody(text) abort
	let num_placeholders = 0
	let has_placeholder_zero = 0

	" TODO Allow multiline patterns
	function! s:ParseLine(i, line) abort closure
		let result = []
		let line = a:line
		while 1
			let res = matchlist(line, '\([^$]*\)\%($\%({\(\d\+\)\%(:\([^}]*\)\)\?}\)\(.*\)\)\?')
			let [match, before, number, initial, after; rest] = res
			if empty(match) | break | endif
			if !empty(before)
				eval result->add(#{type: 'text', text: before})
			endif
			if !empty(number)
				eval result->add(#{
							\ type: 'placeholder',
							\ id: str2nr(number),
							\ initial: s:ParseContent([initial]),
							\ })
				let num_placeholders += 1
				if number == 0
					let has_placeholder_zero = 1
				endif
			endif
			let line = after
		endwhile
		return result
	endfunction

	function! s:ParseContent(text) abort
		return a:text->copy()->map(funcref('s:ParseLine'))
	endfunction

	let result = s:ParseContent(a:text)

	" Add tab stop after snippet
	if !has_placeholder_zero
		eval result[-1]->add(#{type: 'placeholder', id: 0, initial: []})
		let num_placeholders += 1
	endif

	" Synthesize order of placeholders and mirrors
	let placeholderOrder = repeat([-1], num_placeholders)
	let i = 0
	for eline in result
		for item in eline
			if item.type ==# 'placeholder'
				if placeholderOrder[item.id] != -1 | throw 'Duplicate placeholders' | endif
				let placeholderOrder[item.id] = i
				let i += 1
			endif
		endfor
	endfor

	return #{
				\ content: result,
				\ num_placeholders: num_placeholders,
				\ placeholderOrder: placeholderOrder,
				\ }
endfunction

let snippetDef =<< trim END
	console.log(${3:hej}, ${1:foo}, ${2:tree}, ${4:test}, ${5:fekj})fesfe
END

let snippetDef2 =<< trim END
	/begin{${0:align}}
		${1}
	/end{fin}
END

inoremap <script> <Plug>SnipExpandOrJump <Esc>:call <SID>ExpandOrJump()<CR>

" Can use <C-R>= in insmode to not move cursor
imap <unique> <expr> <Tab> <SID>ShouldTrigger() ? "\<Plug>SnipExpandOrJump"
			\ : "\<Tab>"

function s:Listener(bufnr, start, end, added, changes) abort
	" Quit early if there are no active snippets
	if b:snippet_stack->empty() | return | endif

	" Clear snippet stack if edited line not containing a placeholder
	for change in a:changes
		" Skip deletions since no efficient way to know if snippet was deleted
		if change.added < 0 | continue | endif

		for lnum in range(change.lnum, change.end + change.added - 1)
			" If the change was not to active placeholder: Quit current snippet
			let props = prop_list(lnum)->filter({_, v -> v.type ==# 'placeholder'})
			while !(b:snippet_stack->empty())
				let found = 0
				for prop in props
					if b:snippet_stack[-1]->s:HasPlaceholder(prop.id)
						let found = 1
						break
					endif
				endfor
				if found | break | endif
				call s:PopActiveSnippet()
			endwhile
		endfor
	endfor
endfunction

function s:OnBufEnter() abort
	if exists('b:snippet_stack') | return | endif
	let b:snippet_stack = []

	call listener_add(funcref('s:Listener'))
endfunction

augroup snippet
	autocmd!
	autocmd BufEnter * call s:OnBufEnter()
augroup END

nnoremap <F8> :echom prop_list(line('.'))<CR>
