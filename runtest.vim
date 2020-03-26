set nocompatible
let s:test_file = expand('%')

function s:CheckErrors() abort
	if v:errors->empty() | return | endif
	echo s:test_file .. ':1:Error'
	for s:error in v:errors
		echo s:error
	endfor
	cquit!
endfunction

try
	execute 'cd' fnamemodify(resolve(expand('<sfile>:p')), ':h')
	source plugin/snippet.vim
	set runtimepath^=.

	source %
	" Query list of functions matching ^Test_
	let s:tests = execute('function /^Test_')->split("\n")->map('matchstr(v:val, ''function \zs\k\+\ze()'')')

	for s:test_function in s:tests
		%bwipeout!
		echo 'Test' s:test_function
		execute 'call' s:test_function '()'
		call s:CheckErrors()
	endfor
catch
	eval v:errors->add("Uncaught exception: " .. v:exception .. " at " .. v:throwpoint)
	call s:CheckErrors()
endtry

quit!
