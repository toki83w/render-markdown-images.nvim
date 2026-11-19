--- What the plugin does when the world around the images changes, and when it ends.
---
--- Images are drawn at a size that depends on the window, in colours that depend on the colorscheme, and they
--- live in the terminal until somebody deletes them. So:
---
---  - A window that changes size, or an option that changes the width of its text (`number`, `signcolumn`, ...),
---    has its buffer rendered again, which draws the images at the new size. render-markdown does not run the
---    handlers again for this by itself.
---  - The placements the old size left behind are deleted once nothing uses them.
---  - `:colorscheme` clears the highlight groups that carry the image ids: they are defined again. Mermaid
---    diagrams are drawn in the editor's colours, so those that were made under other colours are made again.
---  - A buffer that goes away stops being owed a render and stops using placements.
---  - On exit the images this instance sent are deleted, and only those: other Neovims in the same terminal
---    have images of their own there.
---
--- The autocommands are made when the first handler runs, or by `setup()`, whichever comes first.

---@class render-markdown-images.Lifecycle
local M = {}

local GROUP = "render-markdown-images"

--- How long to wait before deleting placements nobody uses (ms). The cells that still show them are replaced
--- by the render that made them unused; deleting first would blank them for a moment.
local PRUNE_DELAY = 200

---@type table<integer, true> buffers that have marks of ours
local drawn = {}
---@type table<integer, true> buffers render-markdown has run our handler for, drawn on or not
local attached = {}
---@type boolean whether images are shown: switched at run time, never saved
local enabled = true
---@type string? the Mermaid theme the diagrams were made under
local theme
local installed = false
---@type uv.uv_timer_t?
local prune_timer

--- Note that a buffer has, or no longer has, marks of ours.
---@param buf integer
---@param has boolean
function M.drawn(buf, has)
  drawn[buf] = has or nil
  -- The colours the diagrams are made under, noted when the first image is drawn.
  if has and not theme then theme = require("render-markdown-images.image").mermaid_theme() end
end

--- The buffers that have marks of ours.
---@return integer[]
function M.buffers()
  local bufs = vim.tbl_keys(drawn)
  table.sort(bufs)
  return bufs
end

--- Note that render-markdown runs our handler for a buffer, so that it can be told to render again when images
--- are switched on or off, whether it has marks of ours at that moment or not.
---@param buf integer
function M.attach(buf)
  attached[buf] = true
end

---@return boolean
function M.is_enabled()
  return enabled
end

--- Show or hide the images of every buffer, at once and until it is switched again. What was drawn is
--- taken away by the render that follows, and what was fetched and converted stays in the store, so switching
--- back on is quick.
---@param on boolean
---@return boolean changed
function M.set_enabled(on)
  if enabled == on then return false end
  enabled = on
  local store = require "render-markdown-images.store"
  local bufs = vim.tbl_keys(attached)
  table.sort(bufs)
  for _, buf in ipairs(bufs) do
    store.request_render(buf)
  end
  return true
end

--- Render buffers again, soon. Those with nothing of ours drawn are left alone.
---@param bufs? integer[] default: every buffer with marks of ours
function M.rerender(bufs)
  local store = require "render-markdown-images.store"
  for _, buf in ipairs(bufs or M.buffers()) do
    if drawn[buf] then store.request_render(buf) end
  end
end

--- Delete the placements nothing uses, in a moment.
function M.schedule_prune()
  if prune_timer and not prune_timer:is_closing() then return end
  prune_timer = vim.defer_fn(function()
    prune_timer = nil
    require("render-markdown-images.marks").prune()
  end, PRUNE_DELAY)
end

--- The buffers shown in the windows that changed size.
---@param windows integer[]
---@return integer[]
local function buffers_of(windows)
  local bufs, seen = {}, {}
  for _, win in ipairs(windows) do
    if vim.api.nvim_win_is_valid(win) then
      local buf = vim.api.nvim_win_get_buf(win)
      if drawn[buf] and not seen[buf] then
        seen[buf] = true
        bufs[#bufs + 1] = buf
      end
    end
  end
  return bufs
end

--- Windows changed size: draw again what they show.
---@param windows integer[]
function M.win_resized(windows)
  M.rerender(buffers_of(windows))
end

--- The colorscheme or the background changed.
function M.colors_changed()
  require("render-markdown-images.marks").refresh_highlights()
  local now = require("render-markdown-images.image").mermaid_theme()
  if theme and now ~= theme then require("render-markdown-images.store").invalidate "mermaid" end
  theme = theme and now or nil
  M.rerender()
end

--- A buffer is going away.
---@param buf integer
local function forget(buf)
  drawn[buf] = nil
  attached[buf] = nil
  require("render-markdown-images.store").forget_buf(buf)
  require("render-markdown-images.marks").forget_buf(buf)
  M.schedule_prune()
end

--- The Neovim is ending: take the images it sent out of the terminal.
function M.cleanup()
  local ids = require("render-markdown-images.store").image_ids()
  if #ids > 0 then require("render-markdown-images.image").delete_images(ids) end
end

--- Make the autocommands. Safe to call again: they are made afresh.
function M.ensure()
  if installed then return end
  installed = true
  local group = vim.api.nvim_create_augroup(GROUP, { clear = true })

  vim.api.nvim_create_autocmd("WinResized", {
    group = group,
    desc = "render-markdown-images: draw images again at the new size",
    callback = function()
      M.win_resized(vim.v.event.windows or {})
    end,
  })
  vim.api.nvim_create_autocmd("VimResized", {
    group = group,
    desc = "render-markdown-images: draw images again at the new size",
    callback = function()
      M.rerender()
    end,
  })
  vim.api.nvim_create_autocmd("OptionSet", {
    group = group,
    pattern = { "number", "relativenumber", "numberwidth", "signcolumn", "foldcolumn" },
    desc = "render-markdown-images: the text is narrower or wider",
    callback = function()
      -- A window's own setting concerns what the window shows; a global one, every window.
      if vim.v.option_type == "local" then
        M.rerender { vim.api.nvim_win_get_buf(0) }
      else
        M.rerender()
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "ColorScheme" }, {
    group = group,
    desc = "render-markdown-images: define the highlights again",
    callback = function()
      M.colors_changed()
    end,
  })
  vim.api.nvim_create_autocmd("OptionSet", {
    group = group,
    pattern = "background",
    desc = "render-markdown-images: diagrams follow the background",
    callback = function()
      M.colors_changed()
    end,
  })
  vim.api.nvim_create_autocmd({ "BufUnload", "BufWipeout" }, {
    group = group,
    desc = "render-markdown-images: let go of a buffer",
    callback = function(ev)
      forget(ev.buf)
    end,
  })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    desc = "render-markdown-images: take the images out of the terminal",
    callback = function()
      M.cleanup()
    end,
  })
end

--- Forget everything and remove the autocommands. For tests.
function M.reset()
  installed = false
  drawn = {}
  attached = {}
  enabled = true
  theme = nil
  if prune_timer and not prune_timer:is_closing() then
    prune_timer:stop()
    prune_timer:close()
  end
  prune_timer = nil
  pcall(vim.api.nvim_del_augroup_by_name, GROUP)
end

return M
