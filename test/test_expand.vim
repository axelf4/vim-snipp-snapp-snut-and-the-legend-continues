function Test_ExpandPlaintext() abort
	call Expand(ParseSnippet(['foo']), [''])
	call assert_equal(['foo'], getline(1, '$'))
endfunction
