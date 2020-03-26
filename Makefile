all: check

check:
	$(foreach test,$(wildcard test/test_*.vim),vim --clean --not-a-term -u runtest.vim "$(test)")

.PHONY: all check
