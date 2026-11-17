--- Glue between render-markdown.nvim's custom handler API and this plugin.
---
--- Both handlers extend the builtin ones and currently contribute no marks;
--- later tasks fill in discovery (`markdown_inline` images, `markdown` fences).

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

---@return table<string, render-markdown-images.Handler>
function M.new()
  return {
    markdown = { extends = true, parse = no_marks },
    markdown_inline = { extends = true, parse = no_marks },
  }
end

return M
