-- Replace mode inside the real render-markdown: the source hidden, the image in its place, the source
-- back when the cursor enters it. What Neovim will actually show is measured with `nvim_win_text_height`.
-- Only the renderers and the terminal are faked.
-- Needs a render-markdown.nvim checkout, see tests/render_markdown_test.lua.
-- Run: nvim --headless -u NONE --noplugin -l tests/replace_render_test.lua

package.path = vim.fn.getcwd() .. "/?.lua;" .. package.path
local h = require "tests.harness"
local support = require "tests.support"

local rm_path = h.find_plugin("RENDER_MARKDOWN_PATH", "render-markdown.nvim")
if not rm_path then
  if vim.env.RMI_REQUIRE_RENDER_MARKDOWN == "1" then
    print "replace_render_test: FAIL: render-markdown.nvim not found"
    os.exit(1)
  end
  print "replace_render_test: skip (render-markdown.nvim not found)"
  os.exit(0)
end

h.isolate_cache()
vim.opt.rtp:prepend(rm_path)
vim.opt.rtp:prepend(h.root)
vim.cmd.runtime "plugin/render-markdown.lua"

vim.o.columns = 80
vim.o.lines = 40
vim.o.laststatus = 0
vim.o.termguicolors = true

local rmi = require "render-markdown-images"
local rm = require "render-markdown"
local image = require "render-markdown-images.image"
local store = require "render-markdown-images.store"
local marks = require "render-markdown-images.marks"
local handlers = require "render-markdown-images.handlers"

local ns = vim.api.nvim_create_namespace "render-markdown.nvim"

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
local diagram_png = dir .. "/diagram.png"
support.make_png(diagram_png, 400, 200) -- 40 x 10 cells at 10 x 20 px
support.make_png(dir .. "/wide.png", 400, 200) -- 10 rows
support.make_png(dir .. "/small.png", 40, 20) -- 1 row
support.make_png(dir .. "/tall.png", 40, 40) -- 2 rows

---@param opts? { config?: table, anti_conceal?: table, handlers?: boolean }
local function setup(opts)
  opts = opts or {}
  h.unstub()
  store.reset()
  marks.reset()
  rmi.setup(opts.config or { images = { mode = "replace" }, diagrams = { mode = "replace" } })
  h.stub(vim.api, "nvim_ui_send", function() end)
  image.reset_cache()
  image._set_in_tmux(false)
  image._test_cell_size = { cell_w = 10, cell_h = 20 }
  h.stub(image, "has_mmdc", function()
    return true
  end)
  h.stub(image, "render_mermaid_async", function(_, cb)
    cb(diagram_png)
  end)
  h.stub(store.limits, "debounce", 10)
  h.stub(store.limits, "retry_delay", 0)
  rm.setup {
    anti_conceal = opts.anti_conceal or { enabled = true },
    debounce = 0,
    custom_handlers = opts.handlers == false and {} or rmi.handlers(),
  }
end

local function finish_test()
  h.unstub()
  store.reset()
  marks.reset()
  image._test_cell_size = nil
  image.reset_cache()
  rmi.setup()
  vim.cmd "silent! %bwipeout!"
end

--- A buffer with `lines`, shown in the current window with the cursor on row `cursor` (0-based; default: row 0).
---@param lines string[]
---@param cursor? integer
---@return integer buf
local function open(lines, cursor)
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buf, ("%s/doc-%d.md"):format(dir, buf))
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_current_buf(buf)
  vim.bo[buf].filetype = "markdown"
  vim.treesitter.start(buf, "markdown")
  vim.api.nvim_win_set_cursor(0, { (cursor or 0) + 1, 0 })
  vim.wait(0)
  rm.render { buf = buf, force = true }
  return buf
end

--- Move the cursor and render again, as render-markdown does on CursorMoved.
---@param buf integer
---@param row integer 0-based
local function move_to(buf, row)
  vim.api.nvim_win_set_cursor(0, { row + 1, 0 })
  rm.render { buf = buf, force = true }
  support.sleep(60)
end

