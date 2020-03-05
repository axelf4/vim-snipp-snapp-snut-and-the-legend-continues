" Vim plugin for snippets
if !(has('textprop') && has("patch-8.2.324"))
	throw 'Incompatible Vim version!'
endif

highlight Placeholder ctermbg=darkblue
call prop_type_add('placeholder', #{highlight: 'Placeholder', start_incl: 1, end_incl: 1})
highlight Mirror ctermbg=darkgreen
call prop_type_add('mirror', #{highlight: 'Mirror', start_incl: 1, end_incl: 1})

let s:next_placeholder_id = 0
" Map from placeholder ID:s to their respective snippet instances.
let s:placeholder2instance = {}
let g:placeholder_values = {} " TODO Temporarily used for mirror evaluation

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
	let [bufnum, lnum, col, _, curswant] = save_cursor
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

		" Update cursor position
		if (a:lnum < lnum || a:lnum == lnum && a:col <= col)
					\ && (lnum < a:lnum || lnum == a:lnum && col < a:col) " Cursor was inside edit
			let [lnum, col] = [a:end_lnum, a:end_col] " Move cursor to end of edit
		elseif a:end_lnum < lnum || a:end_lnum == lnum && a:end_col <= col " Cursor was after edit
			if a:end_lnum == lnum
				let col += (a:text->empty() ? 0 : a:text[-1]->len())
							\ - (a:lnum == a:end_lnum ? a:end_col - a:col : a:end_col - 1)
			endif
			let lnum += a:text->len() - (a:end_lnum - a:lnum)
		endif
	finally
		call setpos('.', [bufnum, lnum, col, 0, col])
		let &selection = save_selection
	endtry
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

" Returns the text content of the textprop {prop}.
function s:PropContent(prop, lnum) abort
	" TODO Handle multiline props
	return getline(a:lnum)->strpart(a:prop.col - 1, a:prop.length)
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

" Try to expand a snippet or jump to the next tab stop.
"
" Returns false if failed.
function s:ExpandOrJump(...) abort
	if s:should_expand
		let [_, lnum, col; rest] = getcurpos()
		let col -= 2 " Take care of foo

		let snippet = s:ParseSnippets(g:snippetDef)[0]

		let g:placeholder_values = {}
		" Super suboptimal iteration for a fixed-point
		let finished = 0
		while !finished
			let finished = 1
			let builder = #{col: col, lnum: lnum, text: [""]}
			let indent = getline(lnum)->matchstr('^\s*')
			function builder.append(string) abort
				let self.text[-1] ..= a:string
				let self.col += a:string->len()
			endfunction
			function builder.new_line() abort closure
				eval self.text->add(indent)
				let self.lnum += 1
				let self.col = 1 + indent->len()
			endfunction
			" Returns the text from the specified start position to the end.
			function builder.get_text(lnum, col) abort
				let lines = self.text[-1 - (self.lnum - a:lnum):-1]
				let lines[0] = lines[0]->strpart(a:col - 1)
				return lines
			endfunction

			let [placeholders, mirrors] = [[], []]
			function! s:HandleContent(content) abort closure
				for item in a:content
					if item.type ==# 'text'
						call builder.append(item.content)
						if item->get('is_eol', 0) | call builder.new_line() | endif
					elseif item.type ==# 'placeholder'
						let [start_lnum, start_col] = [builder.lnum, builder.col]
						call s:HandleContent(item.initial)
						let g:placeholder_values[item.number] = builder.get_text(start_lnum, start_col)
									\ ->join("\n")
						eval placeholders->add(#{
									\ lnum: start_lnum, col: start_col,
									\ end_lnum: builder.lnum, end_col: builder.col,
									\ number: item.number,
									\ })
					elseif item.type ==# 'mirror'
						for dependency in snippet.mirrors[item.id].dependencies
							if !(g:placeholder_values->has_key(dependency))
								let finished = 0
								break
							endif
						endfor
						let text = finished ? eval(item.value) : ''
						let [start_lnum, start_col] = [builder.lnum, builder.col]
						call builder.append(text)
						eval mirrors->add(#{lnum: start_lnum, col: start_col,
									\ end_lnum: builder.lnum, end_col: builder.col})
					else | throw 'Bad type' | endif
				endfor
			endfunction
			call s:HandleContent(snippet.content)
		endwhile

		call s:Edit(lnum, col, lnum, col + 3, builder.text)

		let first_placeholder_id = s:next_placeholder_id
		let first_mirror_id = first_placeholder_id + placeholders->len()
		let s:next_placeholder_id += placeholders->len() + mirrors->len()
		let instance = #{
					\ snippet: snippet,
					\ first_placeholder_id: first_placeholder_id,
					\ first_mirror_id: first_mirror_id,
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

		for i in range(mirrors->len())
			let mirror = mirrors[i]
			call prop_add(mirror.lnum, mirror.col, #{
						\ end_lnum: mirror.end_lnum, end_col: mirror.end_col,
						\ type: 'mirror',
						\ id: first_mirror_id + i,
						\ })
		endfor

		eval b:snippet_stack->add(instance)
		return 1
	endif

	return s:JumpForward()
