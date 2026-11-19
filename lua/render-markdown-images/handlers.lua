--- Glue between render-markdown.nvim's custom handler API and this plugin.
---
--- One handler, for `markdown`, extending the builtin one. It finds the images and the Mermaid and PlantUML
--- fences of the document, asks the store for them and draws the ready ones.
---
--- Images are not left to a `markdown_inline` handler. render-markdown hands such a handler the inline trees that
--- `for_each_tree` gave it, and those can be stale (see `discover.inline`): now and then a paragraph's
--- images were never seen. The block tree is a single tree, and the inline text of its nodes is parsed here.
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

--- What to ask the store for, to show an image, and how to make it.
---
--- Nothing is waited for and nothing is searched for here: this runs on every render. A URL is its own key;
--- a file is found with one `stat` per candidate; a name that is not a file next to the note, in a note that is in
--- an Obsidian vault, is the vault's to look up, which the store does once and remembers.
---@param item render-markdown-images.ImageItem
---@param dir string the directory of the note
---@return string? key, render-markdown-images.Spec? spec nil spec: the store works out what the key is
function M.source_key(item, dir)
  local image = require "render-markdown-images.image"
  local src = item.src
  if image.is_url(src) then
    -- Badges are not worth a download, and GIFs and videos cannot be shown.
    if image.is_badge_url(src) or image.is_unsupported_format(src) then return nil end
    return src, nil
  end
  -- Other schemes (data:, mailto:, ...) are not files.
  if src:match "^%a[%w+.-]*:" then return nil end
  if image.is_unsupported_format(src) then return nil end

  local path = M.resolve_local(src, dir)
  if path then return path, nil end

  local root = require("render-markdown-images.obsidian").find_vault_root(dir)
  if root then return ("vault:%s:%s"):format(root, src), { kind = "vault", name = src, dir = dir } end
  return nil
end

-- ============================================================================
-- Replace mode
-- ============================================================================

--- Whether a source can be hidden for its image.
---
--- Hiding relies on `conceal_lines` (Neovim 0.11) and on render-markdown drawing the `replace` of a mark
--- (a feature added to it after its first releases). A render-markdown that ignores `replace` would
--- conceal the source and draw nothing, so without it the image goes below the source instead.
---@return boolean
function M.can_replace()
  if vim.fn.has "nvim-0.11" == 0 then return false end
  return (pcall(require, "render-markdown.lib.replacements"))
end

--- The source of an image that is to be hidden.
---
--- An image that is alone on its line at the left margin takes the whole rows. One in the middle of text,
--- or inside a list or a quote whose marker must stay, loses only the `![...](...)` itself.
---@param buf integer
---@param item render-markdown-images.ImageItem
---@return render-markdown-images.Hide
local function image_hide(buf, item)
  if item.alone_on_line and item.indent == 0 then
    return {
      kind = "lines",
      start_row = item.row,
      start_col = 0,
      end_row = item.end_row,
      end_col = #(vim.api.nvim_buf_get_lines(buf, item.end_row, item.end_row + 1, false)[1] or ""),
    }
  end
  return { kind = "text", start_row = item.row, start_col = item.col, end_row = item.end_row, end_col = item.end_col }
end

-- ============================================================================
-- Collecting and drawing
-- ============================================================================

