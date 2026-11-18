-- Mermaid and PlantUML: tool choice, cache paths, command lines. No real renderer is run.
-- Run: nvim --headless -u NONE --noplugin -l tests/diagrams_test.lua

package.path = vim.fn.getcwd() .. "/?.lua;" .. package.path
local h = require "tests.harness"

local cache = h.isolate_cache()
local image = require "render-markdown-images.image"
local async = require "render-markdown-images.async"
local cfg = require "render-markdown-images.config"

local fixture = h.root .. "/tests/fixtures/test_4x4.png"
local png_bytes = (function()
  local f = assert(io.open(fixture, "rb"))
  local data = f:read "*a"
  f:close()
  return data
end)()

local function set_config(opts)
  cfg.setup(opts)
end

--- Pretend exactly the executables in `present` exist.
---@param present table<string, boolean>
local function with_executables(present)
  h.stub(vim.fn, "executable", function(name)
    return present[name] and 1 or 0
  end)
  image.reset_cache()
end

--- Replace `async.system`; every call is recorded as { cmd, opts }. `on_call(cmd, opts)` may write
--- output files and returns the result table (default: success, no stdout).
---@param on_call? fun(cmd: string[], opts: table): table?
---@return { calls: { cmd: string[], opts: table }[] }
local function stub_system(on_call)
  local rec = { calls = {} }
  h.stub(async, "system", function(cmd, opts)
    table.insert(rec.calls, { cmd = cmd, opts = opts })
    return (on_call and on_call(cmd, opts)) or { code = 0 }
  end)
  return rec
end

---@param cmd string[]
---@param flag string
---@return string?
local function arg_after(cmd, flag)
  for i, v in ipairs(cmd) do
    if v == flag then return cmd[i + 1] end
  end
end

local function write_file(path, data)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local f = assert(io.open(path, "wb"))
  f:write(data)
  f:close()
end

--- Call an async API and wait for its callback. Returns whether it answered, and the answer.
---@param fn fun(cb: fun(...))
---@return boolean answered, any answer
local function await_answer(fn)
  local done, answer = false, nil
  fn(function(v)
    answer, done = v, true
  end)
  h.wait_for(function()
    return done
  end)
  return done, answer
end

local function reset()
  h.unstub()
  set_config {}
  image.reset_cache()
  vim.o.background = "dark"
  vim.api.nvim_set_hl(0, "NormalFloat", {})
  vim.api.nvim_set_hl(0, "Normal", {})
end

-- ============================================================================
-- Mermaid
-- ============================================================================

local MERMAID_DIR = cache .. "/nvim/render-markdown-images/mermaid"
local SOURCE = "graph TD; A-->B"

--- A stub renderer: writes a PNG at `-o`, as every real one does.
local function renders_png(cmd)
  local out = arg_after(cmd, "-o")
  if out then write_file(out, png_bytes) end
  return { code = 0 }
end