endfunction

function s:PopActiveSnippet() abort
	if b:snippet_stack->empty() | throw 'Popping empty stack?' | endif
	let instance = b:snippet_stack->remove(-1)

	for placeholder_id in range(instance.first_placeholder_id,
				\ instance.first_placeholder_id + instance.snippet.placeholders->len() - 1)
		call prop_remove(#{id: placeholder_id, all: 1})
		eval s:placeholder2instance->remove(placeholder_id)
	endfor
	for mirror_id in range(instance.first_mirror_id,
				\ instance.first_mirror_id + instance.snippet.mirrors->len() - 1)
		call prop_remove(#{id: mirror_id, all: 1})
	endfor
endfunction

" Return whether placeholder {id} belongs to snippet {instance}.
function s:HasPlaceholder(instance, id) abort
	return a:instance.first_placeholder_id <= a:id
				\ && a:instance.first_placeholder_id + a:instance.snippet.placeholders->len() - 1 >= a:id
endfunction

" Returns index of the snippet instance containing the placeholder with {id}.
function s:InstanceIdOfPlaceholder(id) abort
	for i in range(b:snippet_stack->len() - 1, 0, -1)
		if b:snippet_stack[i]->s:HasPlaceholder(a:id) | return i | endif
	endfor
	throw 'Invalid placeholder id: ' .. a:id
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

let s:NextPlaceholderId = {id, instance -> id >= instance.snippet.placeholders->len() - 1 ? 0 : id + 1}

function s:JumpForward(...) abort
	let opts = a:000->get(0, {})
	let dry_run = opts->get('dry_run', 0)

	let current_props = s:CurrentPlaceholder(line('.'), col('.'))
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

					call s:SelectProp(prop) " Leave user editing the next tab stop
					return 1
				endif
			endfor
		endwhile
	endfor

	return 0
endfunction

" Parse snippet definitions from the List {text} of lines.
"
" Uses a recursive descent parser.
function s:ParseSnippets(text) abort
	let lexer = #{text: a:text, lnum: 0, col: 0, queue: [], in_snippet: 0}
	function lexer.has_eof() abort
		return self.lnum >= self.text->len()
	endfunction
	function lexer.next_symbol() abort
		while self.queue->empty() && !self.has_eof()
			let line = self.text[self.lnum]

			if !self.in_snippet
				if line =~# '^\s*$\|^#' " Ignore line
				else
					let res = line->matchlist('^snippet')
					if res->empty() | throw 'Bad line ' .. line | endif
					let [match; rest] = res
					eval self.queue->add(#{type: 'startsnippet'})
					let self.in_snippet = 1
				endif

				let self.lnum += 1
				continue
			endif

			" TODO Allow escape sequences
			let [match, start, end] = line->matchstrpos('${\d\+:\?\|{\|}\|`[^`]\+`\|endsnippet\s*$\|$', self.col)

			let before = line->strpart(self.col, start - self.col)
			if !empty(before) | eval self.queue->add(#{type: 'text', content: before}) | endif

			if !empty(match)
				if match[0] == '{' || match[0] == '}'
					eval self.queue->add(#{type: match})
				elseif match[0] == '$'
					eval self.queue->add(#{
								\ type: 'placeholder',
								\ number: +matchstr(match, '\d\+'),
								\ has_inital: match =~# ':$',
								\ })
				elseif match[0] == '`'
					eval self.queue->add(#{type: 'mirror', value: match[1:-2]})
				elseif match =~# '^endsnippet'
					eval self.queue->add(#{type: 'endsnippet'})
					let self.in_snippet = 0
				else
					throw 'Strange match?: "' .. match .. '"'
				endif
			endif

			let self.col = end
			if end >= line->len()
				let self.lnum += 1
				let self.col = 0
				if self.in_snippet | eval self.queue->add(#{type: 'text', content: '', is_eol: 1}) | endif
			endif
		endwhile
	endfunction

	function! lexer.accept(type) abort
		if self.queue->empty() | call self.next_symbol() | endif
		if self.queue->empty() | return 0 | endif
		if self.queue[0].type ==# a:type
			return self.queue->remove(0)
		endif
		return 0
	endfunction

	function! lexer.expect(type) abort
		let token = self.accept(a:type)
		if token is 0 | throw 'Expected type: ' .. a:type .. ', found other' | endif
	endfunction

	" Parse the content of a snippet.
	function! s:ParseContent() abort closure
		let result = []
		while 1
			let item = lexer.accept('text')
			if item is 0 | let item = s:ParsePlaceholder() | endif
			if item is 0 | let item = s:ParseBracketPair() | endif
			if item is 0 | let item = s:ParseMirror() | endif
			if item is 0 | break | endif
			eval result->add(item)
		endwhile
		return result
	endfunction

	function! s:ParseBracketPair() abort closure
		let token = lexer.accept('{')
		if token is 0 | return 0 | endif
		let result = s:ParseContent()
		eval result->insert(#{type: 'text', content: '{'}, 0)
		eval result->add(#{type: 'text', content: '}'})
		call lexer.expect('}')
		return result
	endfunction

	function! s:DetectCycles(nodes) abort
		function! s:DetectCyclesGo(node) abort closure
			if a:node.color == 1 | throw 'Detected cycle!' | endif
			let a:node.color = 1
			for child_key in a:node.children
				call s:DetectCyclesGo(a:nodes[child_key])
			endfor
			let a:node.color = 2
		endfunction

		for node in a:nodes->values()
			if node.color != 0 | continue | endif
			call s:DetectCyclesGo(node)
		endfor
	endfunction

	let snippets = []
	while 1
		let token = lexer.accept('startsnippet')
		if token is 0 | break | endif

		let placeholders = {}
		let placeholder_dependants = {}
		let mirrors = []

		let placeholder_nodes = {} " Nodes in graph induced by DEPENDS ON relation
		let current_placeholder_node = v:null

		function! s:ParsePlaceholder() abort closure
			let token = lexer.accept('placeholder')
			if token is 0 | return 0 | endif
			if placeholders->has_key(token.number) | throw 'Duplicate placeholder' | endif

			if current_placeholder_node isnot v:null
				eval current_placeholder_node.children->add(token.number)
			endif
			let [prev_placeholder_node, current_placeholder_node] = [current_placeholder_node, #{color: 0, children: []}]
			let placeholder_nodes[token.number] = current_placeholder_node

			let placeholder = #{type: 'placeholder', number: token.number,
						\ initial: token.has_inital ? s:ParseContent() : [],}
			let placeholders[placeholder.number] = #{order: placeholders->len()}
			call lexer.expect('}')

			let current_placeholder_node = prev_placeholder_node
			return placeholder
		endfunction

		function! s:ParseMirror() abort closure
			let token = lexer.accept('mirror')
			if token is 0 | return 0 | endif
			let mirror_id = mirrors->len()
			let dependencies = []
			function! s:MirrorReplace(m) abort closure
				let [match, placeholder_number; rest] = a:m
				let placeholder_number = +placeholder_number

				if current_placeholder_node isnot v:null
					eval current_placeholder_node.children->add(placeholder_number)
				endif

				if !(placeholder_dependants->has_key(placeholder_number))
					let placeholder_dependants[placeholder_number] = []
				endif
				eval placeholder_dependants[placeholder_number]->add(mirror_id)
				eval dependencies->add(placeholder_number)

				return 'g:placeholder_values[' .. placeholder_number .. ']'
			endfunction
			let value = token.value->substitute('$\(\d\+\)', funcref('s:MirrorReplace'), 'g')
			eval mirrors->add(#{value: value, dependencies: dependencies})
			return #{type: 'mirror', id: mirror_id, value: value}
		endfunction

		let content = s:ParseContent()
		" Remove last EOL
		if !empty(content) && content[-1]->get('is_eol', 0) | eval content->remove(-1) | endif
		" Add tab stop #0 after snippet if needed
		if !(placeholders->has_key('0'))
			eval content->add(#{type: 'placeholder', number: 0, initial: []})
			let placeholders[0] = #{order: placeholders->len()}
			let placeholder_nodes[0] = #{color: 0, children: []}
		endif

		call s:DetectCycles(placeholder_nodes)

		call lexer.expect('endsnippet')
		eval snippets->add(#{content: content, placeholders: placeholders, mirrors: mirrors,
					\ placeholder_dependants: placeholder_dependants,
					\ })
	endwhile
	return snippets
endfunction

let snippetDef =<< trim END
	snippet
	console.log(${3:hej}, ${1:foo}, `$2`, ${2:tree}, ${4:test}, ${5:fekj})`strftime('%c') .. $1`fesfe
	endsnippet

	snippet
	\begin{${0:align}}
		${1}
	\end{fin}
	endsnippet
END

inoremap <script> <Plug>SnipExpandOrJump <Esc>:call <SID>ExpandOrJump()<CR>

" Can use <C-R>= in insmode to not move cursor?
imap <unique> <expr> <Tab> <SID>ShouldTrigger() ? "\<Plug>SnipExpandOrJump"
			\ : "\<Tab>"

let s:listener_disabled = 0
function s:Listener(bufnr, start, end, added, changes) abort
	if s:listener_disabled | return | endif
	" Quit early if there are no active snippets
	if b:snippet_stack->empty() | return | endif

	" Clear snippet stack if edited line not containing a placeholder
	for change in a:changes
		" Skip deletions since no efficient way to know if snippet was deleted
		if change.added < 0 | continue | endif

		let dirty_mirrors = []
		let cached_placeholders = {}
		let max_instance_nr = -1 " Largest snippet instance index seen
		for lnum in range(change.lnum, change.end + change.added - 1)
			let props = prop_list(lnum)->filter({_, v -> v.type ==# 'placeholder' && change.col <= v.col + v.length})
			for prop in props
				let instance_id = prop.id->s:InstanceIdOfPlaceholder()
				if instance_id > max_instance_nr | let max_instance_nr = instance_id | endif
				let instance = b:snippet_stack[instance_id]

				let dependants = instance.snippet.placeholder_dependants->get(prop.id - instance.first_placeholder_id, [])
				if !empty(dependants)
					" Store its content and add dependants to list
					let cached_placeholders[prop.id] = prop->s:PropContent(lnum)
					eval dirty_mirrors->extend(dependants->copy()->map({i, v -> #{instance: instance, id: v}}))
				endif
			endfor
		endfor

		" If the change was not to active placeholder: Quit current snippet
		for _ in range(b:snippet_stack->len() - max_instance_nr - 1) | call s:PopActiveSnippet() | endfor

		" TODO Handle case of multiple dependencies
		function! s:UpdateMirrors(timer) abort closure
			for dirty in dirty_mirrors
				let mirror_prop = prop_find(#{
							\ id: dirty.instance.first_mirror_id + dirty.id,
							\ lnum: 1,
							\ })
				let mirror = dirty.instance.snippet.mirrors[dirty.id]
				for dependency in mirror.dependencies
					let g:placeholder_values[dependency] = cached_placeholders[dirty.instance.first_placeholder_id + dependency]
				endfor

				" Re-evaluate mirror
				let text = eval(mirror.value)
				call s:Edit(mirror_prop.lnum, mirror_prop.col, mirror_prop.lnum, mirror_prop.col + mirror_prop.length,
							\ [text])
				let s:listener_disabled = 1
				try
					call listener_flush()
				finally
					let s:listener_disabled = 0
				endtry
			endfor
		endfunction
		call timer_start(0, funcref('s:UpdateMirrors'))
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
