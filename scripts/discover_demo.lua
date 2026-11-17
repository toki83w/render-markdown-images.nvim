-- Demo: print what render-markdown-images.nvim finds in markdown files.
--
--   nvim --headless -u NONE --cmd 'set rtp^=.' -l scripts/discover_demo.lua [file.md ...]
--
-- Without arguments it reads the two fixtures in tests/fixtures. For each file it lists the
-- images (`inline`) and the diagram fences (`fences`) that `discover` returns, one per line.

local discover = require "render-markdown-images.discover"

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local files = #arg > 0 and arg or { root .. "/tests/fixtures/showcase.md", root .. "/tests/fixtures/wikilinks.md" }

local function out(text)
  io.stdout:write(text, "\n")
end

for _, file in ipairs(files) do
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.fn.readfile(file))
  vim.bo[buf].filetype = "markdown"
  vim.treesitter.start(buf, "markdown")
  local parser = vim.treesitter.get_parser(buf, "markdown")
  parser:parse(true)

  out(("== %s"):format(vim.fn.fnamemodify(file, ":~:.")))
  parser:for_each_tree(function(tree, language_tree)
    local lang = language_tree:lang()
    if lang == "markdown_inline" then
      for _, item in ipairs(discover.inline(buf, tree:root())) do
        out(
          ("image  %3d:%-3d-%3d:%-3d %-34s indent=%d%s%s%s"):format(
            item.row + 1,
            item.col,
            item.end_row + 1,
            item.end_col,
            vim.inspect(item.src),
            item.indent,
            item.alone_on_line and " alone" or "",
            item.embed and " embed" or "",
            item.in_table and " table" or ""
          )
        )
      end
    elseif lang == "markdown" then
      for _, item in ipairs(discover.fences(buf, tree:root())) do
        out(
          ("%-7s %3d-%-3d indent=%d  %s"):format(
            item.kind,
            item.start_row + 1,
            item.end_row + 1,
            item.indent,
            vim.inspect(item.source)
          )
        )
      end
    end
  end)
end
