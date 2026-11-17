--- Glue between render-markdown.nvim's custom handler API and this plugin.
---
--- Both handlers extend the builtin ones. `markdown_inline` finds images and `markdown` finds Mermaid
--- and PlantUML fences; both ask the store for them and draw the ready ones below their lines.
---
--- A handler runs inside render-markdown's parse. It must be quick and must not wait: everything
--- slow happens in the store, which renders the buffer again when something is ready.

---@class render-markdown-images.Handlers
local M = {}

--- Mirrors render-markdown's `render.md.Handler`.
---@class render-markdown-images.Handler
---@field extends boolean
---@field parse fun(ctx: { buf: integer, root: TSNode, last: boolean }): table[]

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
-- Collecting and drawing
-- ============================================================================

--- What is ready to draw, collected over the roots of one render.
---
--- It lives on render-markdown's request context, which is made afresh for every render, under `field`.
--- Without that context each root is drawn on its own.
---@param context? table
---@param field string
---@return render-markdown-images.Ready[] collected, boolean shared whether later roots add to it
local function collector(context, field)
  if not context then return {}, false end
  context[field] = context[field] or {}
  return context[field], true
end

--- The marks for what has been collected, once the last root has added to it.
---@param buf integer
---@param context? table
---@param ready render-markdown-images.Ready[]
---@param shared boolean
---@param last boolean whether this is the last root of the render
---@return table[]
local function draw(buf, context, ready, shared, last)
  if shared and not last then return {} end
  local win = render_window(context, buf)
  if not win then return {} end
  return require("render-markdown-images.marks").below(win, ready)
end

--- Whether the plugin should do anything for this buffer at all.
---@param ctx { buf: integer, root: TSNode }
---@return render-markdown-images.Config? config
local function active(ctx)
  local config = require("render-markdown-images.config").get()
  if config.enabled == false or not ctx.root or not vim.api.nvim_buf_is_valid(ctx.buf) then return nil end
  if not require("render-markdown-images.image").supports_kitty() then return nil end
  return config
end

-- ============================================================================
-- markdown_inline: images
-- ============================================================================

---@param ctx { buf: integer, root: TSNode, last: boolean }
---@return table[]
function M.parse_inline(ctx)
  if not active(ctx) then return {} end
  -- Below mode only, for now: `images.mode = "replace"` is drawn like "below".
  local image = require "render-markdown-images.image"
  local discover = require "render-markdown-images.discover"
  local store = require "render-markdown-images.store"

  local context = request_context(ctx.buf)
  local ready, shared = collector(context, "rmi_images")
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
  return draw(ctx.buf, context, ready, shared, ctx.last)
end

-- ============================================================================
-- markdown: diagram fences
-- ============================================================================

--- Whether render-markdown conceals the closing fence of a block in this language.
---
--- With `code.border = "hide"`, its default, the fence lines are concealed whole, and Neovim drops the
--- virtual lines of a concealed line. Reading the configuration is a bet on render-markdown's internals;
--- when it cannot be read the default is assumed.
---@param buf integer
---@param lang string the language as written after the opening fence
---@return boolean
local function closing_fence_hidden(buf, lang)
  local ok, code = pcall(function()
    return require("render-markdown.state").get(buf).code
  end)
  if not ok or type(code) ~= "table" then return true end
  if not code.enabled or code.border ~= "hide" then return false end
  local disable = code.disable
  if disable == true then return false end
  return not (type(disable) == "table" and vim.tbl_contains(disable, lang))
end

---@param ctx { buf: integer, root: TSNode, last: boolean }
---@return table[]
function M.parse_fences(ctx)
  local config = active(ctx)
  if not config or not (config.diagrams.mermaid or config.diagrams.plantuml) then return {} end
  local discover = require "render-markdown-images.discover"
  local store = require "render-markdown-images.store"

  local context = request_context(ctx.buf)
  local ready, shared = collector(context, "rmi_fences")

  for _, item in ipairs(discover.fences(ctx.buf, ctx.root)) do
    if config.diagrams[item.kind] then
      local key = store.diagram_key(item.kind, item.source)
      local status, entry = store.get(key, ctx.buf, { kind = item.kind, source = item.source })
      if status == "ready" then
        ready[#ready + 1] = {
          -- Under the closing fence. When that line is concealed it would take the image with it, so
          -- the last line of the diagram's source is used: the image lands in the same place.
          row = closing_fence_hidden(ctx.buf, item.lang) and item.end_row - 1 or item.end_row,
          col = 0,
          indent = item.indent,
          id = entry.id,
          w = entry.w,
          h = entry.h,
        }
      end
    end
  end

  return draw(ctx.buf, context, ready, shared, ctx.last)
end

---@return table<string, render-markdown-images.Handler>
function M.new()
  return {
    markdown = { extends = true, parse = M.parse_fences },
    markdown_inline = { extends = true, parse = M.parse_inline },
  }
end

return M
