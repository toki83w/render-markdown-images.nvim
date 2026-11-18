-- The markdown handler: diagram fences -> store -> marks, without render-markdown itself.
-- The renderers (mmdc, plantuml) are stubbed; nothing is run and nothing is drawn by a terminal.
-- (tests/diagrams_render_test.lua runs the same inside the real render-markdown.)
-- Run: nvim --headless -u NONE --noplugin -l tests/fences_test.lua

package.path = vim.fn.getcwd() .. "/?.lua;" .. package.path
local h = require "tests.harness"
local support = require "tests.support"

vim.opt.rtp:prepend(h.root) -- for the queries
h.isolate_cache()
vim.o.columns = 80
vim.o.lines = 40

local rmi = require "render-markdown-images"
local handlers = require "render-markdown-images.handlers"
local store = require "render-markdown-images.store"
local image = require "render-markdown-images.image"
local marks = require "render-markdown-images.marks"
local log = require "render-markdown-images.log"
local placeholder = require "render-markdown-images.placeholder"

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
local diagram_png = dir .. "/diagram.png"
support.make_png(diagram_png, 400, 200) -- 40 x 10 cells at 10x20 px

--- What the renderers were asked, and what they answer. `false` is a renderer that is not installed.
---@type { mermaid: string[], plantuml: string[], mmdc: boolean, plantuml_tool: boolean, result: string? }
local renderers

local function reset()
  h.unstub()
  store.reset()
  marks.reset()
  log.reset()
  rmi.setup()
  image._set_in_tmux(false)
  image._test_cell_size = { cell_w = 10, cell_h = 20 }
  h.stub(store.limits, "debounce", 10)
  h.stub(store.limits, "retry_delay", 0)
  h.stub(vim.api, "nvim_ui_send", function() end)
  local n = 100
  h.stub(store, "transmit", function(_, done)
    n = n + 1
    done(n)
  end)
  h.stub(store, "render_buf", function() end)
  h.stub(package.loaded, "render-markdown.request.context", nil)
  h.stub(package.loaded, "render-markdown.state", nil)

  renderers = { mermaid = {}, plantuml = {}, mmdc = true, plantuml_tool = true, result = diagram_png }
  h.stub(image, "has_mmdc", function()
    return renderers.mmdc
  end)
  h.stub(image, "has_plantuml", function()
    return renderers.plantuml_tool
  end)
  h.stub(image, "render_mermaid_async", function(source, cb)
    table.insert(renderers.mermaid, source)
    cb(renderers.result)
  end)
  h.stub(image, "render_plantuml_async", function(source, cb)
    table.insert(renderers.plantuml, source)
    cb(renderers.result)
  end)
end

local function finish_test()
  h.unstub()
  store.reset()
  marks.reset()
  log.reset()
  rmi.setup()
  image._test_cell_size = nil
  image.reset_cache()
end

--- Set the plugin's options. Doing so makes the image module decide again whether the terminal can show
--- images, so the stand-in answer is given again.
---@param opts? table
local function configure(opts)
  rmi.setup(opts)
end

--- A markdown buffer shown in the current window.
---@param lines string[]
---@return integer buf
local function open(lines)
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buf, dir .. "/doc-" .. buf .. ".md")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_current_buf(buf)
  vim.bo[buf].filetype = "markdown"
  vim.treesitter.start(buf, "markdown")
  vim.treesitter.get_parser(buf, "markdown"):parse(true)
  return buf
end

--- Run the handler over the markdown tree, as render-markdown does.
---@param buf integer
---@return render.md.Mark[]
local function run(buf)
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

local function settle()
  h.wait_for(function()
    return store.stats().running == 0 and store.stats().queued == 0
  end, 3000)
  support.sleep(30)
end

local MERMAID = { "```mermaid", "graph TD; A-->B", "```" }

-- ============================================================================
-- Marks
-- ============================================================================

