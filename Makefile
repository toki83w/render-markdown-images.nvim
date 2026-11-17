NVIM := nvim --headless -u NONE --noplugin

TEST_FILES := $(sort $(wildcard tests/*_test.lua))

.PHONY: test $(TEST_FILES) lint format check

test: $(TEST_FILES)

$(TEST_FILES):
	$(NVIM) -l $@ </dev/null

# Format Lua sources in place (honors .stylua.toml).
format:
	stylua .

# Local gate: formatting check. Luacheck runs where available (`luacheck .`).
lint:
	stylua --check .

check: lint test
