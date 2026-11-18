--- From images that are ready to render-markdown marks: how big, which virtual placement, and the
--- virtual lines that carry the Unicode placeholders.
---
--- Below mode puts an image in the lines under the line it is written on, as `virt_lines` of an
--- extmark at column 0 of that row. Each of those lines holds one row of the image's placeholder
--- grid, so scrolling, wrapping and redrawing are Neovim's business and nothing is placed again after
--- them. The source text stays visible.
---
--- Replace mode hides the source as well, in one of two ways:
---
---  - `lines`: the rows of the source are concealed whole (`conceal_lines`) and the image is handed
---    to render-markdown as the `replace` of that mark. render-markdown then draws it as virtual
---    lines above the next row that is not concealed, and only while the concealing mark is shown:
---    when the cursor enters the source, anti-conceal drops the mark and the image goes with it.
---  - `text`: for an image in the middle of text, only its `![...](...)` is concealed, and the image
---    is virtual lines below that row, hidden together with the text.
---
--- Every mark of a replaced source has `conceal = true`, which is what lets anti-conceal hide it.

---@class render-markdown-images.Ready
---@field row integer row to draw below: the last row of the image's syntax, or of its table
---@field col integer first byte of the image on its row, to order images that share a row
---@field indent integer display columns the image is shifted right
---@field id integer Kitty image id
---@field w integer pixel width of the transmitted image
---@field h integer pixel height of the transmitted image
---@field hide? render-markdown-images.Hide set in replace mode: the source this image stands in for

---@class render-markdown-images.Hide
---@field kind "lines"|"text" whole rows, or only the text of the span
---@field start_row integer
---@field start_col integer
---@field end_row integer
---@field end_col integer byte after the last character of the source, on `end_row`

---@class render-markdown-images.Marks
local M = {}

local image = require "render-markdown-images.image"
local placeholder = require "render-markdown-images.placeholder"

---@class render-markdown-images.VirtualPlacement
---@field id integer Kitty image id
---@field pid integer placement id, carried in the underline colour of the placeholder cells
---@field hl string highlight group that carries image and placement id

--- One virtual placement per (image id, columns, rows), made on first use. It tells the terminal how
--- big the image is in cells; any number of placeholder grids of that size share it.
---@type table<string, render-markdown-images.VirtualPlacement>
local placements = {}
local last_pid = 0

--- The placements each buffer's marks use, as of its last build: what is on its screen. A placement nobody uses
--- any more, because the window changed size or the image left the document, can go.
---@type table<integer, table<string, true>>
local used = {}

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

---@param id integer
---@param cols integer
---@param rows integer
---@return string
function M.key(id, cols, rows)
  return ("%d:%d:%d"):format(id, cols, rows)
end

--- The virtual placement for an image at a size, made if it does not exist yet, and its highlight
--- group, defined again every time: a colorscheme change clears highlight groups.
---@param id integer
---@param cols integer
---@param rows integer
---@return render-markdown-images.VirtualPlacement
function M.placement(id, cols, rows)
  local key = M.key(id, cols, rows)
  local p = placements[key]
  if not p then
    last_pid = last_pid + 1
    image.create_virtual_placement(id, last_pid, cols, rows)
    p = { id = id, pid = last_pid, hl = "" }
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

--- Whether `row` is the last row of the buffer, or the rows after it do not exist.
---@param buf integer
---@param row integer
---@return boolean
local function at_end(buf, row)
  return row >= vim.api.nvim_buf_line_count(buf) - 1
end

