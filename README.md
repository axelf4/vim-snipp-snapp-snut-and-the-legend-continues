# vim-snipp-snapp-snut-and-the-legend-continues
![](https://github.com/axelf4/vim-snipp-snapp-snut-and-the-legend-continues/workflows/CI/badge.svg)

Experimental Vim plugin utilizing text properties to track placeholder text.

Aims to be a modern [UltiSnips] alternative without the Python dependency, nor the complexity from trying to track buffer changes, which is offloaded to Vim via textprops. Current deficiencies in textprops mean that placeholders cannot span multiple lines, but this will be fixed in the future.

Checkout the [documentation][doc].

[doc]: doc/SnippSnapp.txt
[UltiSnips]: https://github.com/SirVer/ultisnips
