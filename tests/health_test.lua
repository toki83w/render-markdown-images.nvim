-- :checkhealth render-markdown-images
-- The probe, tmux, the tools, render-markdown and snacks are stand-ins; what is under test is what the report says.
-- Run: nvim --headless -u NONE --noplugin -l tests/health_test.lua

package.path = vim.fn.getcwd() .. "/?.lua;" .. package.path
local h = require "tests.harness"

vim.opt.rtp:prepend(h.root)
h.isolate_cache()

local rmi = require "render-markdown-images"
local health = require "render-markdown-images.health"
local image = require "render-markdown-images.image"
local handlers = require "render-markdown-images.handlers"
local log = require "render-markdown-images.log"

-- ============================================================================
-- Harness: a fake tmux, a fake probe result, fake tools, and a recording vim.health
-- ============================================================================

---@class Report
---@field calls { kind: string, msg: string, advice: any }[]
---@field tmux_calls string[][]
---@field probes integer how many times the terminal was asked

---@class CheckOpts
---@field tmux? boolean
---@field probe? string what the terminal answered
---@field client_term? string|false
---@field version? string|false
---@field passthrough? string|false
---@field features? string|false
---@field termguicolors? boolean
---@field ambiwidth? string
---@field tools? string[] the executables that exist
---@field formats? string[]|false the formats magick reads (false: it could not be asked)
---@field render_markdown? "missing"|"not_set_up"|"registered"|"no_extends"|"foreign"|"unregistered"
---@field can_replace? boolean
---@field snacks? false|{ enabled?: boolean, doc?: boolean }|"broken"
---@field config? table options for setup()
---@field logged? string[] lines the log holds

--- Run `check()` under the conditions of `opts`, and report what it said.
---@param opts? CheckOpts
---@return Report
local function run_check(opts)
  opts = vim.tbl_extend("keep", opts or {}, {
    tmux = true,
    probe = "ok",
    client_term = "foot",
    version = "tmux 3.7",
    passthrough = "all",
    features = "256,RGB,usstyle,sync",
    termguicolors = true,
    ambiwidth = "single",
    tools = { "curl", "magick", "mmdr", "plantuml" },
    render_markdown = "registered",
    can_replace = true,
    snacks = false,
    config = {},
    logged = {},
  })

  local report = { calls = {}, tmux_calls = {}, probes = 0 }
  h.unstub()
  rmi.setup(opts.config)
  log.reset()
  for _, line in ipairs(opts.logged) do
    log.warn(line)
  end

  for _, kind in ipairs { "start", "ok", "warn", "error", "info" } do
    h.stub(vim.health, kind, function(msg, advice)
      table.insert(report.calls, { kind = kind, msg = msg, advice = advice })
    end)
  end

  h.stub(health, "_tmux", function(args)
    table.insert(report.tmux_calls, args)
    local answer ---@type string|false|nil
    if args[1] == "-V" then
      answer = opts.version
    elseif args[1] == "show" then
      answer = opts.passthrough
    elseif args[1] == "display-message" and args[3] == "#{client_termfeatures}" then
      answer = opts.features
    elseif args[1] == "display-message" and args[3] == "#{client_termname}" then
      answer = opts.client_term
    end
    if answer == false then return nil end -- a query that failed
    return answer
  end)

  h.stub(health, "_magick_formats", function()
    if opts.formats == false then return nil end -- magick could not be asked
    local formats = {}
    for _, name in ipairs(opts.formats or { "JPEG", "WEBP", "BMP", "TIFF", "SVG", "PNG" }) do
      formats[name] = true
    end
    return formats
  end)

  vim.o.termguicolors = opts.termguicolors
  vim.o.ambiwidth = opts.ambiwidth

  image.reset_cache()
  image._set_in_tmux(opts.tmux)
  h.stub(image, "probe", function()
    report.probes = report.probes + 1
    return opts.probe
  end)
  h.stub(image, "has_plantuml", function()
    return vim.tbl_contains(opts.tools, "plantuml")
  end)
  h.stub(vim.fn, "executable", function(name)
    return vim.tbl_contains(opts.tools, name) and 1 or 0
  end)

  -- render-markdown.nvim
  h.stub(package.loaded, "render-markdown", nil)
  h.stub(package.loaded, "render-markdown.state", nil)
  local mode = opts.render_markdown
  if mode ~= "missing" then
    package.loaded["render-markdown"] = {}
    local custom ---@type table?
    if mode == "registered" then
      custom = { markdown = { extends = true, parse = handlers.parse } }
    elseif mode == "no_extends" then
      custom = { markdown = { extends = false, parse = handlers.parse } }
    elseif mode == "foreign" then
      custom = {
        markdown = {
          extends = true,
          parse = function()
            return {}
          end,
        },
      }
    elseif mode == "unregistered" then
      custom = {}
    end
    package.loaded["render-markdown.state"] = { custom_handlers = custom }
  end
  h.stub(handlers, "can_replace", function()
    return opts.can_replace
  end)

  -- snacks.nvim
  h.stub(package.loaded, "snacks", nil)
  if opts.snacks == "broken" then
    package.loaded["snacks"] = setmetatable({}, {
      __index = function()
        error "snacks is not what it was"
      end,
    })
  elseif opts.snacks then
    package.loaded["snacks"] = {
      image = { config = { enabled = opts.snacks.enabled ~= false, doc = { enabled = opts.snacks.doc ~= false } } },
    }
  end

  local ok, err = pcall(health.check)
  local saved_error = err
  h.unstub()
  image.reset_cache()
  vim.o.termguicolors = true
  vim.o.ambiwidth = "single"
  rmi.setup()
  if not ok then error(saved_error, 0) end
  return report