--- Marks that draw `images`.
---
--- An image without `hide` goes below its row, its source left alone. Images on one row stack, left to
--- right, in one mark. An image with `hide` replaces its source, see the top of this file.
---
--- At the end of the buffer there is no row to draw above, and render-markdown has nowhere to put what it
--- generates, so a replaced source there is concealed by us and its image goes below the row before it,
--- in a mark that stays when the cursor enters the source: the image is then above the source being edited.
--- A source that is the whole buffer has no row before it; it is not replaced, the image goes below it.
---@param win integer window the buffer is shown in; it sets the size
---@param images render-markdown-images.Ready[]
---@return render.md.Mark[]
function M.build(win, images)
  if not vim.api.nvim_win_is_valid(win) then return {} end
  local buf = vim.api.nvim_win_get_buf(win)
  local using = {} ---@type table<string, true>
  used[buf] = using -- what this buffer draws now, nothing included
  if #images == 0 then return {} end

  local ordered = vim.list_slice(images)
  table.sort(ordered, function(a, b)
    if a.row ~= b.row then return a.row < b.row end
    return a.col < b.col
  end)

  local marks = {} ---@type render.md.Mark[]
  ---@type table<string, render.md.Mark>
  local stacks = {}

  --- Add virtual lines below `row`; those added to the same row with the same `conceal` stack in one mark.
  ---@param row integer
  ---@param conceal boolean
  ---@param lines table[]
  local function below(row, conceal, lines)
    local key = row .. (conceal and ":c" or ":s")
    local stack = stacks[key]
    if stack then
      vim.list_extend(stack.opts.virt_lines, lines)
    else
      stack = { conceal = conceal, start_row = row, start_col = 0, opts = { virt_lines = lines } }
      stacks[key] = stack
      marks[#marks + 1] = stack
    end
  end

  image.begin_batch() -- new placements go out in one write
  for _, img in ipairs(ordered) do
    local cols, rows = M.size(win, img.indent, img.w, img.h)
    using[M.key(img.id, cols, rows)] = true
    local lines = M.lines(M.placement(img.id, cols, rows), cols, rows, img.indent)
    local hide = img.hide
    if not hide then
      below(img.row, false, lines)
    elseif hide.kind == "text" then
      marks[#marks + 1] = {
        conceal = true,
        start_row = hide.start_row,
        start_col = hide.start_col,
        opts = { end_row = hide.end_row, end_col = hide.end_col, conceal = "" },
      }
      below(img.row, true, lines)
    else
      local conceal_lines = { end_row = hide.end_row, end_col = hide.end_col, conceal_lines = "" }
      if not at_end(buf, hide.end_row) then
        marks[#marks + 1] = {
          conceal = true,
          start_row = hide.start_row,
          start_col = hide.start_col,
          opts = conceal_lines,
          replace = lines,
        }
      elseif hide.start_row > 0 then
        marks[#marks + 1] =
          { conceal = true, start_row = hide.start_row, start_col = hide.start_col, opts = conceal_lines }
        below(hide.start_row - 1, false, lines)
      else
        below(img.row, false, lines)
      end
    end
  end
  image.flush_batch()
  return marks
end

--- Delete the virtual placements that no buffer uses, and their highlight groups. The images stay: placing
--- one again is cheap, sending it again is not.
---@return integer deleted
function M.prune()
  local wanted = {} ---@type table<string, true>
  for _, keys in pairs(used) do
    for key in pairs(keys) do
      wanted[key] = true
    end
  end
  local deleted = 0
  image.begin_batch()
  for key, p in pairs(placements) do
    if not wanted[key] then
      image.delete_virtual_placement(p.id, p.pid)
      placeholder.delete_hl(p.hl)
      placements[key] = nil
      deleted = deleted + 1
    end
  end
  image.flush_batch()
  return deleted
end

--- A buffer is gone: what it used is no longer in use.
---@param buf integer
function M.forget_buf(buf)
  used[buf] = nil
end

--- Define the highlight groups of the placements again. `:colorscheme` clears every group, and the cells would
--- lose the colours that carry their image and placement ids.
function M.refresh_highlights()
  for _, p in pairs(placements) do
    placeholder.ensure_hl(p.id, p.pid)
  end
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
  used = {}
end

return M
