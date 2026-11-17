-- marks: sizing, virtual placements, highlights and the virt_lines marks of below mode.
-- Run: nvim --headless -u NONE --noplugin -l tests/marks_test.lua

package.path = vim.fn.getcwd() .. "/?.lua;" .. package.path
local h = require "tests.harness"

local marks = require "render-markdown-images.marks"
local image = require "render-markdown-images.image"
local placeholder = require "render-markdown-images.placeholder"

--- Every escape sequence the image module writes, from `nvim_ui_send`.
local sent = {}

local function reset()
  h.unstub()
  marks.reset()
  sent = {}
  h.stub(vim.api, "nvim_ui_send", function(data)
    sent[#sent + 1] = data
  end)
  image._set_kitty_supported(true)
  image._set_in_tmux(false)
  image._test_cell_size = { cell_w = 10, cell_h = 20 }
end

local function finish_test()
  h.unstub()
  image._test_cell_size = nil
  image._set_kitty_supported(nil)
  image.reset_cache()
end

--- A window of exactly `width` x `height` text cells, showing an empty buffer.
---@param width integer
---@param height integer
---@param opts? { number?: boolean }
---@return integer win
local function window(width, height, opts)
  local buf = vim.api.nvim_create_buf(false, true)
  local win = vim.api.nvim_open_win(buf, false, {
    relative = "editor",
    row = 0,
    col = 0,
    width = width,
    height = height,
    style = "minimal",
  })
  if opts and opts.number then
    vim.wo[win].number = true
    vim.wo[win].numberwidth = 4
  end
  return win
end

--- The Kitty graphics commands sent so far with the given action (`a=p` and so on).
---@param action string
---@return string[]
local function commands(action)
  local out = {}
  for seq in table.concat(sent):gmatch "\27_G([^\27]*)\27\\" do
    if seq:find("^a=" .. action .. ",") then out[#out + 1] = seq end
  end
  return out
end

-- ============================================================================
-- size
-- ============================================================================

h.test("size: a small image is not scaled up", function()
  reset()
  local win = window(40, 10)
  h.assert_eq({ marks.size(win, 0, 40, 20) }, { 4, 1 }, "40x20 px at 10x20 px cells is 4x1 cells")
  h.assert_eq({ marks.size(win, 0, 20, 40) }, { 2, 2 }, "20x40 px is 2x2")
  finish_test()
end)

h.test("size: a wide image is capped by the width of the window", function()
  reset()
  local win = window(40, 10)
  h.assert_eq({ marks.size(win, 0, 1000, 100) }, { 40, 2 }, "fills the 40 columns, keeping 10:1")
  h.assert_eq({ marks.size(win, 0, 4000, 400) }, { 40, 2 }, "however large it is")
  finish_test()
end)

h.test("size: the indent and the columns before the text are taken off the width", function()
  reset()
  local win = window(40, 10)
  h.assert_eq({ marks.size(win, 10, 1000, 100) }, { 30, 2 }, "indent 10 leaves 30 columns")
  h.assert_eq({ marks.size(win, 39, 1000, 100) }, { 1, 1 }, "one column at least")
  h.assert_eq({ marks.size(win, 60, 1000, 100) }, { 1, 1 }, "even when the indent is wider than the window")

  local numbered = window(40, 10, { number = true })
  local textoff = vim.fn.getwininfo(numbered)[1].textoff
  h.assert_eq(textoff > 0, true, "the number column takes room (" .. textoff .. ")")
  h.assert_eq(({ marks.size(numbered, 0, 4000, 400) })[1], 40 - textoff, "and the image is that much narrower")
  finish_test()
end)

h.test("size: a tall image is capped by the height of the window", function()
  reset()
  local win = window(40, 10)
  h.assert_eq({ marks.size(win, 0, 100, 2000) }, { 1, 10 }, "10 rows, and the width that goes with them")
  local short = window(80, 5)
  h.assert_eq(
    { marks.size(short, 0, 4000, 4000) },
    { 10, 5 },
    "a square one in a short window: 5 rows of 20 px, 10 columns of 10 px"
  )
  finish_test()
end)

h.test("size: never beyond what a placeholder grid can name", function()
  reset()
  local win = window(400, 300)
  local cols, rows = marks.size(win, 0, 100000, 100000)
  h.assert_eq(cols <= placeholder.MAX and rows <= placeholder.MAX, true, "at most " .. placeholder.MAX)
  finish_test()
end)

h.test("size: without a known cell size, a fixed size within the limits", function()
  reset()
  image._test_cell_size = nil
  h.stub(image, "get_cell_size", function()
    return nil
  end)
  local win = window(40, 10)
  h.assert_eq({ marks.size(win, 0, 1000, 1000) }, { 20, 10 }, "20x10")
  h.assert_eq({ marks.size(win, 30, 1000, 1000) }, { 10, 10 }, "narrower when the room is")
  finish_test()
end)

-- ============================================================================
-- placement
-- ============================================================================

h.test("placement: created once per (id, cols, rows), shared by every use", function()
  reset()
  local a = marks.placement(101, 4, 2)
  local b = marks.placement(101, 4, 2)
  h.assert_eq(a.pid, b.pid, "same placement id")
  h.assert_eq(a.hl, b.hl, "same highlight group")
  h.assert_eq(#commands "p", 1, "one command sent to the terminal")
  h.assert_eq(commands("p")[1], ("a=p,U=1,i=101,p=%d,c=4,r=2,q=2"):format(a.pid), "virtual placement of 4x2 cells")
  h.assert_eq(marks.placement_count(), 1, "one placement")

  local other_size = marks.placement(101, 4, 3)
  local other_image = marks.placement(102, 4, 2)
  h.assert_eq(
    a.pid ~= other_size.pid and a.pid ~= other_image.pid and other_size.pid ~= other_image.pid,
    true,
    "another size and another image each get their own"
  )
  h.assert_eq(#commands "p", 3, "three commands in all")
  h.assert_eq(marks.placement_count(), 3, "three placements")
  finish_test()
end)

h.test("placement: the highlight carries the image id and the placement id", function()
  reset()
  local p = marks.placement(0x010203, 3, 1)
  local hl = vim.api.nvim_get_hl(0, { name = p.hl, link = false })
  h.assert_eq(hl.fg, 0x010203, "fg is the image id")
  h.assert_eq(hl.sp, p.pid, "sp is the placement id")
  h.assert_eq(hl.underline, true, "underlined, so that sp reaches the terminal")
  h.assert_eq(hl.nocombine, true, "not blended with what is underneath")
  h.assert_eq(p.hl, "RenderMdImg_" .. p.pid, "named after the placement")
  finish_test()
end)

h.test("placement: the highlight is defined again on every use", function()
  reset()
  local p = marks.placement(101, 4, 2)
  vim.api.nvim_set_hl(0, p.hl, {}) -- what `:colorscheme` does
  h.assert_eq(vim.api.nvim_get_hl(0, { name = p.hl, link = false }), {}, "cleared")
  marks.placement(101, 4, 2)
  h.assert_eq(vim.api.nvim_get_hl(0, { name = p.hl, link = false }).fg, 101, "back")
  h.assert_eq(#commands "p", 1, "without another placement command")
  finish_test()
end)

-- ============================================================================
-- lines
-- ============================================================================

h.test("lines: one per row, each holding that row of the placeholder grid", function()
  reset()
  local p = marks.placement(101, 3, 2)
  local lines = marks.lines(p, 3, 2, 0)
  h.assert_eq(lines, {
    { { placeholder.row_text(1, 3), p.hl } },
    { { placeholder.row_text(2, 3), p.hl } },
  }, "two rows, no indent chunk")
  h.assert_eq(lines[1][1][1] ~= lines[2][1][1], true, "the rows differ")
  finish_test()
end)

h.test("lines: the indent is a chunk before the placeholders", function()
  reset()
  local p = marks.placement(101, 3, 2)
  h.assert_eq(marks.lines(p, 3, 2, 4), {
    { { "    " }, { placeholder.row_text(1, 3), p.hl } },
    { { "    " }, { placeholder.row_text(2, 3), p.hl } },
  }, "four spaces, then the row")
  finish_test()
end)

-- ============================================================================
-- below
-- ============================================================================

--- A ready image.
local function ready(row, col, id, w, h_, indent)
  return { row = row, col = col, indent = indent or 0, id = id, w = w, h = h_ }
end

h.test("below: nothing to draw, or nowhere to draw it, is no marks", function()
  reset()
  local win = window(40, 10)
  h.assert_eq(marks.below(win, {}), {}, "no images")
  h.assert_eq(marks.below(99999, { ready(0, 0, 101, 40, 20) }), {}, "no window")
  h.assert_eq(#sent, 0, "and nothing sent to the terminal")
  finish_test()
end)

h.test("below: one image is one mark, at column 0 of its row, with a row of virt_lines per cell row", function()
  reset()
  local win = window(40, 10)
  local result = marks.below(win, { ready(3, 7, 101, 40, 40) }) -- 4 x 2 cells
  local p = marks.placement(101, 4, 2)
  h.assert_eq(result, {
    {
      conceal = false,
      start_row = 3,
      start_col = 0,
      opts = {
        virt_lines = {
          { { placeholder.row_text(1, 4), p.hl } },
          { { placeholder.row_text(2, 4), p.hl } },
        },
      },
    },
  }, "the mark")
  finish_test()
end)

h.test("below: the row count follows the size", function()
  reset()
  local win = window(40, 10)
  local result = marks.below(win, { ready(0, 0, 101, 1000, 100) }) -- 40 x 2 cells
  h.assert_eq(#result[1].opts.virt_lines, 2, "two rows for 1000x100")
  result = marks.below(win, { ready(0, 0, 102, 100, 2000) }) -- 1 x 10 cells
  h.assert_eq(#result[1].opts.virt_lines, 10, "ten rows, as many as the window has, for 100x2000")
  finish_test()
end)

h.test("below: the indent applies to the size and to the lines", function()
  reset()
  local win = window(40, 10)
  local result = marks.below(win, { ready(0, 0, 101, 4000, 400, 10) })
  local lines = result[1].opts.virt_lines
  h.assert_eq(lines[1][1], { (" "):rep(10) }, "ten spaces first")
  h.assert_eq(vim.fn.strchars(lines[1][2][1]), 30 * 3, "30 cells of three characters: the width left after the indent")
  finish_test()
end)

h.test("below: images on different rows are different marks, in row order", function()
  reset()
  local win = window(40, 10)
  local result = marks.below(win, { ready(8, 0, 102, 40, 20), ready(2, 0, 101, 40, 20) })
  h.assert_eq(
    vim.tbl_map(function(m)
      return m.start_row
    end, result),
    { 2, 8 },
    "sorted by row, whatever the order they came in"
  )
  finish_test()
end)

h.test("below: images on one row stack in one mark, left to right", function()
  reset()
  local win = window(40, 10)
  local result = marks.below(win, {
    ready(5, 30, 102, 40, 40), -- 4 x 2, second on the row
    ready(5, 2, 101, 20, 20), -- 2 x 1, first
  })
  h.assert_eq(#result, 1, "one mark")
  local lines = result[1].opts.virt_lines
  h.assert_eq(#lines, 3, "one row of the first image, then two of the second")
  local first, second = marks.placement(101, 2, 1), marks.placement(102, 4, 2)
  h.assert_eq(lines, {
    { { placeholder.row_text(1, 2), first.hl } },
    { { placeholder.row_text(1, 4), second.hl } },
    { { placeholder.row_text(2, 4), second.hl } },
  }, "in order of column")
  finish_test()
end)

h.test("below: the same image twice shares one placement", function()
  reset()
  local win = window(40, 10)
  local result = marks.below(win, { ready(1, 0, 101, 40, 20), ready(6, 0, 101, 40, 20) })
  h.assert_eq(#result, 2, "two marks")
  h.assert_eq(result[1].opts.virt_lines, result[2].opts.virt_lines, "with the same lines, so the same placement")
  h.assert_eq(marks.placement_count(), 1, "one placement")
  h.assert_eq(#commands "p", 1, "created once")
  finish_test()
end)

h.test("below: the same image at two sizes has two placements", function()
  reset()
  local win = window(40, 10)
  marks.below(win, { ready(1, 0, 101, 1000, 100), ready(6, 0, 101, 1000, 100, 20) }) -- 40 and 20 columns
  h.assert_eq(marks.placement_count(), 2, "one per size")
  finish_test()
end)

h.test("below: building again changes nothing in the terminal", function()
  reset()
  local win = window(40, 10)
  local images = { ready(1, 0, 101, 40, 20), ready(6, 0, 102, 40, 40) }
  local first = marks.below(win, images)
  local sent_after_first = #commands "p"
  local second = marks.below(win, images)
  h.assert_eq(second, first, "the same marks")
  h.assert_eq(#commands "p", sent_after_first, "no placement command repeated")
  finish_test()
end)

h.test("below: new placements go out in one write", function()
  reset()
  local win = window(40, 10)
  marks.below(win, { ready(1, 0, 101, 40, 20), ready(6, 0, 102, 40, 40), ready(9, 0, 103, 80, 20) })
  h.assert_eq(#commands "p", 3, "three placements")
  h.assert_eq(#sent, 1, "in a single write")
  finish_test()
end)

h.test("below: the images passed in are not modified", function()
  reset()
  local win = window(40, 10)
  local images = { ready(8, 0, 102, 40, 20), ready(2, 0, 101, 40, 20) }
  local before = vim.deepcopy(images)
  marks.below(win, images)
  h.assert_eq(images, before, "same order, same fields")
  finish_test()
end)

h.finish "marks_test"
