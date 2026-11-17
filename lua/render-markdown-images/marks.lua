--- From images that are ready to render-markdown marks: how big, which virtual placement, and the
--- virtual lines that carry the Unicode placeholders.
---
--- Below mode puts an image in the lines under the line it is written on, as `virt_lines` of an
--- extmark at column 0 of that row. Each of those lines holds one row of the image's placeholder
--- grid, so scrolling, wrapping and redrawing are Neovim's business and nothing is placed again after
--- them. The source text stays visible.

---@class render-markdown-images.Ready
---@field row integer row to draw below: the last row of the image's syntax, or of its table
---@field col integer first byte of the image on its row, to order images that share a row
---@field indent integer display columns the image is shifted right
---@field id integer Kitty image id
---@field w integer pixel width of the transmitted image
---@field h integer pixel height of the transmitted image

---@class render-markdown-images.Marks
local M = {}

local image = require "render-markdown-images.image"
local placeholder = require "render-markdown-images.placeholder"

---@class render-markdown-images.VirtualPlacement
---@field pid integer placement id, carried in the underline colour of the placeholder cells
---@field hl string highlight group that carries image and placement id

--- One virtual placement per (image id, columns, rows), made on first use. It tells the terminal how
--- big the image is in cells; any number of placeholder grids of that size share it.
---@type table<string, render-markdown-images.VirtualPlacement>
local placements = {}
local last_pid = 0

--- The size to draw an image at, in cells.
---
--- It fits the text area of the window (its width less the number column, sign column and so on) less
--- the indent, and the height of the window; it is never scaled up, and keeps its aspect ratio.
---@param win integer
---@param indent integer
---@param w integer pixel width
---@param h integer pixel height
---@return integer cols, integer rows
function M.size(win, indent, w, h)
  local info = vim.fn.getwininfo(win)[1]
  local textoff = info and info.textoff or 0
  local max_cols = math.min(math.max(1, vim.api.nvim_win_get_width(win) - textoff - indent), placeholder.MAX)
  local max_rows = math.min(math.max(1, vim.api.nvim_win_get_height(win)), placeholder.MAX)
  return image.calc_display_size(w, h, max_cols, max_rows)
end

--- The virtual placement for an image at a size, made if it does not exist yet, and its highlight
--- group, defined again every time: a colorscheme change clears highlight groups.
---@param id integer
---@param cols integer
---@param rows integer
---@return render-markdown-images.VirtualPlacement
function M.placement(id, cols, rows)
  local key = ("%d:%d:%d"):format(id, cols, rows)
  local p = placements[key]
  if not p then
    last_pid = last_pid + 1
    image.create_virtual_placement(id, last_pid, cols, rows)
    p = { pid = last_pid, hl = "" }
    placements[key] = p
  end
  p.hl = placeholder.ensure_hl(id, p.pid)
  return p
end

--- The virtual lines of one image: one per row of its placeholder grid, after the indent.
---@param p render-markdown-images.VirtualPlacement
---@param cols integer
---@param rows integer
---@param indent integer
---@return table[] virt_lines
function M.lines(p, cols, rows, indent)
  local pad = indent > 0 and (" "):rep(indent) or nil
  local lines = {}
  for r = 1, rows do
    local cell = { placeholder.row_text(r, cols), p.hl }
    lines[r] = pad and { { pad }, cell } or { cell }
  end
  return lines
end

--- Marks that draw `images` below their rows. Images on one row stack, left to right, in one mark.
---@param win integer window the buffer is shown in; it sets the size
---@param images render-markdown-images.Ready[]
---@return render.md.Mark[]
function M.below(win, images)
  if #images == 0 or not vim.api.nvim_win_is_valid(win) then return {} end

  local ordered = vim.list_slice(images)
  table.sort(ordered, function(a, b)
    if a.row ~= b.row then return a.row < b.row end
    return a.col < b.col
  end)

  local marks = {} ---@type render.md.Mark[]
  local current ---@type render.md.Mark?
  image.begin_batch() -- new placements go out in one write
  for _, img in ipairs(ordered) do
    local cols, rows = M.size(win, img.indent, img.w, img.h)
    local lines = M.lines(M.placement(img.id, cols, rows), cols, rows, img.indent)
    if current and current.start_row == img.row then
      vim.list_extend(current.opts.virt_lines, lines)
    else
      current = { conceal = false, start_row = img.row, start_col = 0, opts = { virt_lines = lines } }
      marks[#marks + 1] = current
    end
  end
  image.flush_batch()
  return marks
end

--- How many virtual placements exist, for tests and health checks.
---@return integer
function M.placement_count()
  return vim.tbl_count(placements)
end

--- Forget the virtual placements made so far (they stay in the terminal). For tests.
function M.reset()
  placements = {}
  last_pid = 0
end

return M
