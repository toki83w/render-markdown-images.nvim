-- Images below their lines, end to end: render-markdown parses, our handler asks the store, the store
-- works and asks for a render again, and the marks appear. Only the terminal is faked.
-- Needs a render-markdown.nvim checkout, see tests/render_markdown_test.lua.
-- Run: nvim --headless -u NONE --noplugin -l tests/images_render_test.lua

package.path = vim.fn.getcwd() .. "/?.lua;" .. package.path
local h = require "tests.harness"

local rm_path = h.find_plugin("RENDER_MARKDOWN_PATH", "render-markdown.nvim")
if not rm_path then
  if vim.env.RMI_REQUIRE_RENDER_MARKDOWN == "1" then
    print "images_render_test: FAIL: render-markdown.nvim not found"
    os.exit(1)
  end
  print "images_render_test: skip (render-markdown.nvim not found)"
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
local placeholder = require "render-markdown-images.placeholder"

local ns = vim.api.nvim_create_namespace "render-markdown.nvim"

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")

---@param path string
---@param w integer
---@param h_ integer
local function make_png(path, w, h_)
  local function be32(n)
    return string.char(math.floor(n / 16777216) % 256, math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256)
  end
  local f = assert(io.open(path, "wb"))
  f:write("\137PNG\r\n\26\n", be32(13), "IHDR", be32(w), be32(h_), "\8\2\0\0\0", "\0\0\0\0")
  f:close()
end
make_png(dir .. "/wide.png", 400, 200) -- 40 x 10 cells at 10 x 20 px
make_png(dir .. "/small.png", 40, 20) -- 4 x 1
make_png(dir .. "/tall.png", 40, 40) -- 4 x 2

--- Everything written to the terminal.
local sent = {}

---@param opts? { handlers?: boolean, config?: table } `config` goes to `render-markdown-images`'s setup
local function setup(opts)
  opts = opts or {}
  h.unstub()
  store.reset()
  marks.reset()
  sent = {}
  rmi.setup(opts.config)
  h.stub(vim.api, "nvim_ui_send", function(data)
    sent[#sent + 1] = data
  end)
  image.reset_cache()
  image._set_kitty_supported(true)
  image._set_in_tmux(false)
  image._reset_image_id()
  image._test_cell_size = { cell_w = 10, cell_h = 20 }
  h.stub(store.limits, "debounce", 10)
  h.stub(store.limits, "retry_delay", 0)
  rm.setup {
    anti_conceal = { enabled = false },
    debounce = 0,
    custom_handlers = opts.handlers == false and {} or rmi.handlers(),
  }
end

local function finish_test()
  h.unstub()
  store.reset()
  marks.reset()
  image._test_cell_size = nil
  image._set_kitty_supported(nil)
  image.reset_cache()
  rmi.setup()
end

--- A buffer `<dir>/doc-N.md` with `lines`, shown in the current window and rendered.
---@param lines string[]
---@return integer buf
local function open(lines)
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buf, ("%s/doc-%d.md"):format(dir, buf))
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_current_buf(buf)
  vim.bo[buf].filetype = "markdown"
  vim.treesitter.start(buf, "markdown")
  vim.wait(0)
  rm.render { buf = buf, force = true }
  return buf
end

