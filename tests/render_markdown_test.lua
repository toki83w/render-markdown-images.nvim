-- With the handlers registered, render-markdown produces exactly the extmarks it produces without them.
-- Needs a render-markdown.nvim checkout: $RENDER_MARKDOWN_PATH, ~/software/neovim_plugins/render-markdown.nvim
-- or lazy.nvim's data dir. Set RMI_REQUIRE_RENDER_MARKDOWN=1 to fail instead of skip when it is missing.
-- Run: nvim --headless -u NONE --noplugin -l tests/render_markdown_test.lua

package.path = vim.fn.getcwd() .. "/?.lua;" .. package.path
local h = require "tests.harness"

local rm_path = h.find_plugin("RENDER_MARKDOWN_PATH", "render-markdown.nvim")
if not rm_path then
  if vim.env.RMI_REQUIRE_RENDER_MARKDOWN == "1" then
    print "render_markdown_test: FAIL: render-markdown.nvim not found"
    os.exit(1)
  end
  print "render_markdown_test: skip (render-markdown.nvim not found)"
  os.exit(0)
end

vim.opt.rtp:prepend(rm_path)
vim.cmd.runtime "plugin/render-markdown.lua"

vim.o.columns = 80
vim.o.lines = 40
vim.o.laststatus = 0

local rmi = require "render-markdown-images"
local rm = require "render-markdown"

local LINES = {
  "# Title",
  "",
  "Some `inline` text with an image ![alt](test.png) and a [link](https://example.com).",
  "",
  "![alone](other.png)",
  "",
  "![[wiki embed.png|300]]",
  "",
  "- item one",
  "  - nested ![x](nested.png)",
  "",
  "> quote with ![q](quote.png)",
  "",
  "```mermaid",
  "graph TD; A-->B",
  "```",
  "",
  "```plantuml",
  "@startuml",
  "A -> B",
  "@enduml",
  "```",
  "",
  "```lua",
  "print('hi')",
  "```",
  "",
  "| a | b |",
  "| - | - |",
  "| 1 | 2 |",
}

--- Render LINES with the given render-markdown options and return the extmarks it placed.
---@param opts table
---@return table[]
local function render(opts)
  rm.setup(vim.tbl_deep_extend("force", { anti_conceal = { enabled = false } }, opts))
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, LINES)
  vim.bo[buf].filetype = "markdown"
  vim.treesitter.start(buf, "markdown")
  vim.wait(0)
  rm.render { buf = buf, force = true }
  vim.wait(200, function()
    return false
  end)
  local ns = vim.api.nvim_create_namespace "render-markdown.nvim"
  local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
  -- Extmark ids and ns_id differ between runs; compare position and options only.
  local out = {}
  for _, m in ipairs(marks) do
    local d = vim.deepcopy(m[4])
    d.ns_id = nil
    out[#out + 1] = { m[2], m[3], d }
  end
  table.sort(out, function(a, b)
    return vim.inspect(a) < vim.inspect(b)
  end)
  vim.api.nvim_buf_delete(buf, { force = true })
  return out
end

h.test("handlers do not change render-markdown's extmarks", function()
  local baseline = render {}
  h.assert_eq(#baseline > 20, true, "baseline produced extmarks (got " .. #baseline .. ")")

  local calls = {}
  local handlers = rmi.handlers()
  for lang, handler in pairs(handlers) do
    local parse = handler.parse
    handler.parse = function(ctx)
      calls[lang] = (calls[lang] or 0) + 1
      return parse(ctx)
    end
  end

  local with_handlers = render { custom_handlers = handlers }
  h.assert_eq((calls.markdown or 0) > 0, true, "markdown handler was invoked")
  h.assert_eq((calls.markdown_inline or 0) > 0, true, "markdown_inline handler was invoked")
  h.assert_eq(with_handlers, baseline, "identical extmarks with and without handlers")
end)

h.test("registered after setup(): same marks as well", function()
  rmi.setup { images = { mode = "replace" }, diagrams = { mode = "replace" } }
  local baseline = render {}
  h.assert_eq(render { custom_handlers = rmi.handlers() }, baseline, "mode = replace is inert in task 1")
end)

h.finish "render_markdown_test"
