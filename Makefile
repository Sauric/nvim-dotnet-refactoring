NVIM ?= nvim
INIT  = tests/minimal_init.lua
SPECS = tests/spec

.PHONY: test

test:
	$(NVIM) --headless --noplugin -u $(INIT) \
		-c "lua require('plenary.test_harness').test_directory('$(SPECS)', { minimal_init = '$(INIT)' })" \
		-c "qa!"
