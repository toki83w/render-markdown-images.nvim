-- store: one job per key, bounded concurrency, retries, and re-rendering of waiting buffers.
-- Producing, transmitting and rendering are stubbed unless a test says otherwise.
-- Run: nvim --headless -u NONE --noplugin -l tests/store_test.lua

package.path = vim.fn.getcwd() .. "/?.lua;" .. package.path
local h = require "tests.harness"

h.isolate_cache()
local store = require "render-markdown-images.store"
local image = require "render-markdown-images.image"

local fixture = h.root .. "/tests/fixtures/test_4x4.png" -- 4x4 pixels

--- Fast timings, and nothing left over from the previous test.
local function reset()
  h.unstub()
  store.reset()
  image.reset_cache()
  h.stub(store.limits, "debounce", 20)
  h.stub(store.limits, "retry_delay", 0)
end

local function finish_test()
  h.unstub()
  store.reset()
  image.reset_cache()
end

--- A stand-in for `store.produce`. Every call is recorded; `behave(call)` decides what happens, and may
--- keep `call.done` to answer later. By default it answers at once with the fixture.
---@param behave? fun(call: table)
---@return { calls: table[], max_parallel: integer, parallel: integer }
local function stub_produce(behave)
  local rec = { calls = {}, parallel = 0, max_parallel = 0 }
  h.stub(store, "produce", function(key, spec, done)
    local call = { key = key, spec = spec }
    rec.calls[#rec.calls + 1] = call
    rec.parallel = rec.parallel + 1
    rec.max_parallel = math.max(rec.max_parallel, rec.parallel)
    call.done = function(...)
      rec.parallel = rec.parallel - 1
      done(...)
    end
    if behave then
      behave(call)
    else
      call.done(fixture)
    end
  end)
  return rec
end

--- A stand-in for `store.transmit`: numbered ids, the source size unless `size` says otherwise.
---@param size? { [1]: integer, [2]: integer }
---@return { calls: string[] }
local function stub_transmit(size)
  local rec = { calls = {} }
  h.stub(store, "transmit", function(path, done)
    rec.calls[#rec.calls + 1] = path
    done(100 + #rec.calls, size and size[1], size and size[2])
  end)
  return rec
end

--- A stand-in for `store.render_buf`: the buffers it was asked to render, in order.
---@return integer[]
local function stub_render()
  local rendered = {}
  h.stub(store, "render_buf", function(buf)
    rendered[#rendered + 1] = buf
  end)
  return rendered
end

---@param key string
---@param status string
---@return boolean
local function wait_status(key, status)
  return h.wait_for(function()
    return (store.peek(key)) == status
  end, 3000)
end

local function new_buf()
  return vim.api.nvim_create_buf(false, true)
end

local function sleep(ms)
  vim.wait(ms, function()
    return false
  end, 5)
end

-- ============================================================================
-- get: states
-- ============================================================================

h.test("get starts work without waiting, and ends up ready", function()
  reset()
  local produce = stub_produce()
  local transmit = stub_transmit()
  stub_render()
  local status, entry = store.get(fixture, nil)
  h.assert_eq(status, "working", "answers working at once")
  h.assert_eq(#produce.calls, 0, "and has not started anything yet: that happens off the caller's stack")
  h.assert_eq(store.peek(fixture), "working", "peek agrees")
  h.assert_eq(wait_status(fixture, "ready"), true, "becomes ready")
  status, entry = store.get(fixture, nil)
  h.assert_eq(status, "ready", "ready now")
  h.assert_eq({ entry.id, entry.w, entry.h, entry.path }, { 101, 4, 4, fixture }, "id, size of the source, path")
  h.assert_eq({ #produce.calls, #transmit.calls }, { 1, 1 }, "one of each")
  finish_test()
end)

h.test("peek of an unknown key starts nothing", function()
  reset()
  local produce = stub_produce()
  h.assert_eq({ store.peek "nothing" }, { "missing", nil }, "missing")
  sleep(30)
  h.assert_eq(#produce.calls, 0, "no work")
  h.assert_eq(store.stats().entries, 0, "and no entry")
  finish_test()
end)

h.test("a transmission that resized the image reports the new size", function()
  reset()
  stub_produce()
  stub_transmit { 2000, 1500 }
  store.get(fixture)
  wait_status(fixture, "ready")
  local _, entry = store.get(fixture)
  h.assert_eq({ entry.w, entry.h }, { 2000, 1500 }, "the transmitted size, not the source's")
  finish_test()
end)

h.test("the spec is guessed from the key, and passed on", function()
  reset()
  local produce = stub_produce(function() end) -- never answers
  store.get "https://example.test/a.png"
  store.get "/tmp/some/local.png"
  h.wait_for(function()
    return #produce.calls == 2
  end)
  h.assert_eq(produce.calls[1].spec, { kind = "url" }, "a URL")
  h.assert_eq(produce.calls[2].spec, { kind = "file" }, "a path")
  finish_test()
end)

h.test("diagrams carry their source in the spec", function()
  reset()
  local produce = stub_produce(function() end)
  local key = store.diagram_key("mermaid", "graph TD; A-->B")
  h.assert_eq(key:match "^mermaid:%x+$" ~= nil, true, "mermaid:<hash>")
  h.assert_eq(#key, #"mermaid:" + 16, "a 16 digit hash")
  h.assert_eq(store.diagram_key("mermaid", "graph TD; A-->B"), key, "stable")
  h.assert_eq(store.diagram_key("mermaid", "graph TD; B-->C") ~= key, true, "per source")
  h.assert_eq(store.diagram_key("plantuml", "graph TD; A-->B") ~= key, true, "per kind")
  store.get(key, nil, { kind = "mermaid", source = "graph TD; A-->B" })
  h.wait_for(function()
    return #produce.calls == 1
  end)
  h.assert_eq(produce.calls[1].spec, { kind = "mermaid", source = "graph TD; A-->B" }, "spec as given")
  finish_test()
end)

h.test("a diagram key without its source fails at once, with no work", function()
  reset()
  local produce = stub_produce()
  local status, entry = store.get(store.diagram_key("plantuml", "x"))
  h.assert_eq(status, "failed", "failed")
  h.assert_eq(entry.err, "diagram source is missing", "says why")
  status = store.get(store.diagram_key("mermaid", "y"), nil, { kind = "mermaid", source = "" })
  h.assert_eq(status, "failed", "an empty source too")
  sleep(30)
  h.assert_eq(#produce.calls, 0, "nothing was produced")
  finish_test()
end)

-- ============================================================================
-- One job per key
-- ============================================================================

h.test("the same key twice is one job", function()
  reset()
  local produce = stub_produce()
  local transmit = stub_transmit()
  stub_render()
  store.get(fixture)
  store.get(fixture)
  wait_status(fixture, "ready")
  store.get(fixture)
  sleep(30)
  h.assert_eq(#produce.calls, 1, "produced once")
  h.assert_eq(#transmit.calls, 1, "transmitted once")
  finish_test()
end)

h.test("the same key from two buffers is one job, and both buffers are rendered", function()
  reset()
  local produce = stub_produce(function(call)
    vim.defer_fn(function()
      call.done(fixture)
    end, 10)
  end)
  stub_transmit()
  local rendered = stub_render()
  local a, b = new_buf(), new_buf()
  store.get(fixture, a)
  store.get(fixture, b)
  store.get(fixture, a)
  wait_status(fixture, "ready")
  h.wait_for(function()
    return #rendered >= 2
  end)
  sleep(50)
  h.assert_eq(#produce.calls, 1, "one job")
  table.sort(rendered)
  h.assert_eq(rendered, { a, b }, "each buffer once")
  finish_test()
end)

h.test("a different key is a different job", function()
  reset()
  local produce = stub_produce()
  stub_transmit()
  stub_render()
  store.get(fixture)
  store.get(fixture .. ".other")
  h.wait_for(function()
    return #produce.calls == 2
  end)
  h.assert_eq({ produce.calls[1].key, produce.calls[2].key }, { fixture, fixture .. ".other" }, "two keys, two jobs")
  finish_test()
end)

-- ============================================================================
-- Limit on jobs in flight
-- ============================================================================

h.test("at most four jobs run at once, the rest wait their turn in order", function()
  reset()
  local produce = stub_produce(function() end) -- every job stays open until the test answers it
  stub_transmit()
  stub_render()
  for i = 1, 10 do
    store.get("/img/" .. i .. ".png")
  end
  h.wait_for(function()
    return #produce.calls >= 4
  end)
  sleep(30)
  h.assert_eq(#produce.calls, 4, "four started")
  h.assert_eq(store.stats().running, 4, "four running")
  h.assert_eq(store.stats().queued, 6, "six waiting")

  produce.calls[2].done(fixture)
  h.wait_for(function()
    return #produce.calls == 5
  end)
  sleep(30)
  h.assert_eq(#produce.calls, 5, "an answer frees exactly one place")
  h.assert_eq(produce.calls[5].key, "/img/5.png", "for the next in line")

  for i = 1, 10 do
    h.wait_for(function()
      return produce.calls[i] ~= nil
    end)
    if produce.calls[i].done then pcall(produce.calls[i].done, fixture) end
  end
  h.wait_for(function()
    return store.stats().running == 0 and store.stats().queued == 0
  end)
  h.assert_eq(produce.max_parallel <= 4, true, "never more than four at a time (max " .. produce.max_parallel .. ")")
  h.assert_eq(#produce.calls, 10, "every key was produced, once")
  finish_test()
end)

h.test("the limit is read when jobs start", function()
  reset()
  h.stub(store.limits, "jobs", 1)
  local produce = stub_produce(function() end)
  stub_transmit()
  store.get "/a.png"
  store.get "/b.png"
  sleep(40)
  h.assert_eq(#produce.calls, 1, "one at a time")
  finish_test()
end)

h.test("failed and fatal jobs free their place too", function()
  reset()
  h.stub(store.limits, "jobs", 1)
  local produce = stub_produce(function(call)
    if call.key == "/gone.png" then
      call.done(nil, "file not found", true)
    else
      call.done(fixture)
    end
  end)
  stub_transmit()
  stub_render()
  store.get "/gone.png"
  store.get(fixture)
  h.assert_eq(wait_status(fixture, "ready"), true, "the job behind it still runs")
  h.assert_eq(store.peek "/gone.png", "failed", "the first failed")
  finish_test()
end)

-- ============================================================================
-- Failures and retries
-- ============================================================================

h.test("a failing job is attempted four times: the first and three retries", function()
  reset()
  local n = 0
  local produce = stub_produce(function(call)
    n = n + 1
    call.done(nil, "boom " .. n)
  end)
  stub_transmit()
  local rendered = stub_render()
  local buf = new_buf()
  local status = store.get(fixture, buf)
  h.assert_eq(status, "working", "working to begin with")
  h.assert_eq(wait_status(fixture, "failed"), true, "failed in the end")
  local _, entry = store.get(fixture)
  h.assert_eq(#produce.calls, 4, "four attempts")
  h.assert_eq(entry.attempts, 4, "counted")
  h.assert_eq(entry.err, "boom 4", "the last error is kept")
  sleep(60)
  h.assert_eq(rendered, {}, "a failure draws nothing, so nothing is rendered again")
  store.get(fixture)
  sleep(30)
  h.assert_eq(#produce.calls, 4, "and a failed key is not tried again by asking")
  finish_test()
end)

h.test("a job that fails once and then works is ready", function()
  reset()
  local n = 0
  local produce = stub_produce(function(call)
    n = n + 1
    if n < 3 then return call.done(nil, "flaky") end
    call.done(fixture)
  end)
  stub_transmit()
  local rendered = stub_render()
  local buf = new_buf()
  store.get(fixture, buf)
  h.assert_eq(wait_status(fixture, "ready"), true, "ready after two failures")
  h.assert_eq(#produce.calls, 3, "three attempts")
  h.wait_for(function()
    return #rendered == 1
  end)
  h.assert_eq(rendered, { buf }, "the waiting buffer is rendered once, at the end")
  finish_test()
end)

h.test("a fatal failure is not retried", function()
  reset()
  local produce = stub_produce(function(call)
    call.done(nil, "no such file", true)
  end)
  store.get "/nope.png"
  h.assert_eq(wait_status("/nope.png", "failed"), true, "failed")
  sleep(40)
  h.assert_eq(#produce.calls, 1, "once")
  finish_test()
end)

h.test("a retry waits for retry_delay", function()
  reset()
  h.stub(store.limits, "retry_delay", 120)
  local times = {}
  stub_produce(function(call)
    times[#times + 1] = vim.uv.hrtime() / 1e6
    call.done(nil, "slow to recover")
  end)
  store.get "/a.png"
  h.wait_for(function()
    return #times == 2
  end, 2000)
  h.assert_eq(#times, 2, "a second attempt came")
  h.assert_eq(times[2] - times[1] >= 100, true, "after the delay (" .. math.floor(times[2] - times[1]) .. " ms)")
  finish_test()
end)

h.test("a transmission that fails is retried like any other failure", function()
  reset()
  stub_produce()
  local tries = 0
  h.stub(store, "transmit", function(path, done)
    tries = tries + 1
    done(nil)
  end)
  store.get(fixture)
  h.assert_eq(wait_status(fixture, "failed"), true, "failed")
  h.assert_eq(tries, 4, "four attempts")
  h.assert_eq(select(2, store.get(fixture)).err:find("transmitting failed", 1, true) ~= nil, true, "says what failed")
  finish_test()
end)

h.test("something that is not an image is not transmitted, and not retried", function()
  reset()
  local not_image = vim.fn.tempname() .. ".png"
  vim.fn.writefile({ "this is text" }, not_image)
  local produce = stub_produce(function(call)
    call.done(not_image)
  end)
  local transmit = stub_transmit()
  store.get(not_image)
  h.assert_eq(wait_status(not_image, "failed"), true, "failed")
  h.assert_eq(#produce.calls, 1, "one attempt")
  h.assert_eq(#transmit.calls, 0, "nothing sent to the terminal")
  finish_test()
end)

h.test("an error raised by a step is a failed attempt", function()
  reset()
  local n = 0
  h.stub(store, "produce", function(key, spec, done)
    n = n + 1
    error "kaboom"
  end)
  store.get "/a.png"
  h.assert_eq(wait_status("/a.png", "failed"), true, "failed, not stuck")
  h.assert_eq(n, 4, "after the retries")
  h.assert_eq(select(2, store.get "/a.png").err:find("kaboom", 1, true) ~= nil, true, "with the error")
  h.assert_eq(store.stats().running, 0, "and its place is free")
  finish_test()
end)

h.test("a step that never answers is given up on, and its place freed", function()
  reset()
  h.stub(store.limits, "timeout", 60)
  h.stub(store.limits, "jobs", 1)
  local produce = stub_produce(function(call)
    if call.key == "/hangs.png" then return end -- never answers
    call.done(fixture)
  end)
  stub_transmit()
  stub_render()
  store.get "/hangs.png"
  store.get(fixture)
  h.assert_eq(wait_status(fixture, "ready"), true, "the job behind it ran once the hung one timed out")
  h.assert_eq(wait_status("/hangs.png", "failed"), true, "the hung one failed in the end")
  h.assert_eq(select(2, store.get "/hangs.png").err, "timed out", "as timed out")
  finish_test()
end)

h.test("an answer that comes after the timeout is ignored", function()
  reset()
  h.stub(store.limits, "timeout", 40)
  h.stub(store.limits, "retries", 0)
  local late
  stub_produce(function(call)
    late = call
  end)
  stub_transmit()
  local rendered = stub_render()
  local buf = new_buf()
  store.get(fixture, buf)
  h.assert_eq(wait_status(fixture, "failed"), true, "timed out")
  late.done(fixture)
  sleep(60)
  h.assert_eq(store.peek(fixture), "failed", "still failed")
  h.assert_eq(store.stats().running, 0, "the slot was released once")
  h.assert_eq(rendered, {}, "nothing rendered")
  finish_test()
end)

-- ============================================================================
-- Re-render
-- ============================================================================

h.test("one render per buffer, however many images finish together", function()
  reset()
  stub_produce()
  stub_transmit()
  local rendered = stub_render()
  local a, b = new_buf(), new_buf()
  for i = 1, 3 do
    store.get(fixture .. "#a" .. i, a)
  end
  for i = 1, 2 do
    store.get(fixture .. "#b" .. i, b)
  end
  store.get(fixture .. "#a1", b) -- b also waits for one of a's images
  h.wait_for(function()
    return store.stats().running == 0 and store.stats().queued == 0
  end)
  sleep(100)
  table.sort(rendered)
  h.assert_eq(rendered, { a, b }, "a and b, once each")
  finish_test()
end)

h.test("completions in separate windows of time render separately", function()
  reset()
  local calls = {}
  stub_produce(function(call)
    calls[#calls + 1] = call
  end)
  stub_transmit()
  local rendered = stub_render()
  local buf = new_buf()
  store.get("/first.png", buf)
  store.get("/second.png", buf)
  h.wait_for(function()
    return #calls == 2
  end)
  calls[1].done(fixture)
  sleep(80)
  h.assert_eq(rendered, { buf }, "the first completion is rendered without waiting for the second")
  calls[2].done(fixture)
  sleep(80)
  h.assert_eq(rendered, { buf, buf }, "and the second gets its own")
  finish_test()
end)

h.test("the re-render is held back by `debounce`", function()
  reset()
  h.stub(store.limits, "debounce", 150)
  stub_produce()
  stub_transmit()
  local rendered = stub_render()
  store.get(fixture, new_buf())
  wait_status(fixture, "ready")
  sleep(40)
  h.assert_eq(#rendered, 0, "not yet")
  h.wait_for(function()
    return #rendered == 1
  end, 1000)
  h.assert_eq(#rendered, 1, "then once")
  finish_test()
end)

h.test("a wiped buffer is skipped", function()
  reset()
  local call
  stub_produce(function(c)
    call = c
  end)
  stub_transmit()
  local rendered = stub_render()
  local gone, kept = new_buf(), new_buf()
  store.get(fixture, gone)
  store.get(fixture, kept)
  h.wait_for(function()
    return call ~= nil
  end)
  vim.api.nvim_buf_delete(gone, { force = true })
  call.done(fixture)
  h.wait_for(function()
    return #rendered >= 1
  end)
  sleep(60)
  h.assert_eq(rendered, { kept }, "only the buffer that is still there")
  finish_test()
end)

h.test("a buffer wiped while its render is pending is skipped", function()
  reset()
  h.stub(store.limits, "debounce", 80)
  stub_produce()
  stub_transmit()
  local rendered = stub_render()
  local buf = new_buf()
  store.get(fixture, buf)
  wait_status(fixture, "ready")
  vim.api.nvim_buf_delete(buf, { force = true })
  sleep(150)
  h.assert_eq(rendered, {}, "no render for a buffer that is gone")
  finish_test()
end)

h.test("an unloaded buffer is skipped", function()
  reset()
  stub_produce()
  stub_transmit()
  local rendered = stub_render()
  local buf = new_buf()
  vim.bo[buf].bufhidden = "unload"
  local path = vim.fn.tempname()
  vim.api.nvim_buf_set_name(buf, path)
  store.get(fixture, buf)
  vim.cmd("silent! bunload! " .. buf)
  wait_status(fixture, "ready")
  sleep(80)
  h.assert_eq(rendered, {}, "not loaded, not rendered")
  finish_test()
end)

h.test("forget_buf: a buffer that is going away is no longer owed a render", function()
  reset()
  local call
  stub_produce(function(c)
    call = c
  end)
  stub_transmit()
  local rendered = stub_render()
  local a, b = new_buf(), new_buf()
  store.get(fixture, a)
  store.get(fixture, b)
  h.wait_for(function()
    return call ~= nil
  end)
  store.forget_buf(a)
  call.done(fixture)
  sleep(100)
  h.assert_eq(rendered, { b }, "only b")
  finish_test()
end)

h.test("forget_buf cancels a render that is already pending", function()
  reset()
  h.stub(store.limits, "debounce", 100)
  stub_produce()
  stub_transmit()
  local rendered = stub_render()
  local buf = new_buf()
  store.get(fixture, buf)
  wait_status(fixture, "ready")
  h.assert_eq(store.stats().renders, 1, "one pending")
  store.forget_buf(buf)
  h.assert_eq(store.stats().renders, 0, "cancelled")
  sleep(160)
  h.assert_eq(rendered, {}, "and it never happens")
  finish_test()
end)

h.test("asking for a ready image renders nothing: the caller is already rendering", function()
  reset()
  stub_produce()
  stub_transmit()
  local rendered = stub_render()
  store.get(fixture, new_buf())
  wait_status(fixture, "ready")
  sleep(80)
  local before = #rendered
  local status = store.get(fixture, new_buf())
  sleep(80)
  h.assert_eq(status, "ready", "ready")
  h.assert_eq(#rendered, before, "no further render")
  finish_test()
end)

h.test("a buffer asking after the work started is rendered too", function()
  reset()
  local call
  stub_produce(function(c)
    call = c
  end)
  stub_transmit()
  local rendered = stub_render()
  local early, late = new_buf(), new_buf()
  store.get(fixture, early)
  h.wait_for(function()
    return call ~= nil
  end)
  store.get(fixture, late)
  call.done(fixture)
  h.wait_for(function()
    return #rendered >= 2
  end)
  table.sort(rendered)
  h.assert_eq(rendered, { early, late }, "both")
  finish_test()
end)

h.test("reset forgets entries, and work still running is dropped when it ends", function()
  reset()
  local call
  stub_produce(function(c)
    call = c
  end)
  stub_transmit()
  local rendered = stub_render()
  store.get(fixture, new_buf())
  h.wait_for(function()
    return call ~= nil
  end)
  store.reset()
  h.assert_eq(store.peek(fixture), "missing", "forgotten")
  call.done(fixture)
  sleep(80)
  h.assert_eq(store.peek(fixture), "missing", "the late answer did not bring it back")
  h.assert_eq(rendered, {}, "or render anything")
  h.assert_eq(store.stats().running, 0, "the place was released")
  finish_test()
end)

-- ============================================================================
-- The default steps
-- ============================================================================

--- Replace the image-module functions the default `produce` and `transmit` use; calls are recorded.
---@param answers table<string, any> by function name: the path to answer with, or `false` for failure
---@return table<string, string[]>
local function stub_image(answers)
  local calls = {}
  for name, answer in pairs(answers) do
    calls[name] = {}
    h.stub(image, name, function(arg, cb)
      table.insert(calls[name], arg)
      if name == "has_mmdc" or name == "has_plantuml" then return answer end
      cb(answer or nil)
    end)
  end
  return calls
end

--- The attempt of one key, to the end, with the real `produce`.
---@param key string
---@param spec? render-markdown-images.Spec
---@return string status, render-markdown-images.Entry entry
local function run_default_produce(key, spec)
  store.get(key, nil, spec)
  h.wait_for(function()
    return (store.peek(key)) ~= "working"
  end, 3000)
  return store.get(key)
end

h.test("default produce: a file that is there is used as it is", function()
  reset()
  stub_transmit()
  local status, entry = run_default_produce(fixture)
  h.assert_eq({ status, entry.path }, { "ready", fixture }, "ready, with its own path")
  finish_test()
end)

h.test("default produce: a missing file fails at once", function()
  reset()
  local transmit = stub_transmit()
  local status, entry = run_default_produce "/no/such/file.png"
  h.assert_eq(status, "failed", "failed")
  h.assert_eq(entry.attempts, 1, "without retries: it will not appear by itself")
  h.assert_eq(entry.err, "file not found: /no/such/file.png", "says which")
  h.assert_eq(#transmit.calls, 0, "nothing transmitted")
  finish_test()
end)

h.test("default produce: a URL is downloaded", function()
  reset()
  stub_transmit()
  local calls = stub_image { download_async = fixture }
  local status, entry = run_default_produce "https://example.test/pic.png"
  h.assert_eq(status, "ready", "ready")
  h.assert_eq(calls.download_async, { "https://example.test/pic.png" }, "downloaded once")
  h.assert_eq(entry.path, fixture, "the downloaded file is what was transmitted")
  finish_test()
end)

h.test("default produce: a failed download is retried", function()
  reset()
  stub_transmit()
  local calls = stub_image { download_async = false }
  local status, entry = run_default_produce "https://example.test/pic.png"
  h.assert_eq(status, "failed", "failed")
  h.assert_eq(#calls.download_async, 4, "four attempts")
  h.assert_eq(entry.err, "download failed: https://example.test/pic.png", "says so")
  finish_test()
end)

h.test("default produce: badges and unsupported formats are refused without any work", function()
  reset()
  stub_transmit()
  local calls = stub_image { download_async = fixture }
  local status, entry = run_default_produce "https://img.shields.io/badge/a-b-green.png"
  h.assert_eq({ status, entry.attempts }, { "failed", 1 }, "a badge: failed, once")
  status, entry = run_default_produce "https://example.test/anim.gif"
  h.assert_eq({ status, entry.attempts }, { "failed", 1 }, "a GIF: failed, once")
  status, entry = run_default_produce "/local/clip.mp4"
  h.assert_eq({ status, entry.attempts }, { "failed", 1 }, "a video: failed, once")
  h.assert_eq(#calls.download_async, 0, "nothing was downloaded")
  finish_test()
end)

h.test("default produce: Mermaid goes to the renderer with its source", function()
  reset()
  stub_transmit()
  local calls = stub_image { has_mmdc = true, render_mermaid_async = fixture }
  local key = store.diagram_key("mermaid", "graph TD; A-->B")
  local status = run_default_produce(key, { kind = "mermaid", source = "graph TD; A-->B" })
  h.assert_eq(status, "ready", "ready")
  h.assert_eq(calls.render_mermaid_async, { "graph TD; A-->B" }, "rendered once, from the source")
  finish_test()
end)

h.test("default produce: no Mermaid renderer fails once, quietly", function()
  reset()
  stub_transmit()
  local calls = stub_image { has_mmdc = false, render_mermaid_async = fixture }
  local key = store.diagram_key("mermaid", "graph TD; A-->B")
  local status, entry = run_default_produce(key, { kind = "mermaid", source = "graph TD; A-->B" })
  h.assert_eq({ status, entry.attempts }, { "failed", 1 }, "failed, once")
  h.assert_eq(#calls.render_mermaid_async, 0, "nothing run")
  finish_test()
end)

h.test("default produce: PlantUML likewise", function()
  reset()
  stub_transmit()
  local calls = stub_image { has_plantuml = true, render_plantuml_async = fixture }
  local source = "@startuml\nA -> B\n@enduml"
  local status = run_default_produce(store.diagram_key("plantuml", source), { kind = "plantuml", source = source })
  h.assert_eq(status, "ready", "ready")
  h.assert_eq(calls.render_plantuml_async, { source }, "rendered from the source")

  calls = stub_image { has_plantuml = false, render_plantuml_async = fixture }
  local other = "@startuml\nC -> D\n@enduml"
  local status2, entry =
    run_default_produce(store.diagram_key("plantuml", other), { kind = "plantuml", source = other })
  h.assert_eq({ status2, entry.attempts }, { "failed", 1 }, "no renderer: failed, once")
  h.assert_eq(#calls.render_plantuml_async, 0, "nothing run")
  finish_test()
end)

h.test("an unknown kind fails", function()
  reset()
  local status, entry = run_default_produce("x", { kind = "hologram" })
  h.assert_eq({ status, entry.attempts }, { "failed", 1 }, "failed, once")
  finish_test()
end)

h.test("default transmit: through the image module, in the terminal's own words", function()
  reset()
  local sent = {}
  h.stub(vim.api, "nvim_ui_send", function(data)
    sent[#sent + 1] = data
  end)
  image._set_in_tmux(false)
  image._reset_image_id()
  stub_render()
  local status, entry = run_default_produce(fixture)
  h.assert_eq(status, "ready", "ready")
  h.assert_eq({ entry.id, entry.w, entry.h }, { 101, 4, 4 }, "image id 101, 4x4")
  local out = table.concat(sent)
  h.assert_eq(out:find("\27_Ga=t,f=100,t=t,i=101,q=2;", 1, true) ~= nil, true, "a=t,t=t,i=101 was sent")
  h.assert_eq(select(2, out:gsub("\27_Ga=t", "")), 1, "only one transmission")
  finish_test()
end)

h.test("a converted image reports the converted size", function()
  reset()
  stub_produce()
  h.stub(image, "transmit_image_async", function(path, cb)
    cb(150, 2000, 1000)
  end)
  store.get(fixture)
  wait_status(fixture, "ready")
  local _, entry = store.get(fixture)
  h.assert_eq({ entry.id, entry.w, entry.h }, { 150, 2000, 1000 }, "from the transmission")
  finish_test()
end)

-- ============================================================================
-- Default render
-- ============================================================================

h.test("default render_buf: force-renders through render-markdown", function()
  reset()
  local calls = {}
  h.stub(package.loaded, "render-markdown", {
    render = function(ctx)
      calls[#calls + 1] = ctx
    end,
  })
  store.render_buf(7)
  h.assert_eq(calls, { { buf = 7, force = true } }, "buf and force = true")
  finish_test()
end)

h.test("default render_buf: nothing happens when render-markdown is not installed", function()
  reset()
  h.stub(package.loaded, "render-markdown", nil)
  h.stub(package, "path", "")
  h.stub(package, "searchers", {})
  h.assert_eq(pcall(store.render_buf, 7), true, "no error")
  finish_test()
end)

h.test("default render_buf: an error in render-markdown is a warning, not a crash", function()
  reset()
  h.stub(package.loaded, "render-markdown", {
    render = function()
      error "render exploded"
    end,
  })
  local warnings = {}
  h.stub(vim, "notify", function(msg, level)
    warnings[#warnings + 1] = { msg, level }
  end)
  h.assert_eq(pcall(store.render_buf, 7), true, "no error")
  h.assert_eq(#warnings, 1, "one warning")
  h.assert_eq(warnings[1][2], vim.log.levels.WARN, "at warn level")
  h.assert_eq(warnings[1][1]:find("render exploded", 1, true) ~= nil, true, "with the reason")
  finish_test()
end)

h.test("completion renders through the default render_buf", function()
  reset()
  stub_produce()
  stub_transmit()
  local calls = {}
  h.stub(package.loaded, "render-markdown", {
    render = function(ctx)
      calls[#calls + 1] = ctx
    end,
  })
  local buf = new_buf()
  store.get(fixture, buf)
  h.wait_for(function()
    return #calls == 1
  end)
  h.assert_eq(calls, { { buf = buf, force = true } }, "render-markdown was asked to render the buffer, forced")
  finish_test()
end)

-- ============================================================================
-- Log
-- ============================================================================

local log = require "render-markdown-images.log"

h.test("a failed entry is written to the log once, however many attempts it took", function()
  reset()
  log.reset()
  stub_produce(function(call)
    call.done(nil, "renderer exploded")
  end)
  store.get "/broken.png"
  h.assert_eq(wait_status("/broken.png", "failed"), true, "failed")
  local lines = log.recent()
  h.assert_eq(#lines, 1, "one line for four attempts")
  h.assert_eq(lines[1]:find("file /broken.png: renderer exploded", 1, true) ~= nil, true, "kind, key and reason")
  finish_test()
end)

h.test("different keys with the same cause are each written about", function()
  reset()
  log.reset()
  stub_produce(function(call)
    call.done(nil, "boom", true)
  end)
  store.get "/a.png"
  store.get "/b.png"
  wait_status("/a.png", "failed")
  wait_status("/b.png", "failed")
  h.assert_eq(#log.recent(), 2, "one each")
  finish_test()
end)

h.test("a log_id makes one cause one line", function()
  reset()
  log.reset()
  stub_produce(function(call)
    call.done(nil, "no renderer for " .. call.key, true, "no renderer")
  end)
  store.get "/a.png"
  store.get "/b.png"
  store.get "/c.png"
  wait_status("/a.png", "failed")
  wait_status("/b.png", "failed")
  wait_status("/c.png", "failed")
  h.assert_eq(#log.recent(), 1, "one line for three entries")
  finish_test()
end)

h.test("log_id = false keeps a refusal out of the log", function()
  reset()
  log.reset()
  stub_produce(function(call)
    call.done(nil, "not news", true, false)
  end)
  store.get "/a.png"
  wait_status("/a.png", "failed")
  h.assert_eq(log.recent(), {}, "nothing written")
  h.assert_eq(select(2, store.get "/a.png").err, "not news", "but the entry says why")
  finish_test()
end)

h.test("refusals are not failures: badges and GIFs are not logged", function()
  reset()
  log.reset()
  stub_transmit()
  stub_image { download_async = fixture }
  run_default_produce "https://img.shields.io/badge/a-b-green.png"
  run_default_produce "https://example.test/anim.gif"
  run_default_produce "/local/clip.mp4"
  h.assert_eq(log.recent(), {}, "none of them")
  finish_test()
end)

h.test("real failures are logged: a missing file, a failed download, a missing tool", function()
  reset()
  log.reset()
  stub_transmit()
  run_default_produce "/no/such/file.png"
  stub_image { download_async = false, has_mmdc = false, render_mermaid_async = fixture }
  run_default_produce "https://example.test/pic.png"
  run_default_produce(store.diagram_key("mermaid", "graph A"), { kind = "mermaid", source = "graph A" })
  run_default_produce(store.diagram_key("mermaid", "graph B"), { kind = "mermaid", source = "graph B" })
  local lines = log.recent()
  h.assert_eq(#lines, 3, "three: the tool is missing for both diagrams, which is one cause")
  h.assert_eq(lines[1]:find("file not found", 1, true) ~= nil, true, "the file")
  h.assert_eq(lines[2]:find("download failed", 1, true) ~= nil, true, "the download")
  h.assert_eq(lines[3]:find("no mermaid renderer", 1, true) ~= nil, true, "the tool")
  finish_test()
end)

h.test("a ready entry writes nothing", function()
  reset()
  log.reset()
  stub_produce()
  stub_transmit()
  store.get(fixture)
  wait_status(fixture, "ready")
  h.assert_eq(log.recent(), {}, "nothing")
  finish_test()
end)

h.test("snapshot lists every entry with its state", function()
  reset()
  stub_produce(function(call)
    if call.key == "/bad.png" then
      call.done(nil, "no good", true, false)
    else
      call.done(fixture)
    end
  end)
  stub_transmit()
  stub_render()
  h.assert_eq(store.snapshot(), {}, "empty at first")
  store.get "/bad.png"
  store.get(fixture)
  wait_status("/bad.png", "failed")
  wait_status(fixture, "ready")
  local snap = store.snapshot()
  h.assert_eq(
    vim.tbl_map(function(e)
      return { e.key, e.kind, e.status, e.err, e.id }
    end, snap),
    { { "/bad.png", "file", "failed", "no good", nil }, { fixture, "file", "ready", nil, 101 } },
    "sorted by key, with what went wrong"
  )
  finish_test()
end)

-- ============================================================================
-- Failing for good is not for ever
-- ============================================================================

h.test("a failed entry is tried again when it is asked for after retry_failed_after", function()
  reset()
  h.stub(store.limits, "retry_failed_after", 150)
  local fail = true
  local produce = stub_produce(function(call)
    if fail then return call.done(nil, "network down") end
    call.done(fixture)
  end)
  stub_transmit()
  stub_render()
  store.get(fixture, new_buf())
  h.assert_eq(wait_status(fixture, "failed"), true, "failed")
  h.assert_eq(#produce.calls, 4, "after four attempts")

  store.get(fixture)
  sleep(40)
  h.assert_eq(#produce.calls, 4, "asked again at once: not tried again")
  h.assert_eq(store.peek(fixture), "failed", "still failed")

  fail = false
  sleep(150)
  local status = store.get(fixture)
  h.assert_eq(status, "working", "asked again later: working")
  h.assert_eq(wait_status(fixture, "ready"), true, "and ready now that it works")
  h.assert_eq(select(2, store.get(fixture)).attempts, 1, "with the attempts counted afresh")
  finish_test()
end)

h.test("a retried entry that fails again waits again", function()
  reset()
  h.stub(store.limits, "retry_failed_after", 100)
  local produce = stub_produce(function(call)
    call.done(nil, "still down", true)
  end)
  store.get "/a.png"
  wait_status("/a.png", "failed")
  sleep(120)
  store.get "/a.png"
  wait_status("/a.png", "failed")
  h.assert_eq(#produce.calls, 2, "one more attempt")
  store.get "/a.png"
  sleep(30)
  h.assert_eq(#produce.calls, 2, "and no more until the time has passed again")
  finish_test()
end)

h.test("a retry that fails again is not written to the log again", function()
  reset()
  log.reset()
  h.stub(store.limits, "retry_failed_after", 50)
  stub_produce(function(call)
    call.done(nil, "still down", true)
  end)
  store.get "/a.png"
  wait_status("/a.png", "failed")
  sleep(70)
  store.get "/a.png"
  wait_status("/a.png", "failed")
  h.assert_eq(#log.recent(), 1, "one line")
  finish_test()
end)

h.test("an entry whose spec is wrong stays failed whatever time passes", function()
  reset()
  h.stub(store.limits, "retry_failed_after", 0)
  local produce = stub_produce()
  local key = store.diagram_key("mermaid", "x")
  store.get(key)
  sleep(20)
  store.get(key)
  sleep(20)
  h.assert_eq({ store.peek(key), #produce.calls }, { "failed", 0 }, "nothing to retry")
  finish_test()
end)

h.test("a vault name is looked up in the vault by the store, not by the caller", function()
  reset()
  local looked_up = {}
  local obsidian = require "render-markdown-images.obsidian"
  h.stub(obsidian, "resolve", function(name, dir)
    looked_up[#looked_up + 1] = { name, dir }
    if name == "found.png" then return fixture end
  end)
  stub_transmit()
  stub_render()
  store.get("vault:/v:found.png", nil, { kind = "vault", name = "found.png", dir = "/v/notes" })
  store.get("vault:/v:lost.png", nil, { kind = "vault", name = "lost.png", dir = "/v/notes" })
  wait_status("vault:/v:found.png", "ready")
  wait_status("vault:/v:lost.png", "failed")
  h.assert_eq(
    looked_up,
    { { "found.png", "/v/notes" }, { "lost.png", "/v/notes" } },
    "each once, with the note's directory"
  )
  h.assert_eq(select(2, store.get "vault:/v:found.png").path, fixture, "the file it found is what was transmitted")
  h.assert_eq(
    select(2, store.get "vault:/v:lost.png").err,
    "not in the Obsidian vault: lost.png",
    "and what it did not find says so"
  )
  h.assert_eq(select(2, store.get "vault:/v:lost.png").attempts, 1, "not found is not retried at once")
  finish_test()
end)

h.test("a vault key without its spec fails at once", function()
  reset()
  local status, entry = store.get "vault:/v:x.png"
  h.assert_eq({ status, entry.err }, { "failed", "vault name or directory is missing" }, "failed")
  finish_test()
end)

h.finish "store_test"