--- The extmarks render-markdown has placed that carry virtual lines, as `{ row, virt_lines }`.
---@param buf integer
---@return { [1]: integer, [2]: table[] }[]
local function image_marks(buf)
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    local lines = m[4].virt_lines
    -- `RenderMdImg_` is our highlight group; render-markdown's own virtual lines (latex, tables) have others.
    if lines and lines[1] and lines[1][#lines[1]][2]:find "^RenderMdImg_" then out[#out + 1] = { m[2], lines } end
  end
  return out
end

---@param buf integer
---@param n integer how many image marks to wait for
---@return { [1]: integer, [2]: table[] }[]
local function wait_for_images(buf, n)
  h.wait_for(function()
    return #image_marks(buf) >= n
  end, 5000)
  return image_marks(buf)
end

local function sleep(ms)
  vim.wait(ms, function()
    return false
  end, 5)
end

--- The Kitty commands with a given action sent so far.
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

h.test("an image appears under its line once the store has it, and not before", function()
  setup()
  local buf = open { "# Title", "", "![wide](wide.png)", "", "after" }
  h.assert_eq(image_marks(buf), {}, "nothing yet: the image is still being worked on")
  h.wait_for(function()
    return store.peek(dir .. "/wide.png") ~= "missing"
  end, 3000)
  h.assert_eq(store.peek(dir .. "/wide.png") ~= "missing", true, "but it was asked for")

  local found = wait_for_images(buf, 1)
  h.assert_eq(#found, 1, "one image mark")
  h.assert_eq(found[1][1], 2, "on the row of the image")
  h.assert_eq(#found[1][2], 10, "ten rows: 400x200 px at 10x20 px cells")
  local first = found[1][2][1][#found[1][2][1]]
  h.assert_eq(first[1], placeholder.row_text(1, 40), "the placeholder row, 40 cells wide")
  local hl = vim.api.nvim_get_hl(0, { name = first[2], link = false })
  h.assert_eq(hl.fg, 101, "carrying the image id")
  h.assert_eq(hl.underline and hl.nocombine, true, "underlined and uncombined")

  h.assert_eq(#commands "t", 1, "one transmission")
  h.assert_eq(commands("t")[1]:match "^a=t,f=100,t=t,i=101,q=2;" ~= nil, true, "a=t,t=t, image id 101")
  h.assert_eq(#commands "p", 1, "one virtual placement")
  h.assert_eq(commands("p")[1]:match "^a=p,U=1,i=101,p=%d+,c=40,r=10,q=2$" ~= nil, true, "of 40 x 10 cells")
  finish_test()
end)

h.test("the source line stays, and render-markdown's own marks are untouched", function()
  setup { handlers = false }
  local lines = { "# Title", "", "![wide](wide.png)", "", "- [ ] item" }
  local baseline_buf = open(lines)
  sleep(150)
  local function plain_marks(buf)
    local out = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
      local d = vim.deepcopy(m[4])
      d.ns_id = nil
      out[#out + 1] = vim.inspect { m[2], m[3], d }
    end
    table.sort(out)
    return out
  end
  local baseline = plain_marks(baseline_buf)
  h.assert_eq(#baseline > 3, true, "render-markdown drew its own marks (" .. #baseline .. ")")

  setup()
  local buf = open(lines)
  wait_for_images(buf, 1)
  local with = plain_marks(buf)
  local extra = #with - #baseline
  h.assert_eq(extra, 1, "exactly one more mark: the image")
  h.assert_eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), lines, "the buffer text is as it was")
  finish_test()
end)

h.test("a re-render sends nothing to the terminal again", function()
  setup()
  local buf = open { "![wide](wide.png)" }
  wait_for_images(buf, 1)
  local t, p = #commands "t", #commands "p"
  for _ = 1, 3 do
    rm.render { buf = buf, force = true }
    sleep(60)
  end
  h.assert_eq(#image_marks(buf), 1, "still one image mark")
  h.assert_eq({ #commands "t", #commands "p" }, { t, p }, "no new transmission or placement")
  finish_test()
end)

h.test("a narrower window gets a smaller image, with its own placement", function()
  setup()
  local buf = open { "![wide](wide.png)" }
  local wide = wait_for_images(buf, 1)
  h.assert_eq(#wide[1][2], 10, "10 rows at 80 columns")
  -- A second window, showing something else: marks belong to the buffer, so two windows on it would fight.
  vim.cmd "botright vnew"
  vim.cmd "wincmd p"
  vim.cmd "vertical resize 30"
  rm.render { buf = buf, force = true }
  h.wait_for(function()
    local m = image_marks(buf)
    return #m == 1 and #m[1][2] ~= 10
  end, 3000)
  local narrow = image_marks(buf)
  vim.cmd "only"
  h.assert_eq(#commands "p", 2, "a second virtual placement for the new size")
  local cols, rows = commands("p")[2]:match "c=(%d+),r=(%d+)"
  h.assert_eq(tonumber(cols), 30, "30 columns: the width of the window")
  h.assert_eq(
    tonumber(rows) < 10 and tonumber(rows) >= 7,
    true,
    "about 7.5 rows for 400x200 px in 300 px (" .. rows .. ")"
  )
  h.assert_eq(#narrow[1][2], tonumber(rows), "as many lines as the placement has rows")
  h.assert_eq(#commands "t", 1, "the image itself was sent once")
  finish_test()
end)

h.test("images on several lines, stacked and spread", function()
  setup()
  local buf = open { "![a](small.png) text ![b](tall.png)", "", "![c](wide.png)" }
  local found = wait_for_images(buf, 2)
  h.wait_for(function()
    found = image_marks(buf)
    return #found == 2 and #found[1][2] == 3
  end, 5000)
  h.assert_eq(
    vim.tbl_map(function(m)
      return m[1]
    end, found),
    { 0, 2 },
    "one mark under the first line (both its images), one under the third"
  )
  h.assert_eq({ #found[1][2], #found[2][2] }, { 3, 10 }, "1 + 2 rows stacked, then 10")
  finish_test()
end)

h.test("images in a table go below it", function()
  setup()
  local buf = open { "| a | b |", "| - | - |", "| ![x](small.png) | ![y](tall.png) |", "", "text" }
  local found = wait_for_images(buf, 1)
  h.wait_for(function()
    found = image_marks(buf)
    return #found == 1 and #found[1][2] == 3
  end, 5000)
  h.assert_eq(#found, 1, "one mark")
  h.assert_eq(found[1][1], 2, "under the last row of the table")
  h.assert_eq(#found[1][2], 3, "with both images")
  finish_test()
end)

h.test("a missing file draws nothing and the buffer is not re-rendered for it", function()
  setup()
  local buf = open { "![x](nothing-here.png)" }
  sleep(200)
  h.assert_eq(image_marks(buf), {}, "nothing")
  h.assert_eq(store.stats().entries, 0, "and nothing asked for")
  finish_test()
end)

h.test("a terminal without Kitty graphics: render-markdown works as before", function()
  setup()
  image._set_kitty_supported(false)
  local buf = open { "# Title", "", "![wide](wide.png)" }
  sleep(200)
  h.assert_eq(image_marks(buf), {}, "no image")
  h.assert_eq(#sent, 0, "nothing sent")
  h.assert_eq(#vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}) > 0, true, "but render-markdown drew its own")
  finish_test()
end)

h.test("enabled = false switches the handler off", function()
  setup { config = { enabled = false } }
  local buf = open { "![wide](wide.png)" }
  sleep(200)
  h.assert_eq(image_marks(buf), {}, "no image")
  h.assert_eq(store.stats().entries, 0, "no work")
  finish_test()
end)

h.test("two buffers showing the same file share the transmission", function()
  setup()
  local a = open { "![wide](wide.png)" }
  wait_for_images(a, 1)
  local b = open { "text", "", "![wide](wide.png)" }
  local found = wait_for_images(b, 1)
  h.assert_eq(found[1][1], 2, "drawn in the second buffer too")
  h.assert_eq(#commands "t", 1, "one transmission for both")
  h.assert_eq(#commands "p", 1, "and one placement")
  finish_test()
end)

h.finish "images_render_test"
