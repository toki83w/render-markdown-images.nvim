--- Glue between render-markdown.nvim's custom handler API and this plugin.
---
--- Both handlers extend the builtin ones. `markdown_inline` finds images, asks the store for them
--- and draws the ready ones below their lines; `markdown` is still empty (diagram fences come later).
---
--- A handler runs inside render-markdown's parse. It must be quick and must not wait: everything
--- slow happens in the store, which renders the buffer again when something is ready.

---@class render-markdown-images.Handlers
local M = {}

--- Mirrors render-markdown's `render.md.Handler`.
---@class render-markdown-images.Handler
---@field extends boolean
---@field parse fun(ctx: { buf: integer, root: TSNode, last: boolean }): table[]

---@return table[]
local function no_marks()
  return {}
end

-- ============================================================================
-- Where things are
-- ============================================================================

--- render-markdown's request context for the render in progress. It is made afresh for every render, so
--- what is kept on it cannot outlive the pass. Reaching for it is a bet on render-markdown's internals,
--- hence the pcall: without it the handler still works, a root at a time.
---@param buf integer
---@return table?
local function request_context(buf)
  local ok, context = pcall(function()
    return require("render-markdown.request.context").get(buf)
  end)
  return ok and context or nil
end

--- The window being rendered: render-markdown's, else any window showing the buffer.
---@param context? table
---@param buf integer
---@return integer?
local function render_window(context, buf)
  if context and context.win and vim.api.nvim_win_is_valid(context.win) then return context.win end
  local win = vim.fn.bufwinid(buf)
  return win ~= -1 and win or nil
end

--- The directory relative paths are relative to.
---@param buf integer
---@return string
local function base_dir(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" then return vim.fn.getcwd() end
  return vim.fn.fnamemodify(name, ":p:h")
end

--- A local image source as a file path, or nil when there is no such file.
---
--- `~` and absolute paths are taken as they are, anything else is relative to `dir`. A path that is
--- not there is tried once more with `%20` and the like decoded, as markdown viewers do. Nothing is
--- searched for: this runs on every render, and a miss must cost one `stat`.
---@param src string
---@param dir string
---@return string?
function M.resolve_local(src, dir)
  ---@param candidate string
  ---@return string?
  local function try(candidate)
    if candidate:sub(1, 2) == "~/" then candidate = (vim.uv.os_homedir() or "~") .. candidate:sub(2) end
    if candidate:sub(1, 1) ~= "/" then candidate = dir .. "/" .. candidate end
    if vim.fn.filereadable(candidate) == 1 then return vim.fs.normalize(candidate) end
  end
  local found = try(src)
  if found or not src:find "%%%x%x" then return found end
  return try((src:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end)))
end

-- ============================================================================
-- markdown_inline
-- ============================================================================

--- Images ready to draw, collected over the roots of one render.
---@param context? table
---@return render-markdown-images.Ready[] collected, boolean shared whether later roots add to it
local function collector(context)
  if not context then return {}, false end
  context.rmi_ready = context.rmi_ready or {}
  return context.rmi_ready, true
end

---@param ctx { buf: integer, root: TSNode, last: boolean }
---@return table[]
function M.parse_inline(ctx)
  local config = require("render-markdown-images.config").get()
  if config.enabled == false or not ctx.root or not vim.api.nvim_buf_is_valid(ctx.buf) then return {} end
  -- Below mode only, for now: `images.mode = "replace"` is drawn like "below".
  local image = require "render-markdown-images.image"
  if not image.supports_kitty() then return {} end

  local discover = require "render-markdown-images.discover"
  local store = require "render-markdown-images.store"

  local context = request_context(ctx.buf)
  local ready, shared = collector(context)
  local dir = base_dir(ctx.buf)

  for _, item in ipairs(discover.inline(ctx.buf, ctx.root)) do
    -- Remote images and Obsidian vault names are not drawn yet.
    local path = not image.is_url(item.src) and M.resolve_local(item.src, dir) or nil
    if path then
      local status, entry = store.get(path, ctx.buf)
      if status == "ready" then
        ready[#ready + 1] = {
          -- Under a table, not inside it: a gap between two rows would break the table.
          row = item.table_end_row or item.end_row,
          col = item.col,
          indent = item.indent,
          id = entry.id,
          w = entry.w,
          h = entry.h,
        }
      end
    end
  end

  -- Every root of the render has added its images by the time of the last one, so images that share
  -- a row, in different table cells say, stack in one mark.
  if shared and not ctx.last then return {} end
  local win = render_window(context, ctx.buf)
  if not win then return {} end
  return require("render-markdown-images.marks").below(win, ready)
end

---@return table<string, render-markdown-images.Handler>
function M.new()
  return {
    markdown = { extends = true, parse = no_marks },
    markdown_inline = { extends = true, parse = M.parse_inline },
  }
end

return M
