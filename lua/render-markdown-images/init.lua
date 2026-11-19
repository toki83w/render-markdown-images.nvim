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
  require("render-markdown-images.lifecycle").ensure()
end

--- Take over downloading remote images, for what curl cannot fetch (an address that needs a token, say).
---
--- `fn(url, output_path, callback)` is called before curl for every URL. To take the job it returns `true` and,
--- when done, calls `callback(true)` after writing the image to `output_path`, or `callback(false)`; returning
--- `false` leaves the URL to curl. The same URL is not asked for twice at once, and what was fetched is cached.
---@param fn fun(url: string, output_path: string, callback: fun(ok: boolean)): boolean
function M.set_download_fn(fn)
  require("render-markdown-images.image").set_download_fn(fn)
end

--- Handlers for render-markdown's `custom_handlers` option, keyed by treesitter language.
---@return table<string, render-markdown-images.Handler>
function M.handlers()
  return require("render-markdown-images.handlers").new()
end

--- Whether images are shown. They are, until `disable()` or `toggle()`; this is not an option and is not saved.
---@return boolean
function M.is_enabled()
  return require("render-markdown-images.lifecycle").is_enabled()
end

--- Show images again in every buffer. What was fetched and converted is still there, so it is quick.
function M.enable()
  require("render-markdown-images.lifecycle").set_enabled(true)
end

--- Hide the images of every buffer, and look for none until `enable()`: the sources are shown as they are.
function M.disable()
  require("render-markdown-images.lifecycle").set_enabled(false)
end

--- Switch between `enable()` and `disable()`.
---@return boolean enabled whether images are shown now
function M.toggle()
  local on = not M.is_enabled()
  require("render-markdown-images.lifecycle").set_enabled(on)
  return on
end

return M