--- What is ready to draw, collected over the roots of one render.
---
--- It lives on render-markdown's request context, which is made afresh for every render. Without that context
--- each root is drawn on its own.
---@param context? table
---@return render-markdown-images.Ready[] collected, boolean shared whether later roots add to it
local function collector(context)
  if not context then return {}, false end
  context.rmi_ready = context.rmi_ready or {}
  return context.rmi_ready, true
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
  local result = require("render-markdown-images.marks").build(win, ready)
  local lifecycle = require "render-markdown-images.lifecycle"
  lifecycle.drawn(buf, #result > 0)
  lifecycle.schedule_prune()
  return result
end

--- Whether there is anything to do for this buffer. The terminal is not asked whether it shows images:
--- having the plugin configured says it does.
---@param ctx { buf: integer, root: TSNode }
---@return render-markdown-images.Config? config
local function active(ctx)
  if not ctx.root or not vim.api.nvim_buf_is_valid(ctx.buf) then return nil end
  return require("render-markdown-images.config").get()
end

-- ============================================================================
-- Images
-- ============================================================================

--- Only the inline nodes render-markdown has in view: what is not shown is not asked for, so a long document
--- does not download, render and transmit everything at once. Without a view, everything.
---@param context? table
---@return (fun(node: TSNode): boolean)?
local function in_view(context)
  local view = context and context.view
  if type(view) ~= "table" or type(view.overlaps) ~= "function" then return nil end
  return function(node)
    local ok, overlaps = pcall(view.overlaps, view, node)
    return not ok or overlaps
  end
end

---@param ctx { buf: integer, root: TSNode }
---@param config render-markdown-images.Config
---@param context? table
---@param ready render-markdown-images.Ready[]
local function collect_images(ctx, config, context, ready)
  local discover = require "render-markdown-images.discover"
  local store = require "render-markdown-images.store"
  local dir = base_dir(ctx.buf)
  local replace = config.images.mode == "replace" and M.can_replace()

  for _, item in ipairs(discover.inline(ctx.buf, ctx.root, { filter = in_view(context) })) do
    local key, spec = M.source_key(item, dir)
    if key then
      local status, entry = store.get(key, ctx.buf, spec)
      if status == "ready" then
        ready[#ready + 1] = {
          -- Under a table, not inside it: a gap between two rows would break the table.
          row = item.table_end_row or item.end_row,
          col = item.col,
          indent = item.indent,
          id = entry.id,
          w = entry.w,
          h = entry.h,
          -- A table cell cannot give up its text without leaving the table with a hole in it: the
          -- source stays and the image goes below the table, as in below mode.
          hide = replace and not item.in_table and image_hide(ctx.buf, item) or nil,
        }
      end
    end
  end
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

--- The rows of a diagram fence, from the opening fence to the closing one.
---@param buf integer
---@param item render-markdown-images.FenceItem
---@return render-markdown-images.Hide
local function fence_hide(buf, item)
  return {
    kind = "lines",
    start_row = item.start_row,
    start_col = 0,
    end_row = item.end_row,
    end_col = #(vim.api.nvim_buf_get_lines(buf, item.end_row, item.end_row + 1, false)[1] or ""),
  }
end

---@param ctx { buf: integer, root: TSNode }
---@param config render-markdown-images.Config
---@param ready render-markdown-images.Ready[]
local function collect_fences(ctx, config, ready)
  if not (config.diagrams.mermaid or config.diagrams.plantuml) then return end
  local discover = require "render-markdown-images.discover"
  local store = require "render-markdown-images.store"
  local replace = config.diagrams.mode == "replace" and M.can_replace()

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
          hide = replace and fence_hide(ctx.buf, item) or nil,
        }
      end
    end
  end
end

-- ============================================================================
-- The handler
-- ============================================================================

--- What render-markdown calls for the `markdown` tree of a render.
---@param ctx { buf: integer, root: TSNode, last: boolean }
---@return table[]
function M.parse(ctx)
  local config = active(ctx)
  if not config then return {} end
  local lifecycle = require "render-markdown-images.lifecycle"
  lifecycle.ensure()
  lifecycle.attach(ctx.buf)
  if not lifecycle.is_enabled() then
    -- Switched off: nothing is looked for, fetched or drawn, and what an earlier render drew is not drawn again.
    -- The placements it used are let go of, and deleted in a moment.
    if ctx.last then
      lifecycle.drawn(ctx.buf, false)
      require("render-markdown-images.marks").forget_buf(ctx.buf)
      lifecycle.schedule_prune()
    end
    return {}
  end
  local context = request_context(ctx.buf)
  local ready, shared = collector(context)
  collect_images(ctx, config, context, ready)
  collect_fences(ctx, config, ready)
  -- Images and diagrams are drawn together, so that those that share a row stack in one mark.
  return draw(ctx.buf, context, ready, shared, ctx.last)
end

---@return table<string, render-markdown-images.Handler>
function M.new()
  return {
    markdown = { extends = true, parse = M.parse },
  }
end

return M
