" Vim plugin for snippets
if !(has('textprop') && has("patch-8.2.324") && has("patch-8.2.357")
			\ && has("patch-8.2.372"))
	throw 'Incompatible Vim version!'
endif

if exists('g:loaded_snipp_snapp_snut') | finish | endif
let g:loaded_snipp_snapp_snut = 1

call prop_type_add('placeholder', #{start_incl: 1, end_incl: 1})
call prop_type_add('mirror', #{start_incl: 1, end_incl: 1})

let s:next_prop_id = 0
let g:placeholder_values = {} " TODO Temporarily used for mirror evaluation
let s:snippets_by_ft = {}

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
	let [bufnum, lnum, col, _, curswant] = getcurpos()
	execute printf('keeppatterns %dsubstitute/\%%%dc\_.*\%%%dl\%%%dc/%s',
				\ a:lnum, a:col, a:end_lnum, a:end_col, a:text->join("\<CR>")->escape('/\'))

	" Update cursor position
	if (a:lnum < lnum || a:lnum == lnum && a:col <= col)
				\ && (lnum < a:lnum || lnum == a:lnum && col < a:col) " Cursor was inside edit
		let [lnum, col] = [a:end_lnum, a:end_col] " Move cursor to end of edit
	elseif a:end_lnum < lnum || a:end_lnum == lnum && a:end_col <= col " Cursor was after edit
		if a:end_lnum == lnum
			let col += (a:text->empty() ? 0 : a:text[-1]->len())
						\ - (a:end_col - (a:lnum == a:end_lnum ? a:col : 1))
		endif
		let lnum += a:text->len() - (a:end_lnum - a:lnum) - 1
	endif
	call setpos('.', [bufnum, lnum, col, 0, col])
endfunction

" Start Select mode with the specified area.
"
" The implementation is terrible to support CTRL-R =.
function s:Select(lnum, col, end_lnum, end_col) abort
	" TODO Handle all cases of &selection
	let save_virtualedit = &virtualedit
	let zero_len = a:lnum == a:end_lnum && a:col == a:end_col
	call feedkeys((mode() !=# 'n' ? "\<Esc>" : '')
				\ .. ':set virtualedit=onemore | call cursor(' .. a:lnum .. ',' .. a:col .. ")\<CR>"
				\ .. (zero_len ? "i\<C-O>:set virtualedit=" .. save_virtualedit .. "\<CR>"
				\ : "v:\<C-U>call cursor(" .. a:end_lnum .. ',' .. a:end_col .. ")\<CR>\<C-H>:set virtualedit=" .. save_virtualedit .. "\<CR>v`<\<C-G>"),
				\ 'n')
endfunction

" Search for property with {id} starting after/before {ref} on {lnum}.
"
" If {direction} > 0: Search forward; if < 0: Backward.
function s:PropFindRelative(ref, id, lnum, direction) abort
	" FIXME Cannot provide a type='placeholder/mirror' here because it is an OR...
	" Careful: ref might span many lines with match above lnum
	let start = a:direction < 0 || a:ref.start ? a:ref
				\ : prop_find(#{id: a:ref.id, lnum: a:lnum, col: a:ref.col}, 'b')
	return prop_find(#{id: a:id, lnum: start->get('lnum', a:lnum), col: start.col},
				\ a:direction < 0 ? 'b' : 'f')
endfunction

function s:SelectProp(prop) abort
	" TODO Add support for multiline props
	call s:Select(a:prop.lnum, a:prop.col, a:prop.lnum, a:prop.col + a:prop.length)
endfunction

" Returns the text content of the textprop {prop}.
function s:PropContent(prop, lnum) abort
	" TODO Handle multiline props
	return getline(a:lnum)->strpart(a:prop.col - 1, a:prop.length)
endfunction

function s:Flatten(list) abort
	let result = []
	for item in a:list | eval result->extend(item) | endfor
	return result
endfunction

function s:FlatMap(list, F) abort
	let result = []
	for item in a:list | eval result->extend(a:F(item)) | endfor
	return result
endfunction

" Tests if every element of {list} matches the predicate {F}.
function s:All(list, F) abort
	for item in a:list | if !a:F(item) | return 0 | endif | endfor
	return 1
endfunction

" Return the snippets whose trigger matches at the cursor and their matches.
function s:PossibleSnippets() abort
	let snippets = []
	let [line, col] = [getline('.'), col('.')]
	for snippet in s:SnippetFiletypes()->s:FlatMap({ft -> s:snippets_by_ft->get(ft, [])})
		let match = line->matchlist(printf('\%%(%s\)\%%%dc', snippet.trigger, col))
		if !empty(match)
			eval snippets->add([snippet, match])
		endif
	endfor
	return snippets
endfunction

" Try to expand a snippet or jump to the next tab stop.
"
" Returns false if failed.
function s:ExpandOrJump() abort
	let possible = s:PossibleSnippets()
	return !empty(possible) ? s:Expand(possible[0][0], possible[0][1]) : s:Jump()
endfunction

" Expand {snippet} at the cursor location.
function s:Expand(snippet, match) abort
	let [_, lnum, col; rest] = getcurpos()
	let length = a:match[0]->len()
	let col -= length

	let cached_placeholders = {}
	let instance = #{
				\ snippet: a:snippet, match: a:match,
				\ cached_placeholders: cached_placeholders, dirty_mirrors: {},
				\ }
	" Suboptimal iteration for a fixed-point
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
					if !empty(a:snippet.placeholder_dependants->get(item.number, []))
						let cached_placeholders[item.number] = builder.get_text(start_lnum, start_col)
									\ ->join("\n")
					endif
					eval placeholders->add(#{
								\ lnum: start_lnum, col: start_col,
								\ end_lnum: builder.lnum, end_col: builder.col,
								\ number: item.number,
								\ })
				elseif item.type ==# 'mirror'
					let mirror = a:snippet.mirrors[item.id]
					if !(mirror.dependencies->s:All({v -> cached_placeholders->has_key(v)}))
						let finished = 0
					endif
					let text = finished ? mirror->s:EvalMirror(instance) : ''
					let [start_lnum, start_col] = [builder.lnum, builder.col]
					call builder.append(text)
					if !empty(mirror.dependencies)
						eval mirrors->add(#{id: item.id, lnum: start_lnum, col: start_col,
									\ end_lnum: builder.lnum, end_col: builder.col})
					endif
				else | throw 'Bad type' | endif
			endfor
		endfunction
		call s:HandleContent(a:snippet.content)
	endwhile

	call s:Edit(lnum, col, lnum, col + length, builder.text)

	let instance.first_placeholder_id = s:next_prop_id
	let instance.first_mirror_id = instance.first_placeholder_id + placeholders->len()
	let s:next_prop_id += placeholders->len() + a:snippet.mirrors->len()

	if placeholders->len() == 1 " Jump to last placeholder
		let prop_zero = placeholders[0]
		call s:Select(prop_zero.lnum, prop_zero.col, prop_zero.end_lnum, prop_zero.end_col)
	else
		let first_placeholder = placeholders->len() > 1 ? 1 : 0
		for placeholder in placeholders
			let placeholder_id = instance.first_placeholder_id + placeholder.number
			call prop_add(placeholder.lnum, placeholder.col, #{
						\ end_lnum: placeholder.end_lnum, end_col: placeholder.end_col,
						\ type: 'placeholder', id: placeholder_id,
						\ })
			if placeholder.number == first_placeholder
				call s:Select(placeholder.lnum, placeholder.col,
							\ placeholder.end_lnum, placeholder.end_col)
			endif
		endfor

		for mirror in mirrors
			call prop_add(mirror.lnum, mirror.col, #{
						\ end_lnum: mirror.end_lnum, end_col: mirror.end_col,
						\ type: 'mirror', id: instance.first_mirror_id + mirror.id,
						\ })
		endfor

		eval b:snippet_stack->add(instance)
	endif
	return 1
endfunction

function s:PopActiveSnippet() abort
	if b:snippet_stack->empty() | throw 'Popping empty stack?' | endif
	let instance = b:snippet_stack->remove(-1)
	for placeholder_id in range(instance.first_placeholder_id,
				\ instance.first_placeholder_id + instance.snippet.placeholders->len() - 1)
		call prop_remove(#{id: placeholder_id, type: 'placeholder', both: 1, all: 1})
	endfor
	for mirror_id in range(instance.first_mirror_id,
				\ instance.first_mirror_id + instance.snippet.mirrors->len() - 1)
		call prop_remove(#{id: mirror_id, type: 'mirror', both: 1, all: 1})
	endfor
endfunction

" Return whether placeholder {id} belongs to snippet {instance}.
function s:HasPlaceholder(instance, id) abort
	return a:instance.first_placeholder_id <= a:id
				\ && a:id < a:instance.first_placeholder_id + a:instance.snippet.placeholders->len()
endfunction

" Return the index of the snippet instance containing the placeholder with {id} or -1.
function s:InstanceIdOfPlaceholder(id) abort
	for i in range(b:snippet_stack->len() - 1, 0, -1)
		if b:snippet_stack[i]->s:HasPlaceholder(a:id) | return i | endif
	endfor
	return -1
endfunction

let s:NextPlaceholderId = {id, instance -> id >= instance.snippet.placeholders->len() - 1 ? 0 : id + 1}

function s:Jump() abort
	let [lnum, col] = [line('.'), col('.')]
	" Get all placeholders that contain cursor sorted after specificity
	let current_props = prop_list(lnum)->filter({_, v -> v.type ==# 'placeholder'
				\ && v.col <= col && col <= v.col + v.length})
				\ ->sort({a, b -> b.id - a.id})
	for placeholder_prop in current_props
		while 1
			if b:snippet_stack->empty() " Undo etc can cause stray placeholder props
				call prop_remove(#{type: 'placeholder', all: 1})
				return
			endif
			if b:snippet_stack[-1]->s:HasPlaceholder(placeholder_prop.id) | break | endif
			call s:PopActiveSnippet()
		endwhile
		let instance = b:snippet_stack[-1]
		let number = placeholder_prop.id - instance.first_placeholder_id

		while number > 0
			let next = s:NextPlaceholderId(number, instance)
			let direction = instance.snippet.placeholders[next].order
						\ - instance.snippet.placeholders[number].order
			let prop = placeholder_prop->s:PropFindRelative(instance.first_placeholder_id + next,
						\ lnum, direction)
			" If jumping to last placeholder: Snippet is done!
			if next == 0 | call s:PopActiveSnippet() | endif

			if !empty(prop) " Found property to jump to!
				call s:SelectProp(prop) " Leave user editing the next tab stop
				return 1
			endif
			let number = next
		endwhile
	endfor
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
				if line !~# '^\s*$\|^#' " Ignore empty lines and comment
					let res = line->matchlist('^snippet\s\+\(.\)\(\%(\1\@!.\)*\)\@>\1\%(\s\+"\([^"]*\)"\)\?')
					if res->empty() | throw 'Bad line ' .. line | endif
					let [match, _, trigger, desc; rest] = res
					eval self.queue->add(#{type: 'startsnippet', trigger: trigger, description: desc})
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
			if v:t_list == item->type()
				eval result->extend(item)
			else
				eval result->add(item)
			endif
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

	function! s:AssertNoCycle(nodes) abort
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
		let startsnippet_token = lexer.accept('startsnippet')
		if startsnippet_token is 0 | break | endif

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

			let placeholders[token.number] = #{order: placeholders->len() + mirrors->len()}
			let placeholder = #{type: 'placeholder', number: token.number,
						\ initial: token.has_inital ? s:ParseContent() : [],}
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
			eval mirrors->add(#{value: value, dependencies: dependencies,
						\ order: placeholders->len() + mirrors->len()})
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

		call s:AssertNoCycle(placeholder_nodes)

		call lexer.expect('endsnippet')
		eval snippets->add(#{content: content, placeholders: placeholders, mirrors: mirrors,
					\ placeholder_dependants: placeholder_dependants,
					\ trigger: startsnippet_token.trigger, description: startsnippet_token.description,
					\ })
	endwhile
	return snippets
endfunction

let s:listener_disabled = 0
function s:Listener(bufnr, start, end, added, changes) abort
	if b:snippet_stack->empty() | return | endif " Quit early if there are no active snippets

	let max_instance_nr = -1 " Largest snippet instance index seen
	for change in a:changes
		" Skip deletions since no efficient way to know if snippet was deleted
		if change.added < 0 | continue | endif

		for lnum in range(change.lnum, change.end + change.added - 1)
			for prop in prop_list(lnum)
				if prop.type !=# 'placeholder' || prop.col + prop.length < change.col | continue | endif
				let instance_id = prop.id->s:InstanceIdOfPlaceholder()
				if instance_id == -1
					" Undo can re-add old props, if so: Remove them
					call prop_remove(#{id: prop.id, type: 'placeholder', both: 1}, lnum)
					continue
				endif
				if instance_id > max_instance_nr | let max_instance_nr = instance_id | endif
				let instance = b:snippet_stack[instance_id]

				let placeholder_number = prop.id - instance.first_placeholder_id
				let dependants = instance.snippet.placeholder_dependants->get(placeholder_number, [])
				if !empty(dependants)
					let new_content = prop->s:PropContent(lnum)
					if new_content ==# instance.cached_placeholders[placeholder_number] | continue | endif
					" Store its content and add dependants to list with ref
					let instance.cached_placeholders[placeholder_number] = new_content
					for dependant in dependants
						let instance.dirty_mirrors[dependant] = #{prop: prop, lnum: lnum}
					endfor
				endif
			endfor
		endfor
	endfor

	if !s:listener_disabled
		" If the change was not to active placeholder: Quit current snippet
		for _ in range(b:snippet_stack->len() - max_instance_nr - 1) | call s:PopActiveSnippet() | endfor
	endif

	call timer_start(0, funcref('s:UpdateMirrors'))
endfunction

function s:EvalMirror(mirror, instance) abort
	for dependency in a:mirror.dependencies
		let g:placeholder_values[dependency] = a:instance.cached_placeholders->get(dependency, '')
	endfor
	let g:m = a:instance.match
	echom g:m
	return eval(a:mirror.value)
endfunction

function s:UpdateMirrors(timer) abort
	for instance in b:snippet_stack
		for [dirty, ref] in instance.dirty_mirrors->items()
			let mirror = instance.snippet.mirrors[dirty]
			let placeholder = instance.snippet.placeholders[ref.prop.id - instance.first_placeholder_id]
			let direction = mirror.order - placeholder.order
			let mirror_prop = ref.prop->s:PropFindRelative(instance.first_mirror_id + dirty,
						\ ref.lnum, direction)
			if mirror_prop->empty() | continue | endif " Might have been deleted

			let text = mirror->s:EvalMirror(instance)
			call s:Edit(mirror_prop.lnum, mirror_prop.col, mirror_prop.lnum,
						\ mirror_prop.col + mirror_prop.length, [text])
		endfor
		let instance.dirty_mirrors = {}
	endfor
	let s:listener_disabled = 1
	try
		call listener_flush()
	finally
		let s:listener_disabled = 0
	endtry
endfunction

function s:OnBufEnter() abort
	if exists('b:snippet_stack') | return | endif
	let b:snippet_stack = []
	call listener_add(funcref('s:Listener'))
endfunction

let s:SnippetFiletypes = {-> split(&filetype, '\.') + ['all']}
let s:SourcesForFiletype = {ft -> printf('SnippSnapp/**/%s.snippets', ft)->globpath(&runtimepath, 1, 1)}

function s:SourceSnippetFile() abort
	let file = expand('<afile>:p')
	let ft = file->fnamemodify(':t:r')
	let s:snippets_by_ft[ft] = readfile(file)->s:ParseSnippets()
endfunction

function s:EnsureSnippetsLoaded(filetype) abort
	" TODO Handle multiple files for single filetype
	for snippet_file in a:filetype->split('\.')->filter({_, v -> !(s:snippets_by_ft->has_key(v))})
				\ ->s:FlatMap({ft -> s:SourcesForFiletype(ft)})
		execute 'source' snippet_file
	endfor
endfunction

function s:SnippetEdit(mods) abort
	let file = s:SnippetFiletypes()->s:FlatMap({ft -> s:SourcesForFiletype(ft)})->get(0,
				\ printf('%s/%s.snippets', &runtimepath->split(',')[0], s:SnippetFiletypes()[0]))
	execute a:mods 'split' file
	augroup snippet_def_buffer
		autocmd!
		autocmd BufWritePost <buffer> ++nested source <afile>
	augroup END
endfunction

command -bar SnippetEdit call s:SnippetEdit(<q-mods>)

augroup snippet
	autocmd!
	autocmd BufEnter * call s:OnBufEnter()
	autocmd SourceCmd *.snippets call s:SourceSnippetFile()
	autocmd FileType * call s:EnsureSnippetsLoaded('<amatch>')
augroup END

inoremap <script> <unique> <Plug>SnipExpandOrJump <C-R>=<SID>ExpandOrJump()<CR>

inoremap <silent> <unique> <Tab> <C-R>=<SID>ExpandOrJump() ? '' : "\<Tab>"<CR>
snoremap <unique> <Tab> <Esc>:call <SID>Jump()<CR>

call s:EnsureSnippetsLoaded('all')

nnoremap <F8> :echom prop_list(line('.'))<CR>
