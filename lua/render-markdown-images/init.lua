--- Show images and diagrams in markdown source buffers, as render-markdown.nvim custom handlers.
---
--- ```lua
--- require("render-markdown-images").setup({ images = { mode = "below" } }) -- optional
--- require("render-markdown").setup({
---   custom_handlers = require("render-markdown-images").handlers(),
--- })
--- ```

---@class render-markdown-images
local M = {}

--- Validate `opts` and apply them over the defaults. Raises on invalid options and
--- leaves the previous configuration untouched in that case.
---@param opts? table
function M.setup(opts)
  require("render-markdown-images.config").setup(opts)
  -- Only a loaded image module has decisions to forget; do not load it just for this.
  local image = package.loaded["render-markdown-images.image"]
  if image then image.setup() end
end

--- Handlers for render-markdown's `custom_handlers` option, keyed by treesitter language.
---@return table<string, render-markdown-images.Handler>
function M.handlers()
  return require("render-markdown-images.handlers").new()
end

return M
