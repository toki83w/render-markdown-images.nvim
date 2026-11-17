-- Luacheck configuration for render-markdown-images.nvim
-- Docs: https://luacheck.readthedocs.io/en/stable/config.html

-- Neovim embeds LuaJIT.
std = "luajit"
cache = true

-- Globals injected at runtime by Neovim.
read_globals = { "vim" }

-- `vim.<subtable>.foo = ...` assignments are legitimate. Declaring the mutable
-- subtables as writable globals stops luacheck reporting them as writes to a
-- read-only field of the `vim` global.
globals = {
  "vim.g",
  "vim.b",
  "vim.w",
  "vim.o",
  "vim.bo",
  "vim.wo",
  "vim.go",
  "vim.env",
  "vim.opt",
}

-- Line width is owned by StyLua (column_width in .stylua.toml). A few string
-- literals legitimately exceed it and cannot be wrapped.
ignore = { "631" }

exclude_files = { "tests/fixtures/", "lua/render-markdown-images/vendor/" }

-- Tests intentionally destructure unused return values, shadow module upvalues,
-- and monkeypatch vim.* functions when mocking.
files["tests/"] = {
  ignore = {
    "211", -- unused local variable
    "212", -- unused argument
    "431", -- shadowing an upvalue
    "122", -- setting a read-only field of vim (mocking vim.notify, vim.api.*)
  },
}