end

---@param report Report
---@param kind string
---@return { msg: string, advice: any }[]
local function of_kind(report, kind)
  return vim.tbl_filter(function(c)
    return c.kind == kind
  end, report.calls)
end

--- The first call of `kind` whose message matches `pattern`, or false.
local function has(report, kind, pattern)
  for _, c in ipairs(of_kind(report, kind)) do
    if c.msg:find(pattern) then return c end
  end
  return false
end

--- Does the advice of a call (a string or a list) mention `text`?
local function advises(call, text)
  local advice = type(call.advice) == "table" and table.concat(call.advice, "\n") or tostring(call.advice or "")
  return advice:find(text, 1, true) ~= nil
end

local function sections(report)
  return vim.tbl_map(function(c)
    return c.msg
  end, of_kind(report, "start"))
end

-- ============================================================================
-- Healthy
-- ============================================================================

h.test("a healthy setup in tmux: no errors, no warnings", function()
  local r = run_check()
  h.assert_eq(#of_kind(r, "error"), 0, "no errors")
  h.assert_eq(#of_kind(r, "warn"), 0, "no warnings")
  h.assert_eq(sections(r), {
    "render-markdown-images: Neovim",
    "render-markdown-images: terminal",
    "render-markdown-images: tmux",
    "render-markdown-images: tools",
    "render-markdown-images: render-markdown.nvim",
    "render-markdown-images: configuration",
  }, "the sections, in order (no snacks section: snacks is not there)")
  h.assert_eq(has(r, "ok", "tmux 3%.7") ~= false, true, "tmux version")
  h.assert_eq(has(r, "ok", "allow%-passthrough is all") ~= false, true, "passthrough")
  h.assert_eq(has(r, "ok", "RGB") ~= false, true, "RGB")
  h.assert_eq(has(r, "ok", "usstyle") ~= false, true, "usstyle")
  h.assert_eq(has(r, "ok", "termguicolors") ~= false, true, "termguicolors")
  h.assert_eq(has(r, "ok", "ambiwidth") ~= false, true, "ambiwidth")
  h.assert_eq(has(r, "ok", "answered the Kitty graphics protocol query") ~= false, true, "the probe's answer")
  h.assert_eq(has(r, "ok", "registered for `markdown`") ~= false, true, "the handler")
end)

h.test("a healthy setup outside tmux: no tmux section, tmux is not asked anything", function()
  local r = run_check { tmux = false }
  h.assert_eq(#of_kind(r, "error") + #of_kind(r, "warn"), 0, "nothing wrong")
  h.assert_eq(has(r, "start", "tmux"), false, "no tmux section")
  h.assert_eq(r.tmux_calls, {}, "tmux was not run")
end)

h.test("passthrough 'on' is as good as 'all'", function()
  local r = run_check { passthrough = "on" }
  h.assert_eq(#of_kind(r, "error"), 0, "no errors")
  h.assert_eq(has(r, "ok", "allow%-passthrough is on") ~= false, true, "reported")
end)

-- ============================================================================
-- The terminal: the only place it is asked
-- ============================================================================

h.test("the terminal is asked once, by the check", function()
  local r = run_check()
  h.assert_eq(r.probes, 1, "one query")
end)

h.test("an answer is ok", function()
  local r = run_check { tmux = false, probe = "ok" }
  h.assert_eq(has(r, "ok", "answered the Kitty graphics protocol query") ~= false, true, "ok")
  h.assert_eq(#of_kind(r, "warn"), 0, "nothing to warn about")
end)

h.test("a device attributes answer first means no protocol, and that nothing depends on it", function()
  local r = run_check { tmux = false, probe = "da1_first" }
  local w = has(r, "warn", "does not implement the protocol")
  h.assert_eq(w ~= false, true, "a warning")
  h.assert_eq(advises(w, "images are drawn whatever it is"), true, "the advice says images are drawn anyway")
  h.assert_eq(#of_kind(r, "error"), 0, "not an error: the plugin does not depend on it")
end)

h.test("no reply outside tmux is a warning that can be ignored", function()
  local r = run_check { tmux = false, probe = "no_reply" }
  local w = has(r, "warn", "did not answer")
  h.assert_eq(w ~= false, true, "a warning")
  h.assert_eq(advises(w, "ignore this"), true, "with the way out")
  h.assert_eq(has(r, "warn", "tmux"), false, "and no tmux advice")
end)

h.test("no reply inside tmux is information, not a warning: it is common and says little", function()
  local r = run_check { tmux = true, probe = "no_reply" }
  h.assert_eq(has(r, "warn", "did not answer"), false, "not a warning")
  local i = has(r, "info", "did not arrive")
  h.assert_eq(i ~= false, true, "information")
  h.assert_eq(i.msg:find("Through tmux that is common", 1, true) ~= nil, true, "says why it is not alarming")
  h.assert_eq(i.msg:find("tmux section below", 1, true) ~= nil, true, "and where to look if images do not show")
  h.assert_eq(#of_kind(r, "warn"), 0, "no warnings at all with a good tmux")
end)

h.test("nothing asked (no UI) is information", function()
  local r = run_check { tmux = false, probe = "not_asked" }
  h.assert_eq(has(r, "info", "no terminal is attached") ~= false, true, "information")
  h.assert_eq(#of_kind(r, "warn"), 0, "no warning")
end)

h.test("'termguicolors' off is an error, in tmux or out of it, with the fix", function()
  for _, tmux in ipairs { true, false } do
    local r = run_check { tmux = tmux, termguicolors = false }
    local e = has(r, "error", "termguicolors")
    h.assert_eq(e ~= false, true, "error, tmux = " .. tostring(tmux))
    h.assert_eq(advises(e, ":set termguicolors"), true, "the fix")
  end
end)

h.test("'ambiwidth' double is an error, in tmux or out of it, with the fix", function()
  for _, tmux in ipairs { true, false } do
    local r = run_check { tmux = tmux, ambiwidth = "double" }
    local e = has(r, "error", "ambiwidth")
    h.assert_eq(e ~= false, true, "error, tmux = " .. tostring(tmux))
    h.assert_eq(advises(e, ":set ambiwidth=single"), true, "the fix")
  end
end)

h.test("no terminal is named, and the environment does not change the report", function()
  local base = run_check { tmux = false }
  local saved = { vim.env.TERM_PROGRAM, vim.env.KITTY_WINDOW_ID, vim.env.WEZTERM_EXECUTABLE }
  vim.env.TERM_PROGRAM, vim.env.KITTY_WINDOW_ID, vim.env.WEZTERM_EXECUTABLE = "WezTerm", "1", "/usr/bin/wezterm"
  local other = run_check { tmux = false }
  vim.env.TERM_PROGRAM, vim.env.KITTY_WINDOW_ID, vim.env.WEZTERM_EXECUTABLE = saved[1], saved[2], saved[3]
  local function strip(report)
    return vim.tbl_filter(function(c)
      return not c.msg:find "$TERM"
    end, report.calls)
  end
  h.assert_eq(strip(other), strip(base), "the same report")
end)

-- ============================================================================
-- tmux
-- ============================================================================

h.test("allow-passthrough off is an error with the fix", function()
  local r = run_check { passthrough = "" }
  local e = has(r, "error", "allow%-passthrough is off")
  h.assert_eq(e ~= false, true, "error")
  h.assert_eq(advises(e, "set -g allow-passthrough on"), true, "the fix")
end)

h.test("an unreadable allow-passthrough is a warning, not an error", function()
  local r = run_check { passthrough = false }
  h.assert_eq(has(r, "warn", "could not read the tmux option") ~= false, true, "warning")
  h.assert_eq(#of_kind(r, "error"), 0, "no error")
end)

h.test("tmux older than 3.3 is an error", function()
  local r = run_check { version = "tmux 3.2a" }
  h.assert_eq(has(r, "error", "3%.2 is too old") ~= false, true, "error")
  h.assert_eq(has(r, "ok", "tmux 3%.3 is ok"), false, "(sanity)")
end)

h.test("tmux 3.3 exactly is fine, and so is a prerelease", function()
  h.assert_eq(#of_kind(run_check { version = "tmux 3.3a" }, "error"), 0, "3.3a")
  h.assert_eq(#of_kind(run_check { version = "tmux next-3.4" }, "error"), 0, "next-3.4")
end)

h.test("an unreadable tmux version is a warning", function()
  local r = run_check { version = false }
  h.assert_eq(has(r, "warn", "could not read the tmux version") ~= false, true, "warning")
  r = run_check { version = "tmux master" }
  h.assert_eq(has(r, "warn", "could not read the tmux version") ~= false, true, "a version without numbers too")
end)

h.test("RGB missing is an error naming the client's terminal", function()
  local r = run_check { features = "256,usstyle", client_term = "foot" }
  local e = has(r, "error", "RGB")
  h.assert_eq(e ~= false, true, "error")
  h.assert_eq(advises(e, "set -as terminal-features ',foot:RGB'"), true, "the fix names the terminal")
end)

h.test("usstyle missing is an error, because the placement id is lost without it", function()
  local r = run_check { features = "256,RGB", client_term = "foot" }
  local e = has(r, "error", "underline")
  h.assert_eq(e ~= false, true, "error")
  h.assert_eq(advises(e, "foot:usstyle"), true, "the fix")
  h.assert_eq(has(r, "error", "RGB"), false, "RGB is not blamed")
end)

h.test("the terminal-features advice falls back to xterm* when tmux cannot say", function()
  local r = run_check { features = "256", client_term = false }
  h.assert_eq(advises(has(r, "error", "RGB"), "',xterm*:RGB'"), true, "RGB")
  h.assert_eq(advises(has(r, "error", "underline"), "',xterm*:usstyle'"), true, "usstyle")
end)

h.test("unreadable terminal features are a warning", function()
  local r = run_check { features = false }
  h.assert_eq(has(r, "warn", "could not read the client's terminal features") ~= false, true, "warning")
end)

h.test("every tmux query failing does not raise", function()
  local r = run_check { version = false, passthrough = false, features = false, client_term = false }
  h.assert_eq(#of_kind(r, "warn") >= 3, true, "warnings, not an exception")
end)

-- ============================================================================
-- Tools
-- ============================================================================

h.test("curl missing: remote images are not downloaded", function()
  local r = run_check { tools = { "magick", "mmdr", "plantuml" } }
  local w = has(r, "warn", "curl not found")
  h.assert_eq(w ~= false, true, "warning")
  h.assert_eq(advises(w, "set_download_fn"), true, "mentions the way around it")
end)

h.test("no magick: JPEG and WebP are not shown, and the warning says which magick", function()
  local r = run_check { tools = { "curl", "mmdr", "plantuml" } }
  local w = has(r, "warn", "magick not found")
  h.assert_eq(w ~= false, true, "warning")
  h.assert_eq(advises(w, "ImageMagick 7"), true, "names the version that has the command")
  r = run_check { tools = { "curl", "magick", "mmdr", "plantuml" } }
  h.assert_eq(has(r, "warn", "magick not found"), false, "no warning when it is there")
end)

h.test("magick that cannot read a format: it is named, with what to do", function()
  local r = run_check { formats = { "JPEG", "BMP", "PNG" } }
  local w = has(r, "warn", "magick cannot read")
  h.assert_eq(w ~= false, true, "warning")
  h.assert_eq(
    w.msg:find("WEBP", 1, true) ~= nil and w.msg:find("TIFF", 1, true) ~= nil and w.msg:find("SVG", 1, true) ~= nil,
    true,
    "names the missing formats"
  )
  h.assert_eq(w.msg:find("JPEG", 1, true) == nil and w.msg:find("BMP", 1, true) == nil, true, "and only those")
  h.assert_eq(advises(w, "magick -list format"), true, "says how to look")
  r = run_check {}
  h.assert_eq(has(r, "warn", "magick cannot read"), false, "no warning when it reads all of them")
  h.assert_eq(has(r, "ok", "magick reads JPEG, WebP, BMP, TIFF and SVG") ~= false, true, "and says so")
  r = run_check { formats = false }
  h.assert_eq(has(r, "warn", "magick cannot read"), false, "magick that cannot be asked is not blamed")
end)

h.test("`magick -list format` is read for the modes that mean readable", function()
  local out = table.concat({
    "   Format  Module    Mode  Description",
    "-------------------------------------------------------------------------------",
    "      BMP* BMP       rw-   Microsoft Windows bitmap image",
    "     JPEG* JPEG      rw-   Joint Photographic Experts Group JFIF format",
    "      SVG  SVG       -w+   Scalable Vector Graphics",
    "     MSVG  SVG       rw+   ImageMagick's own SVG internal renderer",
    "     WEBP* WEBP      rw+   WebP Image Format (libwebp 1.6.0 [0210])",
  }, "\n")
  h.stub(vim, "system", function()
    return {
      wait = function()
        return { code = 0, stdout = out }
      end,
    }
  end)
  local formats = health._magick_formats()
  h.unstub()
  h.assert_eq(formats.BMP and formats.JPEG and formats.WEBP and formats.MSVG, true, "readable ones")
  h.assert_eq(formats.SVG, nil, "SVG that can only be written is not readable")
  h.assert_eq(formats.Format, nil, "the header is not a format")
end)

h.test("Mermaid: the renderer found is named; none found is a warning", function()
  h.assert_eq(
    has(run_check { tools = { "curl", "magick", "mmdc", "plantuml" } }, "ok", "Mermaid diagrams: mmdc") ~= false,
    true,
    "mmdc"
  )
  h.assert_eq(
    has(run_check { tools = { "curl", "magick", "npx", "plantuml" } }, "ok", "Mermaid diagrams: npx") ~= false,
    true,
    "npx"
  )
  h.assert_eq(
    has(run_check { tools = { "curl", "magick", "mmdr", "mmdc", "npx", "plantuml" } }, "ok", "Mermaid diagrams: mmdr")
      ~= false,
    true,
    "mmdr first, as when rendering"
  )
  local r = run_check { tools = { "curl", "magick", "plantuml" } }
  h.assert_eq(has(r, "warn", "no Mermaid renderer found") ~= false, true, "none: warning")
end)

h.test("PlantUML: none is a warning that names the ways out", function()
  local r = run_check { tools = { "curl", "magick", "mmdr" } }
  local w = has(r, "warn", "no PlantUML renderer")
  h.assert_eq(w ~= false, true, "warning")
  h.assert_eq(advises(w, "PLANTUML_JAR") and advises(w, "plantuml_server"), true, "the jar, and a server")
end)

h.test("a kind of diagram that is turned off is not warned about", function()
  local r = run_check { tools = { "curl", "magick" }, config = { diagrams = { mermaid = false, plantuml = false } } }
  h.assert_eq(has(r, "info", "Mermaid diagrams are turned off") ~= false, true, "Mermaid: information")
  h.assert_eq(has(r, "info", "PlantUML diagrams are turned off") ~= false, true, "PlantUML: information")
  h.assert_eq(has(r, "warn", "renderer"), false, "no warning about renderers")
end)

-- ============================================================================
-- render-markdown.nvim
-- ============================================================================

h.test("render-markdown missing is an error", function()
  local r = run_check { render_markdown = "missing" }
  local e = has(r, "error", "render%-markdown.nvim is not installed")
  h.assert_eq(e ~= false, true, "error")
  h.assert_eq(advises(e, "MeanderingProgrammer/render-markdown.nvim"), true, "says where to get it")
end)

h.test("render-markdown not set up yet is a warning", function()
  local r = run_check { render_markdown = "not_set_up" }
  h.assert_eq(has(r, "ok", "is installed") ~= false, true, "installed")
  h.assert_eq(has(r, "warn", "has not been set up yet") ~= false, true, "warning")
end)

h.test("the handler is registered: ok", function()
  local r = run_check { render_markdown = "registered" }
  h.assert_eq(has(r, "ok", "registered for `markdown`, and extends") ~= false, true, "ok")
end)

h.test("a handler without `extends` drops render-markdown's own markdown rendering: warning", function()
  local r = run_check { render_markdown = "no_extends" }
  h.assert_eq(has(r, "warn", "without `extends = true`") ~= false, true, "warning")
end)

h.test("another plugin's handler for markdown: error", function()
  local r = run_check { render_markdown = "foreign" }
  h.assert_eq(has(r, "error", "not this plugin's") ~= false, true, "error")
end)

h.test("not registered at all: error with the line to add", function()
  local r = run_check { render_markdown = "unregistered" }
  local e = has(r, "error", "not registered")
  h.assert_eq(e ~= false, true, "error")
  h.assert_eq(advises(e, "custom_handlers = require('render-markdown-images').handlers()"), true, "the line")
end)

h.test("replace mode that cannot work is a warning, one that can is ok, and below mode says nothing", function()
  local r = run_check { config = { images = { mode = "replace" } }, can_replace = false }
  h.assert_eq(has(r, "warn", "cannot hide the source") ~= false, true, "cannot: warning")
  r = run_check { config = { diagrams = { mode = "replace" } }, can_replace = true }
  h.assert_eq(has(r, "ok", "replace mode is available") ~= false, true, "can: ok")
  r = run_check { can_replace = false }
  h.assert_eq(has(r, "warn", "replace"), false, "below: nothing to say")
end)

-- ============================================================================
-- snacks.nvim
-- ============================================================================

h.test("snacks with its image viewer in documents on: images would be drawn twice", function()
  local r = run_check { snacks = { enabled = true, doc = true } }
  local w = has(r, "warn", "drawn twice")
  h.assert_eq(w ~= false, true, "warning")
  h.assert_eq(advises(w, "doc = { enabled = false }"), true, "the fix")
  h.assert_eq(has(r, "start", "snacks") ~= false, true, "in a section of its own")
end)

h.test("snacks with documents off, or the viewer off, says nothing", function()
  h.assert_eq(
    has(run_check { snacks = { enabled = true, doc = false } }, "start", "snacks"),
    false,
    "doc.enabled = false"
  )
  h.assert_eq(
    has(run_check { snacks = { enabled = false, doc = true } }, "start", "snacks"),
    false,
    "image.enabled = false"
  )
end)

h.test("no snacks says nothing", function()
  local r = run_check { snacks = false }
  h.assert_eq(has(r, "start", "snacks"), false, "no section")
  h.assert_eq(has(r, "warn", "snacks"), false, "no warning")
end)

h.test("a snacks that cannot be read says nothing and breaks nothing", function()
  local r = run_check { snacks = "broken" }
  h.assert_eq(has(r, "start", "snacks"), false, "no section")
  h.assert_eq(#of_kind(r, "error"), 0, "no error")
  h.assert_eq(has(r, "start", "configuration") ~= false, true, "and the sections after it are there")
end)

-- ============================================================================
-- Configuration, cache, log
-- ============================================================================

h.test("the configuration is summarised", function()
  local r = run_check { config = { images = { mode = "replace" }, diagrams = { plantuml = false } } }
  h.assert_eq(
    has(r, "info", "images: replace, diagrams: below %(mermaid on, plantuml off%)") ~= false,
    true,
    "modes and kinds"
  )
  h.assert_eq(has(r, "info", "cache: ") ~= false, true, "the cache directory")
end)

h.test("a PlantUML server is said, with what it means", function()
  local r = run_check { config = { plantuml_server = "https://plantuml.example.test" } }
  local i = has(r, "info", "PlantUML server: https://plantuml.example.test")
  h.assert_eq(i ~= false, true, "named")
  h.assert_eq(i.msg:find("is sent there", 1, true) ~= nil, true, "and that source goes there")
end)

h.test("nothing logged is ok, and says where the log is", function()
  local r = run_check {}
  local ok = has(r, "ok", "nothing went wrong in the background")
  h.assert_eq(ok ~= false, true, "ok")
  h.assert_eq(ok.msg:find(log.path(), 1, true) ~= nil, true, "the path")
end)

h.test("what was logged is a warning with the last lines", function()
  local lines = {}
  for i = 1, 8 do
    lines[i] = "problem number " .. i
  end
  local r = run_check { logged = lines }
  local w = has(r, "warn", "8 things went wrong")
  h.assert_eq(w ~= false, true, "warning with the count")
  h.assert_eq(#w.advice, 5, "the last five lines")
  h.assert_eq(w.advice[5]:find("problem number 8", 1, true) ~= nil, true, "ending with the latest")
  h.assert_eq(w.advice[1]:find("problem number 4", 1, true) ~= nil, true, "starting five back")
  r = run_check { logged = { "one problem" } }
  h.assert_eq(has(r, "warn", "1 thing went wrong") ~= false, true, "singular")
end)

-- ============================================================================
-- Robustness
-- ============================================================================

h.test("a check that fails does not take the others with it", function()
  local r
  local ok = pcall(function()
    r = run_check { tools = {} }
  end)
  h.assert_eq(ok, true, "no error from missing tools")
  -- A tools check that raises: executable() breaks.
  h.unstub()
  local report = { calls = {} }
  for _, kind in ipairs { "start", "ok", "warn", "error", "info" } do
    h.stub(vim.health, kind, function(msg, advice)
      table.insert(report.calls, { kind = kind, msg = msg, advice = advice })
    end)
  end
  h.stub(health, "_tmux", function()
    return nil
  end)
  h.stub(image, "probe", function()
    return "ok"
  end)
  h.stub(vim.fn, "executable", function()
    error "executable is broken"
  end)
  image._set_in_tmux(false)
  local fine = pcall(health.check)
  h.unstub()
  h.assert_eq(fine, true, "check() itself does not raise")
  h.assert_eq(has(report, "error", "the tools check failed") ~= false, true, "the failure is reported")
  h.assert_eq(has(report, "start", "configuration") ~= false, true, "and the sections after it are still reported")
  image.reset_cache()
end)

h.test("every section starts with its own title, none twice", function()
  local r = run_check { snacks = { enabled = true, doc = true } }
  local seen = {}
  for _, title in ipairs(sections(r)) do
    h.assert_eq(seen[title], nil, title .. " once")
    seen[title] = true
  end
  h.assert_eq(#sections(r), 7, "seven sections with snacks warning")
end)

h.test(":checkhealth runs the module", function()
  rmi.setup()
  h.stub(health, "_tmux", function()
    return nil
  end)
  image._set_in_tmux(false)
  h.stub(image, "probe", function()
    return "not_asked"
  end)
  vim.cmd "silent checkhealth render-markdown-images"
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local text = table.concat(lines, "\n")
  h.assert_eq(text:find("render-markdown-images: Neovim", 1, true) ~= nil, true, "the report is in the buffer")
  h.assert_eq(text:find("render-markdown-images: tools", 1, true) ~= nil, true, "all of it")
  h.unstub()
  image.reset_cache()
  vim.cmd "silent! %bwipeout!"
end)

h.finish "health_test"
