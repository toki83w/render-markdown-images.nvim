-- Demo: images below their lines, in a real Neovim with render-markdown.nvim.
--
--   nvim -u scripts/demo_below.lua scripts/demo_below.md
--   RMI_MODE=replace nvim -u scripts/demo_below.lua scripts/demo_below.md
--   nvim -u scripts/demo_below.lua tests/fixtures/vault/notes/note.md   (an Obsidian vault)
--
-- With RMI_MODE=replace the source of every image and diagram is hidden and the picture takes its place;
-- put the cursor on it and the source comes back, move away and the picture returns.
--
-- Run it in a terminal that speaks the Kitty graphics protocol (foot, kitty, WezTerm, Ghostty, ...),
-- directly or in tmux (>= 3.3, `set -g allow-passthrough on`). The terminal is not asked whether it can:
-- having the plugin configured says so. `:Diagnose` reports what it would answer. render-markdown.nvim is taken from
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

local mode = vim.env.RMI_MODE or "below"
require("render-markdown-images").setup {
  images = { mode = mode },
  diagrams = { mode = mode },
}
require("render-markdown").setup {
  custom_handlers = require("render-markdown-images").handlers(),
}

vim.api.nvim_create_autocmd("FileType", {
  pattern = "markdown",
  callback = function(args)
    vim.treesitter.start(args.buf)
  end,
})

-- ============================================================================
-- :Diagnose — what this plugin knows, for when no image shows
-- ============================================================================

-- Keep a short record of the Kitty graphics commands that leave Neovim. Only this demo does it.
local sent = {}
local ui_send = vim.api.nvim_ui_send
vim.api.nvim_ui_send = function(data)
  for seq in data:gmatch "\27_G([^\27]*)" do
    sent[#sent + 1] = seq:gsub("^(.-);.*$", "%1")
  end
  return ui_send(data)
end

vim.api.nvim_create_user_command("Diagnose", function()
  local image = require "render-markdown-images.image"
  local store = require "render-markdown-images.store"
  local log = require "render-markdown-images.log"
  local out = {}
  local function add(fmt, ...)
    out[#out + 1] = fmt:format(...)
  end

  add "render-markdown-images diagnosis"
  add ""
  add("nvim %s", tostring(vim.version()))
  add("$TERM = %s, $TMUX = %s", vim.env.TERM or "-", vim.env.TMUX and "set" or "-")
  add(
    "termguicolors = %s, ambiwidth = %s, conceallevel = %s",
    tostring(vim.o.termguicolors),
    vim.o.ambiwidth,
    vim.wo.conceallevel
  )
  add("UIs attached: %d", #vim.api.nvim_list_uis())
  if vim.env.TMUX then
    add("tmux allow-passthrough = %s", vim.trim(vim.fn.system { "tmux", "show-options", "-gv", "allow-passthrough" }))
    add(
      "tmux client features = %s",
      vim.trim(vim.fn.system { "tmux", "display-message", "-p", "#{client_termname}: #{client_termfeatures}" })
    )
  end
  add ""
  add(
    "terminal's answer     = %s   (asked just now; nothing else asks. Through tmux it can be no_reply although images work)",
    image.probe()
  )
  add("image.in_tmux()        = %s", tostring(image.in_tmux()))
  local cell = image.get_cell_size()
  add(
    "cell size             = %s",
    cell and ("%.1f x %.1f px"):format(cell.cell_w, cell.cell_h) or "unknown (a fixed 20x10 cells is used)"
  )
  add(
    "config                = %s",
    vim.inspect(require("render-markdown-images.config").get(), { newline = " ", indent = "" })
  )
  add("can_replace()         = %s", tostring(require("render-markdown-images.handlers").can_replace()))
  add ""
  add("store (%s):", vim.inspect(store.stats(), { newline = " ", indent = "" }))
  for _, e in ipairs(store.snapshot()) do
    add("  %-8s %-7s attempts=%d id=%s %s", e.kind, e.status, e.attempts, tostring(e.id), e.err or "")
    add("           %s", e.key)
  end
  add ""
  local ns = vim.api.nvim_create_namespace "render-markdown.nvim"
  local images, concealed = 0, 0
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, { details = true })) do
    local lines = m[4].virt_lines
    if lines and lines[1] and lines[1][#lines[1]][2]:find "^RenderMdImg_" then images = images + 1 end
    if m[4].conceal_lines then concealed = concealed + 1 end
  end
  add("marks in this buffer: %d with an image, %d concealing rows", images, concealed)
  add("graphics commands sent so far (%d), last 8:", #sent)
  for i = math.max(1, #sent - 7), #sent do
    add("  %s", sent[i])
  end
  add ""
  add("log %s:", log.path())
  for _, line in ipairs(log.recent()) do
    add("  %s", line)
  end

  vim.cmd "botright new"
  vim.bo.buftype, vim.bo.bufhidden, vim.bo.swapfile, vim.bo.filetype = "nofile", "wipe", false, "text"
  vim.api.nvim_buf_set_lines(0, 0, -1, false, out)
  vim.bo.modifiable = false
end, { desc = "Report what render-markdown-images knows about this session" })