--- Extmarks in render-markdown's namespace.
---@param buf integer
---@return table[]
local function extmarks(buf)
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    out[#out + 1] = { row = m[2], col = m[3], d = m[4] }
  end
  return out
end

--- Marks that carry an image: `{ row, number of lines, above }`.
---@param buf integer
---@return { [1]: integer, [2]: integer, [3]: boolean }[]
local function image_marks(buf)
  local out = {}
  for _, m in ipairs(extmarks(buf)) do
    local lines = m.d.virt_lines
    if lines and lines[1] and lines[1][#lines[1]][2]:find "^RenderMdImg_" then
      out[#out + 1] = { m.row, #lines, m.d.virt_lines_above == true }
    end
  end
  return out
end

--- The rows that are concealed whole.
---@param buf integer
---@return integer[]
local function concealed_rows(buf)
  local out = {}
  for _, m in ipairs(extmarks(buf)) do
    if m.d.conceal_lines then
      local last = m.d.end_row or m.row
      if last > m.row and m.d.end_col == 0 then last = last - 1 end
      for r = m.row, last do
        out[#out + 1] = r
      end
    end
  end
  table.sort(out)
  return out
end

--- How many screen rows the buffer takes now.
---@return integer
local function text_height()
  return vim.api.nvim_win_text_height(0, {}).all
end

---@param buf integer
---@param n? integer
local function wait_for_images(buf, n)
  h.wait_for(function()
    return #image_marks(buf) >= (n or 1)
  end, 5000)
  support.sleep(30)
end

-- ============================================================================
-- Images alone on a line
-- ============================================================================

local DOC = { "first", "", "![wide](wide.png)", "", "last" }

h.test("an image alone on its line: the row is concealed, the image takes its place", function()
  setup()
  local buf = open(DOC, 0)
  h.assert_eq(text_height(), #DOC, "while the image is pending the source is shown, nothing else")
  h.assert_eq(concealed_rows(buf), {}, "nothing concealed")
  wait_for_images(buf)
  h.assert_eq(concealed_rows(buf), { 2 }, "row 2 is concealed")
  h.assert_eq(
    image_marks(buf),
    { { 3, 10, true } },
    "10 image rows, above the next row (3): render-markdown's generated mark"
  )
  h.assert_eq(text_height(), #DOC - 1 + 10, "Neovim shows 4 lines and 10 rows of image")
  finish_test()
end)

h.test("the source comes back when the cursor enters it, and the image goes", function()
  setup()
  local buf = open(DOC, 0)
  wait_for_images(buf)
  move_to(buf, 2)
  h.assert_eq(concealed_rows(buf), {}, "nothing concealed: the source is shown")
  h.assert_eq(image_marks(buf), {}, "and the image is gone with it")
  h.assert_eq(text_height(), #DOC, "the document as written")
  move_to(buf, 4)
  h.assert_eq(concealed_rows(buf), { 2 }, "cursor away: concealed again")
  h.assert_eq(image_marks(buf), { { 3, 10, true } }, "and the image is back")
  h.assert_eq(text_height(), #DOC - 1 + 10, "as before")
  finish_test()
end)

h.test("the cursor next to the image does not bring the source back", function()
  setup()
  local buf = open(DOC, 0)
  wait_for_images(buf)
  move_to(buf, 1)
  h.assert_eq(concealed_rows(buf), { 2 }, "cursor on the blank row above: still concealed")
  h.assert_eq(#image_marks(buf), 1, "and the image is there")
  move_to(buf, 3)
  h.assert_eq(concealed_rows(buf), { 2 }, "cursor on the blank row below: the same")
  finish_test()
end)

h.test("anti_conceal above and below widen what brings the source back", function()
  setup { anti_conceal = { enabled = true, above = 1, below = 1 } }
  local buf = open(DOC, 0)
  wait_for_images(buf)
  move_to(buf, 1)
  h.assert_eq(concealed_rows(buf), {}, "one row above: shown")
  move_to(buf, 4)
  h.assert_eq(concealed_rows(buf), { 2 }, "two rows below: concealed")
  finish_test()
end)

h.test("an image on the first row, the cursor on it from the start", function()
  setup()
  local buf = open({ "![wide](wide.png)", "", "text" }, 0)
  support.sleep(250)
  h.assert_eq(image_marks(buf), {}, "the cursor is on the source: no image yet")
  move_to(buf, 2)
  wait_for_images(buf)
  h.assert_eq(concealed_rows(buf), { 0 }, "cursor gone: concealed")
  h.assert_eq(image_marks(buf), { { 1, 10, true } }, "image above row 1")
  finish_test()
end)

h.test("two images on neighbouring rows: both replaced, drawn one after the other", function()
  setup()
  local buf = open({ "![a](small.png)", "![b](tall.png)", "", "text" }, 3)
  h.wait_for(function()
    local m = image_marks(buf)
    return #m == 1 and m[1][2] == 3
  end, 5000)
  h.assert_eq(concealed_rows(buf), { 0, 1 }, "both rows concealed")
  h.assert_eq(image_marks(buf), { { 2, 3, true } }, "one stack of 1 + 2 rows above the next visible row")
  finish_test()
end)

h.test("separate images keep their own places", function()
  setup()
  local buf = open({ "![a](small.png)", "", "text", "", "![b](tall.png)", "", "end" }, 6)
  h.wait_for(function()
    return #image_marks(buf) == 2
  end, 5000)
  h.assert_eq(concealed_rows(buf), { 0, 4 }, "both rows")
  h.assert_eq(
    vim.tbl_map(function(m)
      return { m[1], m[2] }
    end, image_marks(buf)),
    { { 1, 1 }, { 5, 2 } },
    "each above the row after its own"
  )
  finish_test()
end)

-- ============================================================================
-- The last row
-- ============================================================================

h.test("an image alone on the last row is still shown", function()
  setup()
  local buf = open({ "first", "", "![wide](wide.png)" }, 0)
  wait_for_images(buf)
  h.assert_eq(concealed_rows(buf), { 2 }, "the last row concealed")
  h.assert_eq(image_marks(buf), { { 1, 10, false } }, "the image below row 1")
  h.assert_eq(text_height(), 3 - 1 + 10, "Neovim shows it")
  finish_test()
end)

h.test("at the end the image stays when the cursor enters the source: above it", function()
  setup()
  local buf = open({ "first", "", "![wide](wide.png)" }, 0)
  wait_for_images(buf)
  move_to(buf, 2)
  h.assert_eq(concealed_rows(buf), {}, "the source is shown")
  h.assert_eq(image_marks(buf), { { 1, 10, false } }, "the image stays, above it")
  h.assert_eq(text_height(), 3 + 10, "all three lines and the image")
  finish_test()
end)

h.test("a document that is only an image keeps its source and draws the image below", function()
  setup()
  local buf = open({ "![wide](wide.png)" }, 0)
  support.sleep(250)
  wait_for_images(buf)
  h.assert_eq(concealed_rows(buf), {}, "nothing concealed")
  h.assert_eq(image_marks(buf), { { 0, 10, false } }, "image below the only row")
  finish_test()
end)

-- ============================================================================
-- Images among text, in lists
-- ============================================================================

h.test("an image among text: its syntax is concealed, the image goes below the line", function()
  setup()
  local buf = open({ "before ![x](small.png) after", "", "text" }, 2)
  wait_for_images(buf)
  local concealing = vim.tbl_filter(function(m)
    return m.d.conceal == ""
  end, extmarks(buf))
  h.assert_eq(#concealing, 1, "one concealed span")
  h.assert_eq(
    { concealing[1].row, concealing[1].col, concealing[1].d.end_col },
    { 0, 7, 22 },
    "exactly `![x](small.png)`"
  )
  h.assert_eq(concealed_rows(buf), {}, "no row concealed")
  h.assert_eq(image_marks(buf), { { 0, 1, false } }, "image below the line")
  h.assert_eq(text_height(), 3 + 1, "the three lines and one row of image")
  finish_test()
end)

h.test("an image among text comes back to source with the cursor", function()
  setup()
  local buf = open({ "before ![x](small.png) after", "", "text" }, 2)
  wait_for_images(buf)
  move_to(buf, 0)
  h.assert_eq(#vim.tbl_filter(function(m)
    return m.d.conceal == ""
  end, extmarks(buf)), 0, "the syntax is shown")
  h.assert_eq(image_marks(buf), {}, "and the image is gone")
  h.assert_eq(text_height(), 3, "just the document")
  finish_test()
end)

h.test("an image alone in a list item keeps the bullet", function()
  setup()
  local buf = open({ "- ![x](small.png)", "", "text" }, 2)
  wait_for_images(buf)
  h.assert_eq(concealed_rows(buf), {}, "the row is not concealed")
  local concealing = vim.tbl_filter(function(m)
    return m.d.conceal == "" and m.d.end_col == 17
  end, extmarks(buf))
  h.assert_eq(#concealing >= 1, true, "the image's syntax is concealed")
  h.assert_eq(concealing[1].col, 2, "after `- `")
  h.assert_eq(image_marks(buf), { { 0, 1, false } }, "the image below")
  finish_test()
end)

h.test("images in a table are drawn below it and the table is left alone", function()
  setup()
  local buf = open({ "| a | b |", "| - | - |", "| ![x](small.png) | text |", "", "after" }, 4)
  wait_for_images(buf)
  h.assert_eq(concealed_rows(buf), {}, "nothing concealed")
  h.assert_eq(image_marks(buf), { { 2, 1, false } }, "under the last row of the table")
  finish_test()
end)

-- ============================================================================
-- Diagrams
-- ============================================================================

local FENCE_DOC = { "intro", "", "```mermaid", "graph TD", "  A --> B", "```", "", "outro" }

h.test("a diagram fence is replaced by its diagram", function()
  setup()
  local buf = open(FENCE_DOC, 0)
  h.assert_eq(
    text_height(),
    #FENCE_DOC - 1,
    "pending: the block as render-markdown draws it (its closing fence concealed)"
  )
  wait_for_images(buf)
  local concealed = concealed_rows(buf)
  for row = 2, 5 do
    h.assert_eq(vim.tbl_contains(concealed, row), true, "row " .. row .. " is concealed")
  end
  h.assert_eq(image_marks(buf), { { 6, 10, true } }, "10 rows above the blank row after the fence")
  h.assert_eq(text_height(), #FENCE_DOC - 4 + 10, "4 rows of the fence gone, 10 of image")
  finish_test()
end)

h.test("a diagram's source comes back with the cursor, on any row of the fence", function()
  setup()
  local buf = open(FENCE_DOC, 0)
  wait_for_images(buf)
  for _, row in ipairs { 2, 3, 4, 5 } do
    move_to(buf, row)
    h.assert_eq(image_marks(buf), {}, "cursor on row " .. row .. ": no image")
    h.assert_eq(vim.tbl_contains(concealed_rows(buf), 3), false, "the source row 3 is shown")
  end
  move_to(buf, 7)
  h.assert_eq(#image_marks(buf), 1, "cursor away: the image is back")
  h.assert_eq(vim.tbl_contains(concealed_rows(buf), 3), true, "and the source is concealed")
  finish_test()
end)

h.test("a diagram that ends the document", function()
  setup()
  local doc = { "intro", "", "```mermaid", "graph TD", "```" }
  local buf = open(doc, 0)
  wait_for_images(buf)
  h.assert_eq(image_marks(buf), { { 1, 10, false } }, "below the row before the fence")
  h.assert_eq(text_height(), 2 + 10, "intro, a blank row, and the diagram: the fence is gone")
  move_to(buf, 3)
  h.assert_eq(#image_marks(buf), 1, "the diagram stays while the source is edited")
  finish_test()
end)

h.test("a diagram in a list item", function()
  setup()
  local buf = open({ "- item", "  ```mermaid", "  graph TD", "  ```", "", "after" }, 5)
  wait_for_images(buf)
  local virt
  for _, m in ipairs(extmarks(buf)) do
    if m.d.virt_lines and m.d.virt_lines[1][#m.d.virt_lines[1]][2]:find "^RenderMdImg_" then virt = m.d.virt_lines end
  end
  h.assert_eq(virt[1][1], { "  " }, "indented like the item's content")
  h.assert_eq(text_height(), 6 - 3 + 10, "the item's three fence rows are gone")
  finish_test()
end)

h.test("a failed diagram leaves its fence alone", function()
  setup()
  h.stub(image, "has_mmdc", function()
    return false
  end)
  local buf = open(FENCE_DOC, 0)
  support.sleep(300)
  h.assert_eq(image_marks(buf), {}, "no image")
  h.assert_eq(text_height(), #FENCE_DOC - 1, "just render-markdown's block")
  finish_test()
end)

-- ============================================================================
-- Modes side by side
-- ============================================================================

h.test("images below and diagrams replaced", function()
  setup { config = { images = { mode = "below" }, diagrams = { mode = "replace" } } }
  local buf = open({ "![x](small.png)", "", "```mermaid", "graph", "```", "", "end" }, 6)
  h.wait_for(function()
    return #image_marks(buf) == 2
  end, 5000)
  h.assert_eq(vim.tbl_contains(concealed_rows(buf), 0), false, "the image row is not concealed")
  h.assert_eq(vim.tbl_contains(concealed_rows(buf), 3), true, "the diagram's source is")
  h.assert_eq(
    vim.tbl_map(function(m)
      return { m[1], m[3] }
    end, image_marks(buf)),
    { { 0, false }, { 5, true } },
    "the image below its line, the diagram above the row after the fence"
  )
  finish_test()
end)

h.test("images replaced and diagrams below", function()
  setup { config = { images = { mode = "replace" }, diagrams = { mode = "below" } } }
  local buf = open({ "![x](small.png)", "", "```mermaid", "graph", "```", "", "end" }, 6)
  h.wait_for(function()
    return #image_marks(buf) == 2
  end, 5000)
  h.assert_eq(vim.tbl_contains(concealed_rows(buf), 0), true, "the image row is concealed")
  h.assert_eq(vim.tbl_contains(concealed_rows(buf), 3), false, "the diagram's source is not")
  finish_test()
end)

h.test("both below: nothing concealed by us", function()
  setup { config = { images = { mode = "below" }, diagrams = { mode = "below" } } }
  local buf = open({ "![x](small.png)", "", "text" }, 2)
  wait_for_images(buf)
  h.assert_eq(concealed_rows(buf), {}, "no concealed rows")
  h.assert_eq(image_marks(buf), { { 0, 1, false } }, "below the line")
  finish_test()
end)

h.test("replace mode follows render-markdown's support for it", function()
  setup()
  h.assert_eq(handlers.can_replace(), true, "this render-markdown can draw a mark's replace")
  finish_test()
end)

h.finish "replace_render_test"