h.test("mermaid: mmdc command line and cache path", function()
  reset()
  with_executables { mmdc = true }
  vim.api.nvim_set_hl(0, "NormalFloat", { bg = 0x112233 })
  local seen_input
  local sys = stub_system(function(cmd)
    seen_input = vim.fn.readfile(arg_after(cmd, "-i"))
    return renders_png(cmd)
  end)

  h.assert_eq(image.has_mmdc(), true, "available")
  local done, path = await_answer(function(cb)
    image.render_mermaid_async(SOURCE, cb)
  end)
  h.assert_eq(done, true, "answered")
  h.assert_eq(path:match "^(.*)/%x+%.png$", MERMAID_DIR, "<cache>/render-markdown-images/mermaid/<hash>.png")
  h.assert_eq(#path:match "/(%x+)%.png$", 16, "a 16 digit hash")
  h.assert_eq(#sys.calls, 1, "one process")
  local call = sys.calls[1]
  h.assert_eq(call.cmd[1], "mmdc", "the mermaid CLI")
  h.assert_eq(arg_after(call.cmd, "-i"):match "%.mmd$" ~= nil, true, "input is a .mmd file")
  h.assert_eq(arg_after(call.cmd, "-o"), path, "output is the cache path")
  h.assert_eq(arg_after(call.cmd, "-t"), "dark", "theme follows 'background'")
  h.assert_eq(arg_after(call.cmd, "-b"), "#112233", "background follows NormalFloat")
  h.assert_eq(arg_after(call.cmd, "-s"), "2", "supersampled")
  h.assert_eq(call.opts.timeout, 30000, "30 s timeout")
  h.assert_eq(seen_input, { SOURCE }, "the source was written for the renderer")
  reset()
end)

h.test("mermaid: a second request is served from the cache", function()
  reset()
  with_executables { mmdc = true }
  local sys = stub_system(renders_png)
  local _, first = await_answer(function(cb)
    image.render_mermaid_async(SOURCE, cb)
  end)
  local _, second = await_answer(function(cb)
    image.render_mermaid_async(SOURCE, cb)
  end)
  h.assert_eq(second, first, "same path")
  h.assert_eq(#sys.calls, 1, "rendered once")
  h.assert_eq(image.get_mermaid_cached(SOURCE), first, "get_mermaid_cached sees it")
  h.assert_eq(image.get_mermaid_cached "graph TD; X-->Y", nil, "another source is not cached")
  reset()
end)

h.test("mermaid: source, theme and background each have their own cache entry", function()
  reset()
  with_executables { mmdc = true }
  stub_system(renders_png)
  local function render(src)
    local _, p = await_answer(function(cb)
      image.render_mermaid_async(src, cb)
    end)
    return p
  end
  local dark = render(SOURCE)
  local other = render "graph TD; B-->C"
  vim.o.background = "light"
  local light = render(SOURCE)
  vim.o.background = "dark"
  vim.api.nvim_set_hl(0, "NormalFloat", { bg = 0x445566 })
  local recolored = render(SOURCE)
  local unique = {}
  for _, p in ipairs { dark, other, light, recolored } do
    unique[p] = true
  end
  h.assert_eq(vim.tbl_count(unique), 4, "four different files")
  reset()
end)

h.test("mermaid: light background selects mermaid's default theme", function()
  reset()
  with_executables { mmdc = true }
  vim.o.background = "light"
  local sys = stub_system(renders_png)
  await_answer(function(cb)
    image.render_mermaid_async("graph TD; L1-->L2", cb)
  end)
  h.assert_eq(arg_after(sys.calls[1].cmd, "-t"), "default", "theme")
  -- Switching 'background' re-applies the default colours, so read what is set now.
  local hl = vim.api.nvim_get_hl(0, { name = "NormalFloat", link = false })
  if not hl.bg then hl = vim.api.nvim_get_hl(0, { name = "Normal", link = false }) end
  h.assert_eq(
    arg_after(sys.calls[1].cmd, "-b"),
    hl.bg and string.format("#%06x", hl.bg) or "#ffffff",
    "background taken from NormalFloat, else Normal, else white"
  )
  reset()
end)

h.test("mermaid: mmdr is preferred, rendered at 2x its natural size", function()
  reset()
  with_executables { mmdr = true, mmdc = true, npx = true }
  h.stub(vim, "system", function(cmd)
    return {
      wait = function()
        return { code = 0, stdout = '{"width": 100.4, "height": 50}' }
      end,
    }
  end)
  local sys = stub_system(renders_png)
  local _, path = await_answer(function(cb)
    image.render_mermaid_async("graph TD; M1-->M2", cb)
  end)
  local cmd = sys.calls[1].cmd
  h.assert_eq(cmd[1], "mmdr", "mmdr beats mmdc and npx")
  h.assert_eq(arg_after(cmd, "-e"), "png", "png output")
  h.assert_eq(arg_after(cmd, "-o"), path, "to the cache path")
  h.assert_eq(arg_after(cmd, "-w"), "201", "2 x the natural width, rounded")
  h.assert_eq(arg_after(cmd, "-H"), "100", "2 x the natural height")
  local cfg_path = arg_after(cmd, "-c")
  h.assert_eq(cfg_path:match "%.json$" ~= nil, true, "background goes through a config file")
  h.assert_eq(vim.fn.readfile(cfg_path)[1]:find("#1e1e2e", 1, true) ~= nil, true, "holding the background colour")
  h.assert_eq(arg_after(cmd, "-b"), nil, "mmdr has no -b")
  h.assert_eq(arg_after(cmd, "-s"), nil, "or -s")
  reset()
end)

h.test("mermaid: mmdc beats npx, and npx is the fallback", function()
  reset()
  with_executables { mmdc = true, npx = true }
  local sys = stub_system(renders_png)
  await_answer(function(cb)
    image.render_mermaid_async("graph TD; 1-->2", cb)
  end)
  h.assert_eq(sys.calls[1].cmd[1], "mmdc", "mmdc first")
  with_executables { npx = true }
  await_answer(function(cb)
    image.render_mermaid_async("graph TD; 3-->4", cb)
  end)
  h.assert_eq(
    { unpack(sys.calls[2].cmd, 1, 3) },
    { "npx", "-y", "@mermaid-js/mermaid-cli" },
    "npx runs the CLI package"
  )
  reset()
end)

h.test("mermaid: no renderer means no work and a nil answer", function()
  reset()
  with_executables {}
  local sys = stub_system(renders_png)
  h.assert_eq(image.has_mmdc(), false, "not available")
  local done, path = await_answer(function(cb)
    image.render_mermaid_async("graph TD; Q-->R", cb)
  end)
  h.assert_eq({ done, path }, { true, nil }, "answered nil")
  h.assert_eq(#sys.calls, 0, "nothing spawned")
  reset()
end)

h.test("mermaid: a renderer that produces nothing answers nil", function()
  reset()
  with_executables { mmdc = true }
  stub_system(function()
    return { code = 1 }
  end)
  local done, path = await_answer(function(cb)
    image.render_mermaid_async("graph TD; S-->T", cb)
  end)
  h.assert_eq({ done, path }, { true, nil }, "nil, and no file claimed")
  reset()
end)

-- ============================================================================
-- PlantUML
-- ============================================================================

local PLANTUML_DIR = cache .. "/nvim/render-markdown-images/plantuml"
local UML = "@startuml\nA -> B\n@enduml"

h.test("plantuml: local `plantuml` is piped the source", function()
  reset()
  with_executables { plantuml = true }
  local sys = stub_system(function()
    return { code = 0, stdout = png_bytes }
  end)
  local done, path = await_answer(function(cb)
    image.render_plantuml_async(UML, cb)
  end)
  h.assert_eq(done, true, "answered")
  h.assert_eq(path:match "^(.*)/%x+%.png$", PLANTUML_DIR, "<cache>/render-markdown-images/plantuml/<hash>.png")
  h.assert_eq(sys.calls[1].cmd, { "plantuml", "-tpng", "-pipe" }, "command")
  h.assert_eq(sys.calls[1].opts.stdin, UML, "source on stdin")
  h.assert_eq(sys.calls[1].opts.text, false, "binary output")
  h.assert_eq(sys.calls[1].opts.timeout, 30000, "30 s timeout")
  local f = assert(io.open(path, "rb"))
  h.assert_eq(f:read "*a", png_bytes, "the PNG written to the cache")
  f:close()
  local _, again = await_answer(function(cb)
    image.render_plantuml_async(UML, cb)
  end)
  h.assert_eq(again, path, "second request, same path")
  h.assert_eq(#sys.calls, 1, "served from the cache")
  h.assert_eq(image.get_plantuml_cached(UML), path, "get_plantuml_cached")
  h.assert_eq(image.get_plantuml_cached "@startuml\nC -> D\n@enduml", nil, "other source not cached")
  reset()
end)

h.test("plantuml: java -jar is used only when PLANTUML_JAR names a readable jar", function()
  reset()
  local jar = vim.fn.tempname() .. ".jar"
  write_file(jar, "jar")
  local saved = vim.env.PLANTUML_JAR
  with_executables { java = true }
  vim.env.PLANTUML_JAR = jar
  local sys = stub_system(function()
    return { code = 0, stdout = png_bytes }
  end)
  await_answer(function(cb)
    image.render_plantuml_async("@startuml\nJ -> K\n@enduml", cb)
  end)
  h.assert_eq(sys.calls[1].cmd, { "java", "-jar", jar, "-tpng", "-pipe" }, "java -jar")

  vim.env.PLANTUML_JAR = nil
  with_executables { java = true }
  h.assert_eq(image.has_plantuml(), false, "java alone is not a renderer")
  vim.env.PLANTUML_JAR = vim.fn.tempname() .. "-missing.jar"
  with_executables { java = true }
  h.assert_eq(image.has_plantuml(), false, "an unreadable jar is not one either")
  vim.env.PLANTUML_JAR = saved
  reset()
end)

h.test("plantuml: no renderer and no server means no work", function()
  reset()
  with_executables { curl = true }
  local sys = stub_system()
  local done, path = await_answer(function(cb)
    image.render_plantuml_async("@startuml\nM -> N\n@enduml", cb)
  end)
  h.assert_eq({ done, path }, { true, nil }, "nil answer")
  h.assert_eq(#sys.calls, 0, "and the diagram went nowhere")
  reset()
end)

h.test("plantuml: a named server is reached with curl, hex-encoded", function()
  reset()
  set_config { plantuml_server = "https://plantuml.example.test/plantuml/" }
  with_executables { curl = true }
  local remote_uml = "@startuml\nR -> S\n@enduml"
  local sys = stub_system(function(cmd)
    write_file(arg_after(cmd, "-o"), png_bytes)
    return { code = 0 }
  end)
  local _, path = await_answer(function(cb)
    image.render_plantuml_async(remote_uml, cb)
  end)
  local cmd = sys.calls[1].cmd
  h.assert_eq(cmd[1], "curl", "curl")
  h.assert_eq(
    cmd[#cmd],
    "https://plantuml.example.test/plantuml/png/~h" .. image._plantuml_encode_hex(remote_uml),
    "url"
  )
  h.assert_eq(arg_after(cmd, "-o"), path, "to the cache path")
  h.assert_eq(arg_after(cmd, "--max-time"), "15", "bounded in time")
  h.assert_eq(arg_after(cmd, "--max-filesize"), "20000000", "and in size")
  reset()
end)

h.test("plantuml: a local renderer that fails falls back to the named server", function()
  reset()
  set_config { plantuml_server = "https://plantuml.example.test" }
  with_executables { plantuml = true, curl = true }
  local sys = stub_system(function(cmd)
    if cmd[1] == "curl" then
      write_file(arg_after(cmd, "-o"), png_bytes)
      return { code = 0 }
    end
    return { code = 1, stdout = "" }
  end)
  local _, path = await_answer(function(cb)
    image.render_plantuml_async("@startuml\nP -> Q\n@enduml", cb)
  end)
  h.assert_eq(path ~= nil, true, "answered with a path")
  h.assert_eq({ sys.calls[1].cmd[1], sys.calls[2].cmd[1] }, { "plantuml", "curl" }, "local first, then the server")
  reset()
end)

h.finish "diagrams_test"
