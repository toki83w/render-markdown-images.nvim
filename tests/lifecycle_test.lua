-- lifecycle: what happens when windows change size, the colours change, buffers go away, and Neovim exits.
-- The handler is run by hand where render-markdown would run it; the renderer and the terminal are stand-ins.
-- Run: nvim --headless -u NONE --noplugin -l tests/lifecycle_test.lua

package.path = vim.fn.getcwd() .. "/?.lua;" .. package.path
local h = require "tests.harness"
local support = require "tests.support"

vim.opt.rtp:prepend(h.root) -- for the queries
h.isolate_cache()
vim.o.columns = 120
vim.o.lines = 50

local rmi = require "render-markdown-images"
local handlers = require "render-markdown-images.handlers"
local lifecycle = require "render-markdown-images.lifecycle"
local store = require "render-markdown-images.store"
local image = require "render-markdown-images.image"
local marks = require "render-markdown-images.marks"
local log = require "render-markdown-images.log"

local GROUP = "render-markdown-images"
local PRUNE_WAIT = 400 -- the plugin waits 200 ms before deleting placements nobody uses

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
support.make_png(dir .. "/wide.png", 1000, 100) -- 40 x 2 cells in 40 columns, 20 x 1 in 20
support.make_png(dir .. "/small.png", 40, 20)
local diagram_png = dir .. "/diagram.png"
support.make_png(diagram_png, 400, 200)

--- Everything written to the terminal.
local sent = {}
--- The buffers `store.render_buf` was asked to render.
local rendered = {}
--- What to do instead of render-markdown rendering a buffer: run the handler, as it would.
---@type fun(buf: integer)?
local on_render
--- The colours of each Mermaid render.
local mermaid_runs

local function reset()
  h.unstub()
  lifecycle.reset()
  store.reset()
  marks.reset()
  log.reset()
  rmi.setup()
  sent, rendered, on_render, mermaid_runs = {}, {}, nil, {}
  image.reset_cache()
  image._set_in_tmux(false)
  image._test_cell_size = { cell_w = 10, cell_h = 20 }
  vim.o.background = "dark"
  h.stub(vim.api, "nvim_ui_send", function(data)
    sent[#sent + 1] = data
  end)
  h.stub(store.limits, "debounce", 10)
  h.stub(store.limits, "retry_delay", 0)
  local n = 100
  h.stub(store, "transmit", function(_, done)
    n = n + 1
    done(n)
  end)
  h.stub(store, "render_buf", function(buf)
    rendered[#rendered + 1] = buf
    if on_render then on_render(buf) end
  end)
  h.stub(package.loaded, "render-markdown.request.context", nil)
  h.stub(image, "has_mmdc", function()
    return true
  end)
  h.stub(image, "render_mermaid_async", function(_, cb)
    mermaid_runs[#mermaid_runs + 1] = image.mermaid_theme()
    cb(diagram_png)
  end)
  lifecycle.ensure()
end

local function finish_test()
  h.unstub()
  lifecycle.reset()
  store.reset()
  marks.reset()
  image._test_cell_size = nil
  image.reset_cache()
  vim.o.background = "dark"
  vim.cmd "silent! only!"
  vim.cmd "silent! %bwipeout!"
  rmi.setup()
end

--- A markdown buffer shown in a floating window `width` cells wide.
---@param lines string[]
---@param width? integer
---@return integer buf, integer win
local function open(lines, width)
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buf, ("%s/doc-%d.md"):format(dir, buf))
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = 0,
    col = 0,
    width = width or 40,
    height = 20,
    style = "minimal",
  })
  vim.bo[buf].filetype = "markdown"
  vim.treesitter.start(buf, "markdown")
  vim.treesitter.get_parser(buf, "markdown"):parse(true)
  return buf, win
end

--- Run the handler over a buffer, as render-markdown would.
---@param buf integer
---@return render.md.Mark[]
local function run(buf)
  if not vim.api.nvim_buf_is_valid(buf) then return {} end
  local root = vim.treesitter.get_parser(buf, "markdown"):parse(true)[1]:root()
  return handlers.new().markdown.parse { buf = buf, root = root, last = true }
end

local function run_until_marks(buf, n)
  local result = run(buf)
  h.wait_for(function()
    result = run(buf)
    return #result >= (n or 1)
  end, 3000)
  return result
