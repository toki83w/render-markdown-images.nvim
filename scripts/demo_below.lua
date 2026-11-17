-- Demo: images below their lines, in a real Neovim with render-markdown.nvim.
--
--   nvim -u scripts/demo_below.lua scripts/demo_below.md
--
-- Run it in a terminal that speaks the Kitty graphics protocol (foot, kitty, WezTerm, Ghostty, ...),
-- directly or in tmux (>= 3.3, `set -g allow-passthrough on`). render-markdown.nvim is taken from
-- $RENDER_MARKDOWN_PATH, ~/software/neovim_plugins/render-markdown.nvim, or lazy.nvim's data directory.
-- Edit the document, resize the window, `:set number`: the images follow.

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

local function find_render_markdown()
  for _, dir in ipairs {
    vim.env.RENDER_MARKDOWN_PATH or "",
    vim.fn.expand "~/software/neovim_plugins/render-markdown.nvim",
    vim.fn.stdpath "data" .. "/lazy/render-markdown.nvim",
  } do
    if dir ~= "" and vim.fn.isdirectory(dir .. "/lua") == 1 then return dir end
  end
  error "render-markdown.nvim not found: set $RENDER_MARKDOWN_PATH"
end

vim.opt.rtp:prepend(find_render_markdown())
vim.opt.rtp:prepend(root)
vim.cmd.runtime "plugin/render-markdown.lua"

vim.o.termguicolors = true
vim.o.ambiwidth = "single"
vim.o.wrap = true

require("render-markdown-images").setup {}
require("render-markdown").setup {
  custom_handlers = require("render-markdown-images").handlers(),
}

vim.api.nvim_create_autocmd("FileType", {
  pattern = "markdown",
  callback = function(args)
    vim.treesitter.start(args.buf)
  end,
})
