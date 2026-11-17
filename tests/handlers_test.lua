-- handlers() shape.
-- Run: nvim --headless -u NONE --noplugin -l tests/handlers_test.lua

package.path = vim.fn.getcwd() .. "/?.lua;" .. package.path
local h = require "tests.harness"
local rmi = require "render-markdown-images"

h.test("handlers() covers markdown and markdown_inline only", function()
  local handlers = rmi.handlers()
  local langs = vim.tbl_keys(handlers)
  table.sort(langs)
  h.assert_eq(langs, { "markdown", "markdown_inline" }, "languages")
end)

h.test("each handler extends the builtin one and parses to no marks", function()
  for lang, handler in pairs(rmi.handlers()) do
    h.assert_eq(handler.extends, true, lang .. ".extends")
    h.assert_eq(type(handler.parse), "function", lang .. ".parse is a function")
    h.assert_eq(handler.parse { buf = 0, root = nil, last = true }, {}, lang .. ".parse returns {}")
    local keys = vim.tbl_keys(handler)
    table.sort(keys)
    h.assert_eq(keys, { "extends", "parse" }, lang .. " has only the keys render-markdown accepts")
  end
end)

h.test("handlers() returns independent tables", function()
  local a, b = rmi.handlers(), rmi.handlers()
  a.markdown.extends = false
  h.assert_eq(b.markdown.extends, true, "mutating one result does not affect another")
end)

h.test("handlers() works without setup()", function()
  package.loaded["render-markdown-images.config"] = nil
  h.assert_eq(type(require("render-markdown-images").handlers().markdown.parse), "function", "usable")
end)

h.finish "handlers_test"
