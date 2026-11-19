-- Switching images off and on at run time, end to end: render-markdown parses, our handler draws or does not,
-- and the buffers are rendered again when the switch is thrown. Only the terminal is faked.
-- Needs a render-markdown.nvim checkout, see tests/render_markdown_test.lua.
-- Run: nvim --headless -u NONE --noplugin -l tests/toggle_test.lua

package.path = vim.fn.getcwd() .. "/?.lua;" .. package.path
local h = require "tests.harness"
local support = require "tests.support"

local rm_path = h.find_plugin("RENDER_MARKDOWN_PATH", "render-markdown.nvim")
if not rm_path then
  if vim.env.RMI_REQUIRE_RENDER_MARKDOWN == "1" then
    print "toggle_test: FAIL: render-markdown.nvim not found"
    os.exit(1)
  end
  print "toggle_test: skip (render-markdown.nvim not found)"
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
local lifecycle = require "render-markdown-images.lifecycle"
local health = require "render-markdown-images.health"

local ns = vim.api.nvim_create_namespace "render-markdown.nvim"

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
support.make_png(dir .. "/wide.png", 400, 200) -- 40 x 10 cells at 10 x 20 px
support.make_png(dir .. "/small.png", 40, 20)

--- Everything written to the terminal.
local sent = {}