h.test("a Mermaid fence: nothing while pending, then one mark under the diagram", function()
  reset()
  local buf = open { "text", "", "```mermaid", "graph TD", "  A --> B", "```", "", "after" }
  h.assert_eq(run(buf), {}, "no marks while the renderer works")
  local result = run_until_marks(buf)
  h.assert_eq(#result, 1, "one mark")
  h.assert_eq(
    { result[1].start_row, result[1].start_col, result[1].conceal },
    { 4, 0, false },
    "under the last line of the source (the closing fence is concealed by default)"
  )
  h.assert_eq(#result[1].opts.virt_lines, 10, "10 rows: 400x200 px at 10x20 px cells")
  h.assert_eq(renderers.mermaid, { "graph TD\n  A --> B" }, "the renderer got the source, once")
  finish_test()
end)

h.test("a PlantUML fence, and the short name puml", function()
  reset()
  local buf = open {
    "```plantuml",
    "@startuml",
    "A -> B",
    "@enduml",
    "```",
    "",
    "```puml",
    "@startuml",
    "C -> D",
    "@enduml",
    "```",
  }
  local result = run_until_marks(buf, 2)
  h.assert_eq(#result, 2, "two marks")
  h.assert_eq(renderers.plantuml, { "@startuml\nA -> B\n@enduml", "@startuml\nC -> D\n@enduml" }, "each got its source")
  h.assert_eq(renderers.mermaid, {}, "no Mermaid")
  finish_test()
end)

h.test("both kinds in one document, each under its own fence", function()
  reset()
  local buf = open { "```mermaid", "graph", "```", "", "```plantuml", "@startuml", "```" }
  local result = run_until_marks(buf, 2)
  h.assert_eq(
    vim.tbl_map(function(m)
      return m.start_row
    end, result),
    { 1, 5 },
    "rows of the last source line of each"
  )
  finish_test()
end)

h.test("the same diagram twice is rendered once and shares a placement", function()
  reset()
  local buf = open { "```mermaid", "graph", "```", "", "```mermaid", "graph", "```" }
  local result = run_until_marks(buf, 2)
  settle()
  h.assert_eq(#result, 2, "drawn twice")
  h.assert_eq(#renderers.mermaid, 1, "rendered once")
  h.assert_eq(marks.placement_count(), 1, "one placement")
  finish_test()
end)

h.test("editing a diagram makes a new one", function()
  reset()
  local buf = open { "```mermaid", "graph TD; A-->B", "```" }
  run_until_marks(buf)
  vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "graph TD; A-->C" })
  vim.treesitter.get_parser(buf, "markdown"):parse(true)
  h.assert_eq(run(buf), {}, "the new source is not ready")
  run_until_marks(buf)
  h.assert_eq(renderers.mermaid, { "graph TD; A-->B", "graph TD; A-->C" }, "each source rendered once")
  finish_test()
end)

h.test("the diagram follows the fence's indent", function()
  reset()
  local buf = open { "- item", "  ```mermaid", "  graph", "  ```" }
  local result = run_until_marks(buf)
  h.assert_eq(result[1].opts.virt_lines[1][1], { "  " }, "two columns, as the list item's content")
  h.assert_eq(renderers.mermaid, { "graph" }, "the renderer got the source without the list's indentation")
  finish_test()
end)

h.test("an unclosed or empty fence is left alone", function()
  reset()
  local buf = open { "```mermaid", "graph", "", "text" }
  h.assert_eq(run(buf), {}, "unclosed")
  buf = open { "```mermaid", "```" }
  h.assert_eq(run(buf), {}, "empty")
  settle()
  h.assert_eq(store.stats().entries, 0, "nothing was asked for")
  finish_test()
end)

h.test("other fences are not diagrams", function()
  reset()
  local buf = open { "```lua", "print(1)", "```", "", "```", "plain", "```" }
  h.assert_eq(run(buf), {}, "no marks")
  h.assert_eq(store.stats().entries, 0, "no entries")
  finish_test()
end)

h.test("images and diagrams in one document are marks of their own", function()
  reset()
  support.make_png(dir .. "/small.png", 40, 20)
  local buf = open { "![x](small.png)", "", "```mermaid", "graph", "```" }
  local both = {}
  h.wait_for(function()
    both = run(buf)
    return #both == 2
  end, 3000)
  h.assert_eq(
    vim.tbl_map(function(m)
      return m.start_row
    end, both),
    { 0, 3 },
    "the image under its line, the diagram under its source"
  )
  finish_test()
end)

-- ============================================================================
-- Where the mark goes: render-markdown's code border
-- ============================================================================

--- Pretend to be render-markdown's state, with this `code` configuration.
---@param code table|false false: state that cannot be read
local function fake_code_config(code)
  h.stub(package.loaded, "render-markdown.state", {
    get = function()
      if not code then error "no state" end
      return { code = code }
    end,
  })
end

--- The row the mark of a ready Mermaid fence `{ "```mermaid", "graph", "```" }` ends up on.
---@param lang? string
---@return integer
local function anchor_row(lang)
  local buf = open { "```" .. (lang or "mermaid"), "graph", "```" }
  local result = run_until_marks(buf)
  return result[1].start_row
end

h.test("border = hide (the default): the last source line, since the fence line is concealed", function()
  reset()
  fake_code_config { enabled = true, border = "hide", disable = {} }
  h.assert_eq(anchor_row(), 1, "row 1")
  finish_test()
end)

h.test("the configuration cannot be read: the default is assumed", function()
  reset()
  fake_code_config(false)
  h.assert_eq(anchor_row(), 1, "row 1")
  finish_test()
end)

h.test("a visible closing fence: the image goes under it", function()
  for _, border in ipairs { "none", "thin", "thick" } do
    reset()
    fake_code_config { enabled = true, border = border, disable = {} }
    h.assert_eq(anchor_row(), 2, "border = " .. border)
    finish_test()
  end
end)

h.test("render-markdown's code blocks switched off: the fence is not concealed", function()
  reset()
  fake_code_config { enabled = false, border = "hide", disable = {} }
  h.assert_eq(anchor_row(), 2, "code.enabled = false")
  finish_test()
end)

h.test("a language render-markdown does not render: its fence is not concealed", function()
  reset()
  fake_code_config { enabled = true, border = "hide", disable = { "Mermaid" } }
  h.assert_eq(anchor_row "Mermaid", 2, "listed in code.disable, spelled as written")
  finish_test()
  reset()
  fake_code_config { enabled = true, border = "hide", disable = { "lua" } }
  h.assert_eq(anchor_row(), 1, "another language disabled changes nothing")
  finish_test()
  reset()
  fake_code_config { enabled = true, border = "hide", disable = true }
  h.assert_eq(anchor_row(), 2, "code.disable = true")
  finish_test()
end)

-- ============================================================================
-- Switches
-- ============================================================================

h.test("diagrams.mermaid = false: no Mermaid work and no marks; PlantUML still works", function()
  reset()
  configure { diagrams = { mermaid = false } }
  local buf = open { "```mermaid", "graph", "```", "", "```plantuml", "@startuml", "```" }
  local result = run_until_marks(buf)
  settle()
  h.assert_eq(#result, 1, "one mark: the PlantUML one")
  h.assert_eq(result[1].start_row, 5, "under the PlantUML source")
  h.assert_eq(renderers.mermaid, {}, "the Mermaid renderer was not asked")
  h.assert_eq(store.stats().entries, 1, "and the store has only the PlantUML diagram")
  finish_test()
end)

h.test("diagrams.plantuml = false likewise", function()
  reset()
  configure { diagrams = { plantuml = false } }
  local buf = open { "```mermaid", "graph", "```", "", "```plantuml", "@startuml", "```" }
  local result = run_until_marks(buf)
  settle()
  h.assert_eq(#result, 1, "one mark: the Mermaid one")
  h.assert_eq(renderers.plantuml, {}, "no PlantUML work")
  finish_test()
end)

h.test("both off: nothing is even looked for", function()
  reset()
  configure { diagrams = { mermaid = false, plantuml = false } }
  local buf = open(MERMAID)
  h.assert_eq(run(buf), {}, "no marks")
  settle()
  h.assert_eq(store.stats().entries, 0, "no entries")
  h.assert_eq(renderers.mermaid, {}, "no work")
  finish_test()
end)

h.test("the switch is read on every render", function()
  reset()
  local buf = open(MERMAID)
  run_until_marks(buf)
  configure { diagrams = { mermaid = false } }
  h.assert_eq(run(buf), {}, "off: the diagram is gone, though the store still has it")
  configure()
  h.assert_eq(#run(buf), 1, "on again: drawn without rendering again")
  h.assert_eq(#renderers.mermaid, 1, "rendered once in all")
  finish_test()
end)

h.test("an invalid root is no marks", function()
  reset()
  h.assert_eq(handlers.new().markdown.parse { buf = 0, root = nil, last = true }, {}, "no root")
  finish_test()
end)

-- ============================================================================
-- Failures are quiet
-- ============================================================================

--- Fail the test if anything is shown to the user.
local function expect_silence()
  local notified = {}
  h.stub(vim, "notify", function(msg)
    notified[#notified + 1] = msg
  end)
  h.stub(vim, "notify_once", function(msg)
    notified[#notified + 1] = msg
  end)
  return notified
end

h.test("no Mermaid renderer: no marks, no error, no message, one line in the log", function()
  reset()
  renderers.mmdc = false
  local notified = expect_silence()
  local buf = open { "```mermaid", "graph A", "```", "", "```mermaid", "graph B", "```" }
  h.assert_eq(pcall(run, buf), true, "no error")
  h.wait_for(function()
    return store.stats().entries == 2 and store.stats().running == 0
  end)
  settle()
  h.assert_eq(run(buf), {}, "no marks")
  h.assert_eq(store.peek(store.diagram_key("mermaid", "graph A")), "failed", "the first is failed")
  h.assert_eq(store.peek(store.diagram_key("mermaid", "graph B")), "failed", "so is the second")
  h.assert_eq(renderers.mermaid, {}, "the renderer was never run")
  h.assert_eq(notified, {}, "the user was told nothing")
  local lines = log.recent()
  h.assert_eq(#lines, 1, "one line in the log for two diagrams")
  h.assert_eq(lines[1]:find("no mermaid renderer", 1, true) ~= nil, true, "saying what is missing")
  h.assert_eq(vim.fn.readfile(log.path())[1], lines[1], "and in the file")
  finish_test()
end)

h.test("no PlantUML renderer: the same, and independent of Mermaid", function()
  reset()
  renderers.plantuml_tool = false
  local notified = expect_silence()
  local buf = open { "```plantuml", "@startuml", "```", "", "```mermaid", "graph", "```" }
  local result = run_until_marks(buf)
  settle()
  h.assert_eq(#result, 1, "the Mermaid diagram is drawn")
  h.assert_eq(store.peek(store.diagram_key("plantuml", "@startuml")), "failed", "the PlantUML one failed")
  h.assert_eq(notified, {}, "silently")
  h.assert_eq(#log.recent(), 1, "one line")
  h.assert_eq(log.recent()[1]:find("no plantuml renderer", 1, true) ~= nil, true, "about PlantUML")
  finish_test()
end)

h.test("a missing tool is not tried again on every render", function()
  reset()
  renderers.mmdc = false
  local buf = open(MERMAID)
  run(buf)
  settle()
  for _ = 1, 5 do
    run(buf)
  end
  settle()
  h.assert_eq(store.stats().entries, 1, "one entry")
  h.assert_eq(#log.recent(), 1, "one log line, however many renders")
  finish_test()
end)

h.test("a renderer that fails is retried, then the diagram is quietly failed and logged", function()
  reset()
  renderers.result = nil -- the tool runs and produces nothing
  local notified = expect_silence()
  local buf = open(MERMAID)
  run(buf)
  h.wait_for(function()
    return store.peek(store.diagram_key("mermaid", "graph TD; A-->B")) == "failed"
  end, 3000)
  h.assert_eq(#renderers.mermaid, 4, "four attempts: the first and three retries")
  h.assert_eq(run(buf), {}, "no marks")
  h.assert_eq(notified, {}, "silently")
  h.assert_eq(#log.recent(), 1, "logged once")
  h.assert_eq(log.recent()[1]:find("mermaid rendering failed", 1, true) ~= nil, true, "with the reason")
  finish_test()
end)

h.test("a failed diagram does not hold back the others", function()
  reset()
  local buf = open { "```mermaid", "graph BAD", "```", "", "```mermaid", "graph GOOD", "```" }
  h.stub(image, "render_mermaid_async", function(source, cb)
    table.insert(renderers.mermaid, source)
    if source:find "BAD" then
      cb(nil)
    else
      cb(diagram_png)
    end
  end)
  local result = run_until_marks(buf)
  settle()
  h.assert_eq(#result, 1, "the good one is drawn")
  h.assert_eq(result[1].start_row, 5, "under its own source")
  finish_test()
end)

-- ============================================================================
-- diagrams.mode = "replace"
-- ============================================================================

--- `diagrams.mode = "replace"`, with render-markdown able to draw a mark's `replace`.
local function replace_mode()
  configure { diagrams = { mode = "replace" } }
  h.stub(package.loaded, "render-markdown.lib.replacements", {})
end

h.test("replace mode: the whole fence is concealed and the diagram is the mark's `replace`", function()
  reset()
  replace_mode()
  local buf = open { "text", "", "```mermaid", "graph TD", "  A --> B", "```", "", "after" }
  h.assert_eq(run(buf), {}, "pending: the source stays")
  local result = run_until_marks(buf)
  h.assert_eq(#result, 1, "one mark")
  h.assert_eq({
    result[1].conceal,
    result[1].start_row,
    result[1].start_col,
    result[1].opts.end_row,
    result[1].opts.end_col,
    result[1].opts.conceal_lines,
  }, { true, 2, 0, 5, 3, "" }, "from the opening fence to the end of the closing fence, hidden by anti-conceal")
  h.assert_eq(#result[1].replace, 10, "the diagram: 10 rows")
  h.assert_eq(result[1].opts.virt_lines, nil, "no virtual lines of its own: render-markdown draws `replace`")
  finish_test()
end)

h.test("replace mode: it does not matter what render-markdown does with the fence lines", function()
  for _, border in ipairs { "hide", "none" } do
    reset()
    replace_mode()
    fake_code_config { enabled = true, border = border, disable = {} }
    local buf = open { "a", "", "```mermaid", "graph", "```", "", "b" }
    local result = run_until_marks(buf)
    h.assert_eq({ result[1].start_row, result[1].opts.end_row }, { 2, 4 }, "rows 2 to 4, border = " .. border)
    finish_test()
  end
end)

h.test("replace mode: a fence in a list item is indented", function()
  reset()
  replace_mode()
  local buf = open { "- item", "  ```mermaid", "  graph", "  ```", "", "after" }
  local result = run_until_marks(buf)
  h.assert_eq(
    { result[1].start_row, result[1].opts.end_row, result[1].opts.end_col },
    { 1, 3, 5 },
    "the three fence rows"
  )
  h.assert_eq(result[1].replace[1][1], { "  " }, "image indented by the item's content column")
  finish_test()
end)

h.test("replace mode: a fence that ends the buffer is concealed here, the diagram goes under the row before", function()
  reset()
  replace_mode()
  local buf = open { "text", "", "```mermaid", "graph", "```" }
  local result = run_until_marks(buf, 2)
  h.assert_eq(#result, 2, "two marks")
  local hiding = vim.tbl_filter(function(m)
    return m.opts.conceal_lines
  end, result)[1]
  local drawing = vim.tbl_filter(function(m)
    return m.opts.virt_lines
  end, result)[1]
  h.assert_eq(hiding.replace, nil, "no `replace`: there is no row below to draw above")
  h.assert_eq({ hiding.start_row, hiding.opts.end_row }, { 2, 4 }, "the fence rows concealed")
  h.assert_eq({ drawing.start_row, drawing.conceal }, { 1, false }, "the diagram below row 1")
  finish_test()
end)

h.test("replace mode: followed by a blank row, not the end of the buffer", function()
  reset()
  replace_mode()
  local buf = open { "text", "", "```mermaid", "graph", "```", "" }
  local result = run_until_marks(buf)
  h.assert_eq(#result, 1, "one mark")
  h.assert_eq(result[1].replace ~= nil, true, "with `replace`")
  finish_test()
end)

h.test("replace mode without render-markdown's `replace`: below the source, which stays", function()
  reset()
  configure { diagrams = { mode = "replace" } }
  local buf = open { "```mermaid", "graph", "```", "", "after" }
  local result = run_until_marks(buf)
  h.assert_eq(result[1].conceal, false, "never hidden")
  h.assert_eq(result[1].opts.conceal_lines, nil, "nothing concealed")
  finish_test()
end)

h.test("replace mode: Mermaid and PlantUML fences, each replaced", function()
  reset()
  replace_mode()
  local buf = open { "```mermaid", "graph", "```", "", "```plantuml", "@startuml", "```", "", "end" }
  local result = run_until_marks(buf, 2)
  h.assert_eq(
    vim.tbl_map(function(m)
      return { m.start_row, m.opts.end_row }
    end, result),
    { { 0, 2 }, { 4, 6 } },
    "rows of each fence"
  )
  finish_test()
end)

h.test("replace mode: a fence whose diagram fails stays as it is", function()
  reset()
  replace_mode()
  renderers.mmdc = false
  local buf = open { "```mermaid", "graph", "```", "", "after" }
  run(buf)
  settle()
  h.assert_eq(run(buf), {}, "no marks, so no concealing")
  finish_test()
end)

h.finish "fences_test"