end

--- The Kitty graphics commands sent so far.
---@param action? string only those starting with `a=<action>`
---@return string[]
local function commands(action)
  local out = {}
  for seq in table.concat(sent):gmatch "\27_G([^\27]*)\27\\" do
    if not action or seq:find("^a=" .. action .. ",") then out[#out + 1] = seq end
  end
  return out
end

--- The commands that delete an image with its data (`d=I`).
---@return string[]
local function image_deletes()
  return vim.tbl_filter(function(c)
    return c:find "^a=d,d=I,"
  end, commands "d")
end

--- The grid of a virtual placement command: `a=p,U=1,i=…,p=…,c=<cols>,r=<rows>`.
---@param command string
---@return integer cols, integer rows
local function grid_of(command)
  local cols, rows = command:match "c=(%d+),r=(%d+)"
  return tonumber(cols), tonumber(rows)
end

--- Let what the store asks to be rendered when an image is ready happen, and forget it: a test of what
--- the lifecycle asks for must not count that.
local function settled()
  support.sleep(120)
  rendered = {}
end

local function wait_rendered(n)
  return h.wait_for(function()
    return #rendered >= n
  end, 2000)
end

-- ============================================================================
-- The autocommands
-- ============================================================================

h.test("the autocommands are made once, by setup() or by the first handler, and can be removed", function()
  reset()
  local function count()
    return #vim.api.nvim_get_autocmds { group = GROUP }
  end
  local n = count()
  h.assert_eq(n > 0, true, "there are some (" .. n .. ")")
  lifecycle.ensure()
  rmi.setup()
  h.assert_eq(count(), n, "the same number after more calls")
  local events = {}
  for _, a in ipairs(vim.api.nvim_get_autocmds { group = GROUP }) do
    events[a.event] = true
  end
  for _, event in ipairs {
    "WinResized",
    "VimResized",
    "OptionSet",
    "ColorScheme",
    "BufUnload",
    "BufWipeout",
    "VimLeavePre",
  } do
    h.assert_eq(events[event], true, event .. " is watched")
  end
  lifecycle.reset()
  h.assert_eq(pcall(vim.api.nvim_get_autocmds, { group = GROUP }), false, "gone")
  finish_test()
end)

h.test("setup() does not load the image module", function()
  reset()
  lifecycle.reset()
  local loaded = package.loaded["render-markdown-images.image"]
  package.loaded["render-markdown-images.image"] = nil
  rmi.setup()
  h.assert_eq(package.loaded["render-markdown-images.image"], nil, "not loaded by setup")
  package.loaded["render-markdown-images.image"] = loaded
  finish_test()
end)

-- ============================================================================
-- Resizing
-- ============================================================================

local WIDE = { "![wide](wide.png)", "", "text" }

h.test("a buffer with images is noted, and forgotten when it has none", function()
  reset()
  local buf = open(WIDE)
  h.assert_eq(lifecycle.buffers(), {}, "nothing drawn yet")
  run_until_marks(buf)
  h.assert_eq(lifecycle.buffers(), { buf }, "drawn")
  vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "no image any more" })
  vim.treesitter.get_parser(buf, "markdown"):parse(true)
  run(buf)
  h.assert_eq(lifecycle.buffers(), {}, "nothing drawn: not noted")
  finish_test()
end)

