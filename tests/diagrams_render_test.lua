-- Diagrams below their fences, inside the real render-markdown: where the mark must go so that Neovim
-- shows it. Only the renderers and the terminal are faked.
-- Needs a render-markdown.nvim checkout, see tests/render_markdown_test.lua.
-- Run: nvim --headless -u NONE --noplugin -l tests/diagrams_render_test.lua

package.path = vim.fn.getcwd() .. "/?.lua;" .. package.path
local h = require "tests.harness"
local support = require "tests.support"

local rm_path = h.find_plugin("RENDER_MARKDOWN_PATH", "render-markdown.nvim")
if not rm_path then
  if vim.env.RMI_REQUIRE_RENDER_MARKDOWN == "1" then
    print "diagrams_render_test: FAIL: render-markdown.nvim not found"
    os.exit(1)
  end
  print "diagrams_render_test: skip (render-markdown.nvim not found)"
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
local log = require "render-markdown-images.log"

local ns = vim.api.nvim_create_namespace "render-markdown.nvim"

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
local diagram_png = dir .. "/diagram.png"
support.make_png(diagram_png, 400, 200) -- 40 x 10 cells at 10 x 20 px

local renders = { mermaid = 0, plantuml = 0 }

---@param opts? { config?: table, code?: table }
local function setup(opts)
  opts = opts or {}
  h.unstub()
  store.reset()
  marks.reset()
  log.reset()
  renders = { mermaid = 0, plantuml = 0 }
  rmi.setup(opts.config)
  h.stub(vim.api, "nvim_ui_send", function() end)
  image.reset_cache()
  image._set_kitty_supported(true)
  image._set_in_tmux(false)
  image._test_cell_size = { cell_w = 10, cell_h = 20 }
  h.stub(image, "has_mmdc", function()
    return true
  end)
  h.stub(image, "has_plantuml", function()
    return true
  end)
  h.stub(image, "render_mermaid_async", function(_, cb)
    renders.mermaid = renders.mermaid + 1
    cb(diagram_png)
  end)
  h.stub(image, "render_plantuml_async", function(_, cb)
    renders.plantuml = renders.plantuml + 1
    cb(diagram_png)
  end)
  h.stub(store.limits, "debounce", 10)
  h.stub(store.limits, "retry_delay", 0)
  rm.setup {
    anti_conceal = { enabled = false },
    debounce = 0,
    code = opts.code,
    custom_handlers = rmi.handlers(),
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

--- Rows of `virt_lines` marks that carry an image, as `{ row, line count }`.
---@param buf integer
---@return { [1]: integer, [2]: integer }[]
local function image_marks(buf)
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    local lines = m[4].virt_lines
    if lines and lines[1] and lines[1][#lines[1]][2]:find "^RenderMdImg_" then out[#out + 1] = { m[2], #lines } end
  end
  return out
end

--- Rows render-markdown conceals.
---@param buf integer
---@return integer[]
local function concealed_rows(buf)
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    if m[4].conceal_lines then out[#out + 1] = m[2] end
  end
  table.sort(out)
  return out
end

---@param buf integer
---@return { [1]: integer, [2]: integer }[]
local function wait_for_images(buf)
  h.wait_for(function()
    return #image_marks(buf) >= 1
  end, 5000)
  return image_marks(buf)
end

--- Screen rows the current window needs for its buffer: what Neovim will actually show.
---@return integer
local function text_height()
  return vim.api.nvim_win_text_height(0, {}).all
end

local FENCE = { "```mermaid", "graph TD", "  A --> B", "```" }

-- ============================================================================

h.test("by default the closing fence is concealed, and the image is still shown", function()
  setup()
  local buf = open(FENCE)
  local found = wait_for_images(buf)
  h.assert_eq(
    concealed_rows(buf),
    { 3 },
    "render-markdown conceals the closing fence line (the opening one shows the language)"
  )
  h.assert_eq(found, { { 2, 10 } }, "our mark is on the last source line, with 10 rows")
  h.assert_eq(text_height(), #FENCE - 1 + 10, "Neovim shows all of it: 4 lines, one concealed, 10 rows of image")
  finish_test()
end)

h.test("had the mark been on the concealed line, Neovim would have dropped it", function()
  setup()
  local buf = open(FENCE)
  wait_for_images(buf)
  -- The reason for the anchor: the same lines on the concealed row show nothing.
  local probe_ns = vim.api.nvim_create_namespace "rmi-probe"
  vim.api.nvim_buf_set_extmark(buf, probe_ns, 3, 0, {
    virt_lines = { { { "dropped 1" } }, { { "dropped 2" } } },
  })
  h.assert_eq(text_height(), #FENCE - 1 + 10, "two more virtual lines on the concealed row add nothing")
  vim.api.nvim_buf_clear_namespace(buf, probe_ns, 0, -1)
  finish_test()
end)

h.test("border = none: nothing is concealed and the image goes under the closing fence", function()
  setup { code = { border = "none" } }
  local buf = open(FENCE)
  local found = wait_for_images(buf)
  h.assert_eq(concealed_rows(buf), {}, "no concealed lines")
  h.assert_eq(found, { { 3, 10 } }, "the mark is on the closing fence line")
  h.assert_eq(text_height(), #FENCE + 10, "all four lines and the image")
  finish_test()
end)

h.test("a language render-markdown is told not to render keeps its fence, and the image goes under it", function()
  setup { code = { disable = { "mermaid" } } }
  local buf = open(FENCE)
  local found = wait_for_images(buf)
  h.assert_eq(concealed_rows(buf), {}, "render-markdown leaves the block alone")
  h.assert_eq(found, { { 3, 10 } }, "under the closing fence")
  h.assert_eq(text_height(), #FENCE + 10, "and it is shown")
  finish_test()
end)

h.test("a diagram in a list item", function()
  setup()
  local buf = open { "- item", "  ```mermaid", "  graph TD", "  ```", "", "after" }
  local found = wait_for_images(buf)
  h.assert_eq(found, { { 2, 10 } }, "under the last source line")
  local virt
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, { 2, 0 }, { 2, 0 }, { details = true })) do
    if m[4].virt_lines then virt = m[4].virt_lines end
  end
  h.assert_eq(virt[1][1], { "  " }, "indented like the list item's content")
  finish_test()
end)

h.test("two diagrams and an image, each under its own text", function()
  setup()
  support.make_png(dir .. "/small.png", 40, 20)
  local buf = open { "![x](small.png)", "", "```mermaid", "graph", "```", "", "```plantuml", "@startuml", "```" }
  h.wait_for(function()
    return #image_marks(buf) == 3
  end, 5000)
  h.assert_eq(
    vim.tbl_map(function(m)
      return m[1]
    end, image_marks(buf)),
    { 0, 3, 7 },
    "image under row 0, Mermaid under its source on row 3, PlantUML under its source on row 7"
  )
  h.assert_eq({ renders.mermaid, renders.plantuml }, { 1, 1 }, "each rendered once")
  finish_test()
end)

h.test("a re-render does not render the diagram again", function()
  setup()
  local buf = open(FENCE)
  wait_for_images(buf)
  for _ = 1, 3 do
    rm.render { buf = buf, force = true }
    support.sleep(60)
  end
  h.assert_eq(renders.mermaid, 1, "rendered once")
  h.assert_eq(#image_marks(buf), 1, "one mark")
  finish_test()
end)

h.test("diagrams.mermaid = false: the fence stays a code block", function()
  setup { config = { diagrams = { mermaid = false } } }
  local buf = open(FENCE)
  support.sleep(250)
  h.assert_eq(image_marks(buf), {}, "no image")
  h.assert_eq(renders.mermaid, 0, "no rendering")
  h.assert_eq(#concealed_rows(buf), 1, "render-markdown still renders the block")
  finish_test()
end)

h.test("a missing renderer: render-markdown works as before, and the log has one line", function()
  setup()
  h.stub(image, "has_mmdc", function()
    return false
  end)
  local buf = open(FENCE)
  h.wait_for(function()
    return #log.recent() == 1
  end, 3000)
  support.sleep(150)
  h.assert_eq(image_marks(buf), {}, "no image")
  h.assert_eq(#log.recent(), 1, "one log line")
  h.assert_eq(#concealed_rows(buf), 1, "render-markdown still renders the block")
  finish_test()
end)

h.finish "diagrams_render_test"
