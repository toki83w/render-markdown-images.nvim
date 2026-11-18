-- The images half of the markdown handler: discover -> store -> marks, without render-markdown itself.
-- (tests/render_markdown_test.lua and tests/images_render_test.lua run it inside the real thing.)
-- Run: nvim --headless -u NONE --noplugin -l tests/handler_test.lua

package.path = vim.fn.getcwd() .. "/?.lua;" .. package.path
local h = require "tests.harness"
local support = require "tests.support"
local make_png = support.make_png

vim.opt.rtp:prepend(h.root) -- for the queries
h.isolate_cache()
vim.o.columns = 80
vim.o.lines = 40

local rmi = require "render-markdown-images"
local handlers = require "render-markdown-images.handlers"
local store = require "render-markdown-images.store"
local image = require "render-markdown-images.image"
local marks = require "render-markdown-images.marks"
local placeholder = require "render-markdown-images.placeholder"

-- ============================================================================
-- Fixtures
-- ============================================================================

local dir = vim.fn.tempname()
vim.fn.mkdir(dir .. "/sub", "p")

make_png(dir .. "/wide.png", 400, 200) -- 40 x 10 cells at 10x20 px
make_png(dir .. "/small.png", 40, 20) -- 4 x 1 cells
make_png(dir .. "/sub/other.png", 40, 40) -- 4 x 2 cells
make_png(dir .. "/my pic.png", 40, 20)

--- What render-markdown does at the start of a render: a new request context, here by clearing ours.
---@param context table
local function new_render(context)
  context.rmi_ready = nil
end

--- The fake render-markdown context in use, if any; every `run` is a new render and gets a fresh one.
local fake_context ---@type table?

local function reset()
  fake_context = nil
  h.unstub()
  store.reset()
  marks.reset()
  rmi.setup()
  image._set_in_tmux(false)
  image._test_cell_size = { cell_w = 10, cell_h = 20 }
  h.stub(store.limits, "debounce", 10)
  h.stub(store.limits, "retry_delay", 0)
  h.stub(vim.api, "nvim_ui_send", function() end)
  -- Ids in order of transmission, and nothing rendered again: this test calls the handler itself.
  local n = 100
  h.stub(store, "transmit", function(_, done)
    n = n + 1
    done(n)
  end)
  h.stub(store, "render_buf", function() end)
  h.stub(package.loaded, "render-markdown.request.context", nil)
end

local function finish_test()
  h.unstub()
  store.reset()
  marks.reset()
  rmi.setup()
  image._test_cell_size = nil
  image.reset_cache()
end

--- A markdown buffer named `<dir>/doc.md`, shown in the current window.
---@param lines string[]
---@param opts? { shown?: boolean }
---@return integer buf
local function open(lines, opts)
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buf, dir .. "/doc-" .. buf .. ".md")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  if not opts or opts.shown ~= false then vim.api.nvim_set_current_buf(buf) end
  vim.bo[buf].filetype = "markdown"
  vim.treesitter.start(buf, "markdown")
  vim.treesitter.get_parser(buf, "markdown"):parse(true)
  return buf
end

--- Run the handler over the markdown tree, as render-markdown does. Returns its marks.
---@param buf integer
---@return render.md.Mark[]
local function run(buf)
  local root = vim.treesitter.get_parser(buf, "markdown"):parse(true)[1]:root()
  if fake_context then new_render(fake_context) end
  return handlers.new().markdown.parse { buf = buf, root = root, last = true }
end

--- Run again until marks appear: the first pass only asks the store, which answers later.
---@param buf integer
---@return render.md.Mark[]
local function run_until_marks(buf)
  local result = run(buf)
  h.wait_for(function()
    result = run(buf)
    return #result > 0
  end, 3000)
  return result
end

local function sleep(ms)
  vim.wait(ms, function()
    return false
  end, 5)
end

--- Pretend to be render-markdown's request context, so that roots can share what they collect.
---@param win integer
---@return table context
local function fake_render_markdown_context(win)
  local context = { win = win }
  fake_context = context
  h.stub(package.loaded, "render-markdown.request.context", {
    get = function()
      return context
    end,
  })
  return context
end

-- ============================================================================
-- The path of one image
-- ============================================================================

h.test("pending: nothing is drawn, the store is asked, and a buffer waiting is remembered", function()
  reset()
  local buf = open { "![x](wide.png)" }
  h.assert_eq(run(buf), {}, "no marks while the image is not ready")
  h.assert_eq(store.peek(dir .. "/wide.png") ~= "missing", true, "the store has the image's resolved path")
  h.assert_eq(store.stats().entries, 1, "and only that")
  finish_test()
end)