h.test("a window that changes size has its image drawn again at the new size", function()
  reset()
  local buf, win = open(WIDE, 40)
  on_render = run
  run_until_marks(buf)
  settled()
  local placements = commands "p"
  h.assert_eq(#placements, 1, "one placement")
  h.assert_eq({ grid_of(placements[1]) }, { 40, 2 }, "40 x 2 cells in 40 columns")

  vim.api.nvim_win_set_width(win, 20)
  lifecycle.win_resized { win }
  h.assert_eq(wait_rendered(1), true, "the buffer is rendered again")
  h.assert_eq(rendered, { buf }, "that buffer")
  placements = commands "p"
  h.assert_eq(#placements, 2, "a second placement")
  h.assert_eq({ grid_of(placements[2]) }, { 20, 1 }, "20 x 1 cells in 20 columns")
  finish_test()
end)

h.test("the placement the old size left behind is deleted, after a moment, and its highlight with it", function()
  reset()
  local buf, win = open(WIDE, 40)
  on_render = run
  run_until_marks(buf)
  local first = commands("p")[1]
  local id, pid = first:match "i=(%d+),p=(%d+)"
  local group = "RenderMdImg_" .. pid
  h.assert_eq(vim.api.nvim_get_hl(0, { name = group, link = false }).fg, tonumber(id), "its highlight is defined")

  vim.api.nvim_win_set_width(win, 20)
  lifecycle.win_resized { win }
  wait_rendered(1)
  h.assert_eq(#commands "d", 0, "not deleted at once: its cells are still on screen")
  h.assert_eq(marks.placement_count(), 2, "both exist")

  h.wait_for(function()
    return #commands "d" > 0
  end, PRUNE_WAIT * 3)
  h.assert_eq(commands "d", { ("a=d,d=i,i=%s,p=%s,q=2"):format(id, pid) }, "the old one only, the image kept")
  h.assert_eq(marks.placement_count(), 1, "one left")
  h.assert_eq(vim.api.nvim_get_hl(0, { name = group, link = false }), {}, "its highlight is cleared")
  finish_test()
end)

h.test("a window that shows nothing of ours is left alone", function()
  reset()
  local buf = open(WIDE, 40)
  run_until_marks(buf)
  support.sleep(100) -- the render the store asks for when the image is ready
  rendered = {}
  local other, other_win = open({ "just text" }, 30)
  run(other)
  lifecycle.win_resized { other_win }
  support.sleep(100)
  h.assert_eq(rendered, {}, "nothing rendered again")
  finish_test()
end)

h.test("a window that is gone is not a problem", function()
  reset()
  local buf, win = open(WIDE, 40)
  run_until_marks(buf)
  vim.api.nvim_win_close(win, true)
  h.assert_eq(pcall(lifecycle.win_resized, { win, 99999 }), true, "no error")
  finish_test()
end)

h.test("VimResized draws every buffer with images again", function()
  reset()
  local a = open(WIDE, 40)
  run_until_marks(a)
  local b = open({ "![small](small.png)" }, 30)
  run_until_marks(b)
  settled()
  vim.api.nvim_exec_autocmds("VimResized", { group = GROUP })
  wait_rendered(2)
  table.sort(rendered)
  h.assert_eq(rendered, { a, b }, "both, once each")
  finish_test()
end)

h.test("changing what takes room before the text draws the images again", function()
  reset()
  local buf, win = open(WIDE, 40)
  run_until_marks(buf)
  settled()
  vim.wo[win].number = true
  h.assert_eq(wait_rendered(1), true, "'number'")
  rendered = {}
  vim.wo[win].signcolumn = "yes:2"
  h.assert_eq(wait_rendered(1), true, "'signcolumn'")
  rendered = {}
  vim.wo[win].foldcolumn = "3"
  h.assert_eq(wait_rendered(1), true, "'foldcolumn'")
  finish_test()
end)

h.test("a narrower text area gets a smaller image", function()
  reset()
  local buf, win = open(WIDE, 40)
  on_render = run
  run_until_marks(buf)
  settled()
  vim.wo[win].number = true
  wait_rendered(1)
  local placements = commands "p"
  local cols = grid_of(placements[#placements])
  h.assert_eq(cols < 40, true, "narrower than 40: the number column takes room (" .. cols .. ")")
  finish_test()
end)

-- ============================================================================
-- Placements nobody uses
-- ============================================================================

h.test("an image that leaves the document has its placement deleted", function()
  reset()
  local buf = open(WIDE, 40)
  run_until_marks(buf)
  h.assert_eq(marks.placement_count(), 1, "one placement")
  vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "gone" })
  vim.treesitter.get_parser(buf, "markdown"):parse(true)
  run(buf)
  h.wait_for(function()
    return #commands "d" > 0
  end, PRUNE_WAIT * 3)
  h.assert_eq(#commands "d", 1, "deleted")
  h.assert_eq(marks.placement_count(), 0, "none left")
  finish_test()
end)

h.test("a placement two buffers use stays until both let go", function()
  reset()
  local a = open(WIDE, 40)
  run_until_marks(a)
  local b = open(WIDE, 40)
  run_until_marks(b)
  h.assert_eq(marks.placement_count(), 1, "one placement, shared")
  vim.api.nvim_buf_set_lines(a, 0, 1, false, { "a lets go" })
  vim.treesitter.get_parser(a, "markdown"):parse(true)
  run(a)
  support.sleep(PRUNE_WAIT)
  h.assert_eq({ #commands "d", marks.placement_count() }, { 0, 1 }, "b still uses it")
  vim.api.nvim_buf_set_lines(b, 0, 1, false, { "b lets go" })
  vim.treesitter.get_parser(b, "markdown"):parse(true)
  run(b)
  h.wait_for(function()
    return #commands "d" > 0
  end, PRUNE_WAIT * 3)
  h.assert_eq({ #commands "d", marks.placement_count() }, { 1, 0 }, "now it goes")
  finish_test()
end)

h.test("a prune with nothing to delete sends nothing", function()
  reset()
  local buf = open(WIDE, 40)
  run_until_marks(buf)
  local before = #sent
  for _ = 1, 3 do
    run(buf)
  end
  support.sleep(PRUNE_WAIT)
  h.assert_eq(#sent, before, "the same placement, kept: nothing written")
  finish_test()
end)

-- ============================================================================
-- Colours
-- ============================================================================

h.test(":colorscheme: the highlights are defined again at once, and the buffers drawn again", function()
  reset()
  local buf = open(WIDE, 40)
  local result = run_until_marks(buf)
  local line = result[1].opts.virt_lines[1]
  local group = line[#line][2]
  local id = vim.api.nvim_get_hl(0, { name = group, link = false }).fg
  h.assert_eq(type(id), "number", "the group carries the image id")
  settled()
  vim.cmd "highlight clear"
  h.assert_eq(vim.api.nvim_get_hl(0, { name = group, link = false }), {}, "cleared, as a colorscheme does")
  vim.cmd "doautocmd ColorScheme"
  local hl = vim.api.nvim_get_hl(0, { name = group, link = false })
  h.assert_eq({ hl.fg, hl.underline, hl.nocombine }, { id, true, true }, "defined again, with what carries the ids")
  h.assert_eq(wait_rendered(1), true, "the buffer is drawn again")
  finish_test()
end)

local MERMAID = { "```mermaid", "graph TD; A-->B", "```", "", "![x](small.png)" }

h.test("Mermaid diagrams are made again when the background changes, and only those", function()
  reset()
  local buf = open(MERMAID, 40)
  on_render = run
  local result = run_until_marks(buf, 2)
  h.assert_eq(#result, 2, "the diagram and the image")
  h.assert_eq(#mermaid_runs, 1, "the diagram was made once")
  h.assert_eq(#store.image_ids(), 2, "two images were sent")
  local diagram_key = store.diagram_key("mermaid", "graph TD; A-->B")
  local diagram_id = select(2, store.get(diagram_key)).id
  settled()

  vim.o.background = "light"
  h.assert_eq(wait_rendered(1), true, "the buffer is drawn again")
  h.assert_eq(
    image_deletes(),
    { ("a=d,d=I,i=%d"):format(diagram_id) },
    "the old diagram is deleted from the terminal, nothing else"
  )
  h.wait_for(function()
    return #mermaid_runs == 2
  end, 3000)
  h.assert_eq(#mermaid_runs, 2, "and made again")
  h.assert_eq(
    mermaid_runs[1] ~= mermaid_runs[2],
    true,
    "under the new colours (" .. mermaid_runs[1] .. " then " .. mermaid_runs[2] .. ")"
  )
  h.assert_eq(select(2, store.get(diagram_key)).id ~= diagram_id, true, "with a new image id")
  finish_test()
end)

h.test("colours that did not change leave the diagrams alone", function()
  reset()
  local buf = open(MERMAID, 40)
  on_render = run
  run_until_marks(buf, 2)
  lifecycle.colors_changed()
  lifecycle.colors_changed()
  support.sleep(200)
  h.assert_eq(#mermaid_runs, 1, "not made again")
  h.assert_eq(image_deletes(), {}, "nothing deleted")
  finish_test()
end)

-- ============================================================================
-- Buffers going away
-- ============================================================================

h.test("a wiped buffer is forgotten: no render owed, no placements used", function()
  reset()
  local buf = open(WIDE, 40)
  run_until_marks(buf)
  local forgotten = {}
  local forget = store.forget_buf
  h.stub(store, "forget_buf", function(b)
    forgotten[#forgotten + 1] = b
    return forget(b)
  end)
  vim.api.nvim_buf_delete(buf, { force = true })
  h.assert_eq(vim.tbl_contains(forgotten, buf), true, "the store was told")
  h.assert_eq(lifecycle.buffers(), {}, "not noted any more")
  h.wait_for(function()
    return #commands "d" > 0
  end, PRUNE_WAIT * 3)
  h.assert_eq({ #commands "d", marks.placement_count() }, { 1, 0 }, "its placement was deleted")
  finish_test()
end)

h.test("an unloaded buffer is forgotten too", function()
  reset()
  local buf = open(WIDE, 40)
  run_until_marks(buf)
  vim.cmd("silent! bunload! " .. buf)
  h.assert_eq(lifecycle.buffers(), {}, "not noted")
  finish_test()
end)

h.test("a buffer waiting for an image is not rendered when the image arrives after it is wiped", function()
  reset()
  local release
  h.stub(store, "transmit", function(_, done)
    release = function()
      done(150)
    end
  end)
  local buf = open(WIDE, 40)
  run(buf)
  h.wait_for(function()
    return release ~= nil
  end, 2000)
  vim.api.nvim_buf_delete(buf, { force = true })
  release()
  support.sleep(150)
  h.assert_eq(rendered, {}, "nothing rendered")
  finish_test()
end)

-- ============================================================================
-- Exit
-- ============================================================================

h.test("on exit the images this instance sent are deleted, one command each, in one write", function()
  reset()
  local buf = open(MERMAID, 40)
  run_until_marks(buf, 2)
  local ids = store.image_ids()
  h.assert_eq(#ids, 2, "two images")
  local before = #sent
  vim.api.nvim_exec_autocmds("VimLeavePre", { group = GROUP })
  h.assert_eq(#sent, before + 1, "one write")
  h.assert_eq(
    image_deletes(),
    vim.tbl_map(function(id)
      return ("a=d,d=I,i=%d"):format(id)
    end, ids),
    "d=I for each id, in order"
  )
  h.assert_eq(table.concat(sent):find("d=A", 1, true), nil, "never d=A: other Neovims' images are not ours to delete")
  finish_test()
end)

h.test("on exit with nothing sent nothing is written", function()
  reset()
  vim.api.nvim_exec_autocmds("VimLeavePre", { group = GROUP })
  h.assert_eq(#sent, 0, "silence")
  finish_test()
end)

h.test("what failed has no id to delete", function()
  reset()
  h.stub(store, "produce", function(_, _, done)
    done(nil, "no", true, false)
  end)
  store.get(dir .. "/small.png")
  support.sleep(60)
  h.assert_eq(store.image_ids(), {}, "no ids")
  finish_test()
end)

-- ============================================================================
-- Image ids
-- ============================================================================

h.test("every Neovim takes its image ids from a range of its own", function()
  reset()
  h.unstub()
  local loaded = package.loaded["render-markdown-images.image"]
  package.loaded["render-markdown-images.image"] = nil
  local fresh = require "render-markdown-images.image"
  h.stub(vim.api, "nvim_ui_send", function() end)
  fresh._set_in_tmux(false)
  local first = fresh.transmit_image(h.root .. "/tests/fixtures/test_4x4.png")
  local second = fresh.transmit_image(h.root .. "/tests/fixtures/test_4x4.png")
  package.loaded["render-markdown-images.image"] = loaded
  local base = 100 + (vim.uv.os_getpid() % 4000) * 4000
  h.assert_eq({ first, second }, { base + 1, base + 2 }, "from this process's base")
  h.assert_eq(first >= 101 and second < 2 ^ 24, true, "within the 24 bits a colour holds")
  -- The ranges of two processes: any pid maps to a range of 4000 ids, and neighbours do not touch.
  local function range(pid)
    local low = 100 + (pid % 4000) * 4000
    return low + 1, low + 4000
  end
  local _, last_of_first = range(1)
  local first_of_next = range(2)
  h.assert_eq(last_of_first < first_of_next, true, "consecutive pids: disjoint ranges")
  local _, highest = range(3999)
  h.assert_eq(highest < 2 ^ 24, true, "the highest range still fits in 24 bits")
  finish_test()
end)

h.finish "lifecycle_test"