---@param opts? { config?: table }
local function setup(opts)
  opts = opts or {}
  h.unstub()
  store.reset()
  marks.reset()
  lifecycle.reset()
  sent = {}
  rmi.setup(opts.config)
  h.stub(vim.api, "nvim_ui_send", function(data)
    sent[#sent + 1] = data
  end)
  image.reset_cache()
  image._set_in_tmux(false)
  image._reset_image_id()
  image._test_cell_size = { cell_w = 10, cell_h = 20 }
  h.stub(store.limits, "debounce", 10)
  h.stub(store.limits, "retry_delay", 0)
  rm.setup {
    anti_conceal = { enabled = false },
    debounce = 0,
    custom_handlers = rmi.handlers(),
  }
end

local function finish_test()
  h.unstub()
  vim.cmd "silent! only"
  store.reset()
  marks.reset()
  lifecycle.reset()
  image._test_cell_size = nil
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

--- The extmarks of render-markdown that are ours: virtual lines in our highlight groups.
---@param buf integer
---@return integer
local function image_marks(buf)
  local n = 0
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    local lines = m[4].virt_lines
    if lines and lines[1] and lines[1][#lines[1]][2]:find "^RenderMdImg_" then n = n + 1 end
  end
  return n
end

--- Marks that hide the source: a concealed line or a concealed piece of one.
---@param buf integer
---@return integer
local function hiding_marks(buf)
  local n = 0
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    if m[4].conceal_lines ~= nil then n = n + 1 end
  end
  return n
end

---@param fn fun(): boolean
---@param ms? integer
---@return boolean
local function wait(fn, ms)
  return h.wait_for(fn, ms or 5000)
end

local function sleep(ms)
  vim.wait(ms, function()
    return false
  end, 5)
end

--- The Kitty commands with a given action sent so far.
---@param action string
---@return integer
local function commands(action)
  local n = 0
  for seq in table.concat(sent):gmatch "\27_G([^\27]*)\27\\" do
    if seq:find("^a=" .. action .. ",") then n = n + 1 end
  end
  return n
end

-- ============================================================================

h.test("images are shown until they are switched off", function()
  setup()
  h.assert_eq(rmi.is_enabled(), true, "on to begin with")
  local buf = open { "# Title", "", "![wide](wide.png)", "" }
  h.assert_eq(
    wait(function()
      return image_marks(buf) == 1
    end),
    true,
    "drawn"
  )
  finish_test()
end)

h.test("switching off takes the pictures away, and switching on brings them back without fetching again", function()
  setup()
  local lines = { "# Title", "", "![wide](wide.png)", "", "after" }
  local buf = open(lines)
  wait(function()
    return image_marks(buf) == 1
  end)
  local transmitted = commands "t"
  h.assert_eq(transmitted, 1, "sent once")

  h.assert_eq(rmi.toggle(), false, "toggle says: now off")
  h.assert_eq(rmi.is_enabled(), false, "is off")
  h.assert_eq(
    wait(function()
      return image_marks(buf) == 0
    end),
    true,
    "the picture is gone"
  )
  h.assert_eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), lines, "the text is as it was")
  h.assert_eq(
    wait(function()
      return marks.placement_count() == 0
    end),
    true,
    "and its placement is deleted once nothing uses it"
  )
  h.assert_eq(#lifecycle.buffers(), 0, "no buffer is counted as drawn")

  h.assert_eq(rmi.toggle(), true, "toggle says: now on")
  h.assert_eq(
    wait(function()
      return image_marks(buf) == 1
    end),
    true,
    "the picture is back"
  )
  h.assert_eq(commands "t", transmitted, "without sending the image again")
  finish_test()
end)

h.test("while off, nothing is looked for, fetched or converted", function()
  setup()
  rmi.disable()
  local asked = {}
  h.stub(store, "produce", function(key, _, done)
    asked[#asked + 1] = key
    done(nil, "not now", true)
  end)
  local buf = open { "![small](small.png)", "", "```mermaid", "graph TD; A-->B", "```" }
  sleep(200)
  h.assert_eq(asked, {}, "the store was asked for nothing")
  h.assert_eq(store.stats().entries, 0, "and has no entry")
  h.assert_eq(image_marks(buf), 0, "no picture")
  h.assert_eq(commands "t" + commands "p", 0, "nothing sent to the terminal")
  finish_test()
end)

h.test("a buffer opened while off gets its pictures when images are switched on", function()
  setup()
  rmi.disable()
  local buf = open { "![wide](wide.png)" }
  sleep(100)
  h.assert_eq(image_marks(buf), 0, "nothing while off")
  rmi.enable()
  h.assert_eq(
    wait(function()
      return image_marks(buf) == 1
    end),
    true,
    "drawn once on"
  )
  finish_test()
end)

h.test("every buffer follows the switch", function()
  setup()
  local a = open { "![wide](wide.png)" }
  vim.cmd "split" -- a buffer that is not shown is not drawn on: both have a window
  local b = open { "text", "", "![small](small.png)" }
  wait(function()
    return image_marks(a) == 1 and image_marks(b) == 1
  end)
  rmi.disable()
  h.assert_eq(
    wait(function()
      return image_marks(a) == 0 and image_marks(b) == 0
    end),
    true,
    "both are bare"
  )
  rmi.enable()
  h.assert_eq(
    wait(function()
      return image_marks(a) == 1 and image_marks(b) == 1
    end),
    true,
    "both are back"
  )
  finish_test()
end)

h.test("in replace mode the sources come back while off, and are hidden again on", function()
  setup { config = { images = { mode = "replace" } } }
  local buf = open { "# Title", "", "![wide](wide.png)", "", "after" }
  h.assert_eq(
    wait(function()
      return image_marks(buf) == 1 and hiding_marks(buf) >= 1
    end),
    true,
    "the source is hidden and the picture drawn"
  )
  rmi.disable()
  h.assert_eq(
    wait(function()
      return image_marks(buf) == 0 and hiding_marks(buf) == 0
    end),
    true,
    "the source is shown, nothing hides it"
  )
  rmi.enable()
  h.assert_eq(
    wait(function()
      return image_marks(buf) == 1 and hiding_marks(buf) >= 1
    end),
    true,
    "hidden and drawn again"
  )
  finish_test()
end)

h.test("enable when on and disable when off change nothing, and render nothing", function()
  setup()
  local buf = open { "![wide](wide.png)" }
  wait(function()
    return image_marks(buf) == 1
  end)
  sleep(200) -- whatever the first render left to do is done
  local renders = 0
  h.stub(store, "render_buf", function()
    renders = renders + 1
  end)
  rmi.enable()
  sleep(100)
  h.assert_eq(renders, 0, "enable when on: no render")
  rmi.disable()
  sleep(100)
  h.assert_eq(renders, 1, "disable: one render")
  rmi.disable()
  sleep(100)
  h.assert_eq(renders, 1, "disable when off: no render")
  finish_test()
end)

h.test("a buffer that is gone is not rendered when images are switched", function()
  setup()
  local buf = open { "![wide](wide.png)" }
  wait(function()
    return image_marks(buf) == 1
  end)
  vim.api.nvim_buf_delete(buf, { force = true })
  local renders = {}
  h.stub(store, "render_buf", function(b)
    renders[#renders + 1] = b
  end)
  rmi.disable()
  sleep(100)
  h.assert_eq(renders, {}, "nothing to render")
  finish_test()
end)

--- Define the command afresh, and collect what it says.
---@return string[] said
local function with_command()
  vim.g.loaded_render_markdown_images = nil
  pcall(vim.api.nvim_del_user_command, "RenderMarkdownImages")
  vim.cmd.runtime "plugin/render-markdown-images.lua"
  local said = {}
  h.stub(vim, "notify", function(msg, level)
    said[#said + 1] = level == vim.log.levels.ERROR and ("ERROR " .. msg) or msg
  end)
  return said
end

h.test(":RenderMarkdownImages toggle switches, and says so", function()
  setup()
  local said = with_command()
  h.assert_eq(vim.fn.exists ":RenderMarkdownImages", 2, "the command exists")
  vim.cmd "RenderMarkdownImages toggle"
  h.assert_eq(rmi.is_enabled(), false, "off")
  vim.cmd "RenderMarkdownImages toggle"
  h.assert_eq(rmi.is_enabled(), true, "on again")
  h.assert_eq(said, { "render-markdown-images: images hidden", "render-markdown-images: images shown" }, "messages")
  finish_test()
end)

h.test(":RenderMarkdownImages enable and disable say what they did, and are safe to repeat", function()
  setup()
  local said = with_command()
  vim.cmd "RenderMarkdownImages disable"
  vim.cmd "RenderMarkdownImages disable"
  h.assert_eq(rmi.is_enabled(), false, "off")
  vim.cmd "RenderMarkdownImages enable"
  vim.cmd "RenderMarkdownImages enable"
  h.assert_eq(rmi.is_enabled(), true, "on")
  h.assert_eq(#said, 4, "one message each time")
  finish_test()
end)

h.test(":RenderMarkdownImages with no name or a wrong one says how to use it, and changes nothing", function()
  setup()
  local said = with_command()
  vim.cmd "RenderMarkdownImages"
  vim.cmd "RenderMarkdownImages toggel"
  vim.cmd "RenderMarkdownImages toggle now"
  h.assert_eq(rmi.is_enabled(), true, "still on")
  h.assert_eq(#said, 3, "three messages")
  for _, msg in ipairs(said) do
    h.assert_eq(
      msg:find "^ERROR " ~= nil and msg:find("{disable|enable|toggle}", 1, true) ~= nil,
      true,
      "an error with the names: " .. msg
    )
  end
  finish_test()
end)

h.test(":RenderMarkdownImages completes its names, for the first word only", function()
  setup()
  with_command()
  local function complete(line)
    return vim.fn.getcompletion(line, "cmdline")
  end
  h.assert_eq(complete "RenderMarkdownImages ", { "disable", "enable", "toggle" }, "all of them")
  h.assert_eq(complete "RenderMarkdownImages t", { "toggle" }, "by prefix")
  h.assert_eq(complete "RenderMarkdownImages e", { "enable" }, "by prefix")
  h.assert_eq(complete "RenderMarkdownImages toggle ", {}, "none after the name")
  h.assert_eq(complete "RenderMarkdownImages x", {}, "none that do not match")
  finish_test()
end)

h.test(":checkhealth says when images are switched off", function()
  setup()
  local calls = {}
  for _, kind in ipairs { "start", "ok", "warn", "error", "info" } do
    h.stub(vim.health, kind, function(msg)
      calls[#calls + 1] = { kind = kind, msg = msg }
    end)
  end
  h.stub(health, "_tmux", function()
    return nil
  end)
  h.stub(health, "_magick_formats", function()
    return nil
  end)
  h.stub(image, "probe", function()
    return "ok"
  end)
  local function switched_off()
    for _, c in ipairs(calls) do
      if c.kind == "warn" and c.msg:find("switched off", 1, true) then return true end
    end
    return false
  end
  pcall(health.check)
  h.assert_eq(switched_off(), false, "no warning while on")
  rmi.disable()
  calls = {}
  pcall(health.check)
  h.assert_eq(switched_off(), true, "a warning while off")
  finish_test()
end)

h.finish "toggle_test"
