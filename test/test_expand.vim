function Test_ExpandPlaintext() abort
	call Expand(ParseSnippet(['foo']), [''])
	call assert_equal(['foo'], getline(1, '$'))
endfunction

function Test_NestedPlaceholders() abort
	let snippetBody =<< trim END
	<a href="${1:http://www.${2:example.com}}">
		${0}
	</a>
	END
	let snippet = ParseSnippet(snippetBody)

	call Expand(snippet, [''])
	call feedkeys("foo\<Tab>bar", 'tx')
	call assert_equal(['<a href="foo">', "\tbar", '</a>'], getline(1, '$'))

	%bwipeout!

	call Expand(snippet, [''])
	call feedkeys("\<Tab>foo\<Tab>bar", 'tx')
	call assert_equal(['<a href="http://www.foo">', "\tbar", '</a>'], getline(1, '$'))
endfunction