h.test("ready: one mark under the image's row with the right number of rows", function()
  reset()
  local buf = open { "text", "", "![x](wide.png)", "", "more" }
  local result = run_until_marks(buf)
  h.assert_eq(#result, 1, "one mark")
  h.assert_eq(
    { result[1].start_row, result[1].start_col, result[1].conceal },
    { 2, 0, false },
    "row 2, column 0, not concealed"
  )
  h.assert_eq(#result[1].opts.virt_lines, 10, "10 rows: 400x200 px at 10x20 px cells is 40x10")
  local _, entry = store.get(dir .. "/wide.png")
  local p = marks.placement(entry.id, 40, 10)
  h.assert_eq(
    result[1].opts.virt_lines[1],
    { { placeholder.row_text(1, 40), p.hl } },
    "first row: placeholders in the placement's highlight"
  )
  h.assert_eq(result[1].opts.virt_lines[10], { { placeholder.row_text(10, 40), p.hl } }, "last row")
  finish_test()
end)

h.test("ready: the id and size in the marks are the transmitted image's", function()
  reset()
  local buf = open { "![x](small.png)" }
  local result = run_until_marks(buf)
  local _, entry = store.get(dir .. "/small.png")
  h.assert_eq({ entry.id, entry.w, entry.h }, { 101, 40, 20 }, "the entry")
  local hl = vim.api.nvim_get_hl(0, { name = result[1].opts.virt_lines[1][1][2], link = false })
  h.assert_eq(hl.fg, 101, "the highlight carries the image id")
  h.assert_eq(#result[1].opts.virt_lines, 1, "40x20 px is one row")
  h.assert_eq(vim.fn.strchars(result[1].opts.virt_lines[1][1][1]), 4 * 3, "four cells")
  finish_test()
end)

h.test("a multi-line image is drawn under its last row", function()
  reset()
  local buf = open { "![a description", "over two lines](small.png)", "after" }
  local result = run_until_marks(buf)
  h.assert_eq(result[1].start_row, 1, "under the second row")
  finish_test()
end)

h.test("an image that is not a file is not drawn and not asked for", function()
  reset()
  local buf = open { "![x](missing.png)", "![y](sub)" }
  h.assert_eq(run(buf), {}, "no marks")
  sleep(30)
  h.assert_eq(store.stats().entries, 0, "no store entry: it costs a stat, nothing more")
  finish_test()
end)

h.test("remote images and Obsidian names are left alone for now", function()
  reset()
  local buf = open { "![x](https://example.test/a.png)", "![[wide.png]]" }
  h.assert_eq(run(buf), {}, "nothing drawn")
  -- `![[wide.png]]` is a name in a vault; relative to the note it is a file here, and is found.
  h.assert_eq(store.peek "https://example.test/a.png", "missing", "the URL was not asked for")
  finish_test()
end)

h.test("a wikilink embed that names a file next to the note is drawn", function()
  reset()
  local buf = open { "![[small.png|300]]" }
  local result = run_until_marks(buf)
  h.assert_eq(#result, 1, "drawn")
  finish_test()
end)

-- ============================================================================
-- Paths
-- ============================================================================

h.test("resolve_local: relative to the note's directory, not the working directory", function()
  h.assert_eq(handlers.resolve_local("wide.png", dir), dir .. "/wide.png", "same directory")
  h.assert_eq(handlers.resolve_local("sub/other.png", dir), dir .. "/sub/other.png", "subdirectory")
  h.assert_eq(handlers.resolve_local("../wide.png", dir .. "/sub"), dir .. "/wide.png", "parent directory, normalized")
  h.assert_eq(handlers.resolve_local("./wide.png", dir), dir .. "/wide.png", "dot slash")
  h.assert_eq(handlers.resolve_local("wide.png", "/nonexistent"), nil, "not found")
end)

h.test("resolve_local: absolute paths and ~", function()
  h.assert_eq(handlers.resolve_local(dir .. "/wide.png", "/elsewhere"), dir .. "/wide.png", "absolute")
  local saved = vim.env.HOME
  vim.env.HOME = dir
  local ok, found = pcall(handlers.resolve_local, "~/wide.png", "/elsewhere")
  vim.env.HOME = saved
  h.assert_eq(ok and found, dir .. "/wide.png", "~ is the home directory")
end)

h.test("resolve_local: percent-escapes are decoded when the name as written is not there", function()
  h.assert_eq(handlers.resolve_local("my%20pic.png", dir), dir .. "/my pic.png", "%20")
  h.assert_eq(handlers.resolve_local("my pic.png", dir), dir .. "/my pic.png", "a literal space works too")
  h.assert_eq(handlers.resolve_local("my%20nothing.png", dir), nil, "decoded and still not there")
  make_png(dir .. "/100%25.png", 10, 10)
  h.assert_eq(
    handlers.resolve_local("100%25.png", dir),
    dir .. "/100%25.png",
    "a name that really holds %25 is used as written"
  )
end)

h.test("resolve_local: a directory is not an image", function()
  h.assert_eq(handlers.resolve_local("sub", dir), nil, "directory")
end)

h.test("images are found relative to the buffer, with spaces and escapes", function()
  reset()
  local buf = open { "![a](sub/other.png)", "", "![b](<my pic.png>)", "", "![c](my%20pic.png)" }
  local result = run_until_marks(buf)
  h.wait_for(function()
    result = run(buf)
    return #result == 3
  end)
  h.assert_eq(
    vim.tbl_map(function(m)
      return m.start_row
    end, result),
    { 0, 2, 4 },
    "all three, each under its own row"
  )
  h.assert_eq(store.stats().entries, 2, "two files: `my pic.png` is asked for once")
  finish_test()
end)

h.test("a buffer without a name resolves against the working directory", function()
  reset()
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "![x](wide.png)" })
  vim.api.nvim_set_current_buf(buf)
  vim.bo[buf].filetype = "markdown"
  vim.treesitter.start(buf, "markdown")
  vim.treesitter.get_parser(buf, "markdown"):parse(true)
  local saved = vim.fn.getcwd()
  vim.cmd.cd(dir)
  run(buf)
  local status = store.peek(dir .. "/wide.png")
  vim.cmd.cd(saved)
  h.assert_eq(status ~= "missing", true, "found in the working directory")
  finish_test()
end)

-- ============================================================================
-- When nothing is drawn
-- ============================================================================

h.test("a buffer that is not in a window has nowhere to draw", function()
  reset()
  local other = open { "other" }
  local buf = open({ "![x](small.png)" }, { shown = false })
  vim.api.nvim_set_current_buf(other)
  run(buf)
  h.wait_for(function()
    return store.peek(dir .. "/small.png") == "ready"
  end)
  h.assert_eq(run(buf), {}, "ready, but no window: no marks")
  finish_test()
end)

h.test("an invalid buffer or root is no marks", function()
  reset()
  local handler = handlers.new().markdown
  h.assert_eq(handler.parse { buf = 99999, root = nil, last = true }, {}, "no root")
  h.assert_eq(handler.parse { buf = 0, root = nil, last = true }, {}, "no root, current buffer")
  finish_test()
end)

h.test("a document with no images costs nothing", function()
  reset()
  local buf = open { "# Title", "", "Just text and a [link](https://example.test)." }
  h.assert_eq(run(buf), {}, "no marks")
  h.assert_eq(store.stats().entries, 0, "no entries")
  finish_test()
end)

-- ============================================================================
-- Several images
-- ============================================================================

h.test("the same file twice is one job and one placement", function()
  reset()
  local buf = open { "![a](wide.png)", "", "![b](wide.png)" }
  local result = run_until_marks(buf)
  h.wait_for(function()
    result = run(buf)
    return #result == 2
  end)
  h.assert_eq(store.stats().entries, 1, "one store entry")
  h.assert_eq(marks.placement_count(), 1, "one virtual placement")
  h.assert_eq(result[1].opts.virt_lines, result[2].opts.virt_lines, "same lines")
  finish_test()
end)

h.test("two images on one line stack in one mark, left to right", function()
  reset()
  local buf = open { "![a](small.png) and ![b](sub/other.png)" }
  local result = run_until_marks(buf)
  h.wait_for(function()
    result = run(buf)
    return #result > 0 and #result[1].opts.virt_lines == 3
  end)
  h.assert_eq(#result, 1, "one mark")
  h.assert_eq(#result[1].opts.virt_lines, 3, "one row (4x1 cells) and two rows (4x2)")
  local _, first = store.get(dir .. "/small.png")
  local _, second = store.get(dir .. "/sub/other.png")
  h.assert_eq(
    vim.api.nvim_get_hl(0, { name = result[1].opts.virt_lines[1][1][2], link = false }).fg,
    first.id,
    "the left image comes first"
  )
  h.assert_eq(
    vim.api.nvim_get_hl(0, { name = result[1].opts.virt_lines[2][1][2], link = false }).fg,
    second.id,
    "then the right one"
  )
  finish_test()
end)

h.test("an image that is not ready yet does not hold back one that is", function()
  reset()
  local buf = open { "![a](small.png)", "", "![b](sub/other.png)" }
  local release
  h.stub(store, "transmit", function(path, done)
    if path:find("other.png", 1, true) then
      release = function()
        done(150)
      end
    else
      done(101)
    end
  end)
  run(buf)
  h.wait_for(function()
    return store.peek(dir .. "/small.png") == "ready"
  end)
  local result = run(buf)
  h.assert_eq(#result, 1, "only the ready one")
  h.assert_eq(result[1].start_row, 0, "under its row")
  h.wait_for(function()
    return release ~= nil
  end)
  release()
  h.wait_for(function()
    return #run(buf) == 2
  end)
  h.assert_eq(#run(buf), 2, "both, once the other is ready")
  finish_test()
end)

-- ============================================================================
-- Containers
-- ============================================================================

h.test("an image in a list item is indented with its text", function()
  reset()
  local buf = open { "- item", "  - ![x](small.png)" }
  local result = run_until_marks(buf)
  local line = result[1].opts.virt_lines[1]
  h.assert_eq(line[1], { "    " }, "four columns: the nested item's content")
  h.assert_eq(#line, 2, "then the placeholders")
  finish_test()
end)

h.test("the indent narrows the image", function()
  reset()
  local win = vim.api.nvim_get_current_win()
  local width = vim.api.nvim_win_get_width(win)
  make_png(dir .. "/huge.png", 20000, 2000)
  local buf = open { "- ![x](huge.png)" }
  local result = run_until_marks(buf)
  local line = result[1].opts.virt_lines[1]
  h.assert_eq(line[1], { "  " }, "indent 2")
  h.assert_eq(
    vim.fn.strchars(line[2][1]),
    (width - vim.fn.getwininfo(win)[1].textoff - 2) * 3,
    "the cells fit what is left of the window"
  )
  finish_test()
end)

h.test("images in a table go below the table, together", function()
  reset()
  local buf = open {
    "| a | b |",
    "| - | - |",
    "| ![x](small.png) | text |",
    "| text | ![y](sub/other.png) |",
    "",
    "after the table",
  }
  fake_render_markdown_context(vim.api.nvim_get_current_win())
  local result = run_until_marks(buf)
  h.wait_for(function()
    result = run(buf)
    return #result > 0 and #result[1].opts.virt_lines == 3
  end)
  h.assert_eq(#result, 1, "one mark, though the images are in different cells")
  h.assert_eq(result[1].start_row, 3, "under the last row of the table, not inside it")
  h.assert_eq(#result[1].opts.virt_lines, 3, "both images, stacked")
  finish_test()
end)

h.test("with render-markdown's context the marks come with the last root only", function()
  reset()
  local buf = open { "![a](small.png)", "", "text", "", "![b](sub/other.png)" }
  local context = fake_render_markdown_context(vim.api.nvim_get_current_win())
  run(buf)
  h.wait_for(function()
    return store.stats().running == 0 and store.stats().queued == 0
  end)
  sleep(20)
  new_render(context)
  local root = vim.treesitter.get_parser(buf, "markdown"):parse(true)[1]:root()
  local handler = handlers.new().markdown
  h.assert_eq(
    handler.parse { buf = buf, root = root, last = false },
    {},
    "not the last root: collected, nothing returned"
  )
  new_render(context)
  h.assert_eq(#handler.parse { buf = buf, root = root, last = true }, 2, "the last root: both images' marks")
  finish_test()
end)

h.test("only what render-markdown has in view is asked for", function()
  reset()
  local buf = open { "![a](small.png)", "", "text", "", "![b](sub/other.png)" }
  local context = fake_render_markdown_context(vim.api.nvim_get_current_win())
  context.view = {
    overlaps = function(_, node)
      return (node:range()) < 3 -- the first paragraph only
    end,
  }
  run_until_marks(buf)
  h.wait_for(function()
    return store.stats().running == 0 and store.stats().queued == 0
  end)
  h.assert_eq(store.peek(dir .. "/small.png"), "ready", "the image in view")
  h.assert_eq(store.peek(dir .. "/sub/other.png"), "missing", "the one out of view is not even asked for")
  local result = run(buf)
  h.assert_eq(#result, 1, "one mark")
  finish_test()
end)

h.test("a view that cannot be asked is no restriction", function()
  reset()
  local buf = open { "![a](small.png)", "", "![b](sub/other.png)" }
  local context = fake_render_markdown_context(vim.api.nvim_get_current_win())
  context.view = {
    overlaps = function()
      error "no such method here"
    end,
  }
  run_until_marks(buf)
  h.wait_for(function()
    return store.peek(dir .. "/sub/other.png") == "ready"
  end)
  h.assert_eq(#run(buf), 2, "both")
  finish_test()
end)

h.test("images are found whatever state the injected inline trees are in", function()
  reset()
  local buf = open { "intro", "", "![a](small.png)", "", "text ![b](sub/other.png) text", "", "end" }
  local parser = vim.treesitter.get_parser(buf, "markdown")
  -- Partial parses, as the highlighter and render-markdown make them: they drop the regions outside the
  -- rows asked for, and `for_each_tree` can then be wrong about the rest.
  parser:invalidate(true)
  parser:parse { 0, 0 }
  local result = run_until_marks(buf, 2)
  h.wait_for(function()
    parser:invalidate(true)
    parser:parse { 6, 6 }
    result = run(buf)
    return #result == 2
  end)
  h.assert_eq(#result, 2, "both images, from the block tree's own text")
  finish_test()
end)

h.test("a new render starts a new collection", function()
  reset()
  local buf = open { "![a](small.png)" }
  local context = fake_render_markdown_context(vim.api.nvim_get_current_win())
  run(buf)
  h.wait_for(function()
    return store.peek(dir .. "/small.png") == "ready"
  end)
  h.assert_eq(#run(buf), 1, "first render: one mark")
  new_render(context)
  h.assert_eq(#run(buf), 1, "a new context: one mark, not two")
  finish_test()
end)

-- ============================================================================
-- images.mode = "replace"
-- ============================================================================

--- Let the handler believe render-markdown can draw a mark's `replace`.
local function with_replace_support()
  h.stub(package.loaded, "render-markdown.lib.replacements", {})
end

--- `images.mode = "replace"`, and the stand-in answer about the terminal given again (setup resets it).
local function replace_mode()
  rmi.setup { images = { mode = "replace" } }
  with_replace_support()
end

--- The marks of every kind, once the images are ready: `{ conceal_lines | conceal | virt_lines | replace, ... }`
---@param marks_ render.md.Mark[]
---@return string[]
local function kinds(marks_)
  local out = vim.tbl_map(function(m)
    if m.replace then return "replace" end
    if m.opts.conceal_lines then return "conceal_lines" end
    if m.opts.conceal then return "conceal" end
    return m.conceal and "virt_lines(hidden)" or "virt_lines"
  end, marks_)
  table.sort(out)
  return out
end

h.test("replace mode: can_replace needs Neovim 0.11 and render-markdown's `replace`", function()
  reset()
  h.assert_eq(handlers.can_replace(), false, "no render-markdown here")
  with_replace_support()
  h.assert_eq(handlers.can_replace(), true, "with it")
  local has = vim.fn.has
  h.stub(vim.fn, "has", function(feature)
    if feature == "nvim-0.11" then return 0 end
    return has(feature)
  end)
  h.assert_eq(handlers.can_replace(), false, "but not on an old Neovim: no conceal_lines")
  finish_test()
end)

h.test("replace mode without render-markdown's `replace`: drawn below, the source untouched", function()
  reset()
  rmi.setup { images = { mode = "replace" } }
  local buf = open { "![x](small.png)" }
  local result = run_until_marks(buf)
  h.assert_eq(kinds(result), { "virt_lines" }, "just virtual lines below")
  h.assert_eq(result[1].conceal, false, "never hidden")
  finish_test()
end)

h.test("replace mode: an image alone on its line replaces the row", function()
  reset()
  replace_mode()
  local buf = open { "text", "", "![x](wide.png)", "", "more" }
  h.assert_eq(run(buf), {}, "while pending nothing is hidden: the source stays")
  local result = run_until_marks(buf)
  h.assert_eq(#result, 1, "one mark")
  h.assert_eq({
    result[1].conceal,
    result[1].start_row,
    result[1].start_col,
    result[1].opts.end_row,
    result[1].opts.end_col,
    result[1].opts.conceal_lines,
  }, { true, 2, 0, 2, 14, "" }, "conceal_lines over the whole row, hidden by anti-conceal")
  h.assert_eq(#result[1].replace, 10, "the image as `replace`: 10 rows")
  finish_test()
end)

h.test("replace mode: a multi-line image alone replaces all its rows", function()
  reset()
  replace_mode()
  local buf = open { "text", "", "![a long", "description](small.png)", "", "more" }
  local result = run_until_marks(buf)
  h.assert_eq(
    { result[1].start_row, result[1].opts.end_row, result[1].opts.end_col },
    { 2, 3, 23 },
    "rows 2 and 3, to the end of the second"
  )
  finish_test()
end)

h.test("replace mode: an image among text loses only its own syntax; the image goes below", function()
  reset()
  replace_mode()
  local buf = open { "before ![x](small.png) after", "", "end" }
  local result = run_until_marks(buf)
  h.wait_for(function()
    result = run(buf)
    return #result == 2
  end)
  h.assert_eq(kinds(result), { "conceal", "virt_lines(hidden)" }, "the span, and the image below it")
  local span = vim.tbl_filter(function(m)
    return m.opts.conceal
  end, result)[1]
  h.assert_eq(
    { span.conceal, span.start_row, span.start_col, span.opts.end_row, span.opts.end_col },
    { true, 0, 7, 0, 22 },
    "exactly `![x](small.png)`"
  )
  finish_test()
end)

h.test("replace mode: two images in a line each lose their syntax, and stack below", function()
  reset()
  replace_mode()
  local buf = open { "![a](small.png) and ![b](sub/other.png)" }
  local result
  h.wait_for(function()
    result = run(buf)
    return #result == 3
  end)
  h.assert_eq(kinds(result), { "conceal", "conceal", "virt_lines(hidden)" }, "two spans, one stack")
  local stack = vim.tbl_filter(function(m)
    return m.opts.virt_lines
  end, result)[1]
  h.assert_eq(#stack.opts.virt_lines, 3, "1 + 2 rows")
  finish_test()
end)

h.test("replace mode: an image alone in a list item keeps the marker", function()
  reset()
  replace_mode()
  local buf = open { "- ![x](small.png)", "", "text" }
  local result
  h.wait_for(function()
    result = run(buf)
    return #result == 2
  end)
  h.assert_eq(kinds(result), { "conceal", "virt_lines(hidden)" }, "span and image: the row, with its bullet, stays")
  local span = vim.tbl_filter(function(m)
    return m.opts.conceal
  end, result)[1]
  h.assert_eq({ span.start_col, span.opts.end_col }, { 2, 17 }, "after `- `")
  local stack = vim.tbl_filter(function(m)
    return m.opts.virt_lines
  end, result)[1]
  h.assert_eq(stack.opts.virt_lines[1][1], { "  " }, "image indented with the item")
  finish_test()
end)

h.test("replace mode: an image in a table stays below the table, the cell keeps its text", function()
  reset()
  replace_mode()
  local buf = open { "| a | b |", "| - | - |", "| ![x](small.png) | text |", "", "after" }
  local result = run_until_marks(buf)
  h.assert_eq(kinds(result), { "virt_lines" }, "below mode, nothing concealed")
  h.assert_eq(result[1].start_row, 2, "under the table")
  finish_test()
end)

h.test("replace mode: the last row of the buffer is concealed here, the image goes under the row before", function()
  reset()
  replace_mode()
  local buf = open { "text", "", "![x](small.png)" }
  local result = run_until_marks(buf)
  h.wait_for(function()
    result = run(buf)
    return #result == 2
  end)
  h.assert_eq(kinds(result), { "conceal_lines", "virt_lines" }, "no `replace`: render-markdown has no row below")
  local stack = vim.tbl_filter(function(m)
    return m.opts.virt_lines
  end, result)[1]
  h.assert_eq({ stack.start_row, stack.conceal }, { 1, false }, "below row 1, and kept when the cursor enters")
  finish_test()
end)

h.test("replace mode: `images.mode = below` leaves images alone while diagrams may be replaced", function()
  reset()
  rmi.setup { diagrams = { mode = "replace" } }
  with_replace_support()
  local buf = open { "![x](small.png)", "", "text" }
  local result = run_until_marks(buf)
  h.assert_eq(kinds(result), { "virt_lines" }, "images below")
  finish_test()
end)

h.finish "handler_test"
