--- One entry per thing to draw, shared by every buffer that shows it.
---
--- Rendering an image takes work that cannot happen while render-markdown parses: a download,
--- a Mermaid or PlantUML run, a conversion, a transmission to the terminal. `get` is what a
--- handler calls during a parse. It never waits: the first call for a key starts the work and
--- answers "working", later calls join it, and once the work is done the buffers that asked
--- are rendered again, which is when `get` answers "ready".
---
---     missing --get--> working --> ready { id, w, h }
---                         |  ^
---                         |  +-- retried, up to `limits.retries` times
---                         +----> failed
---
--- Entries are keyed by what they show: the resolved path of a file, a URL, or
--- `mermaid:<hash>` / `plantuml:<hash>` (see `diagram_key`). An entry is never started twice, at
--- most `limits.jobs` entries are worked on at once, and the re-render a completion asks for is
--- coalesced per buffer.

---@alias render-markdown-images.Status "working"|"ready"|"failed"

---@class render-markdown-images.Spec
---@field kind "file"|"url"|"vault"|"mermaid"|"plantuml"
---@field source? string the diagram text, for `mermaid` and `plantuml`
---@field name? string what an Obsidian vault is asked for, for `vault`: a file name or a path in the vault
---@field dir? string the directory of the note that asks, for `vault`: it says which vault

---@class render-markdown-images.Entry
---@field key string
---@field spec render-markdown-images.Spec
---@field status render-markdown-images.Status
---@field attempts integer attempts started so far
---@field bufs table<integer, true> buffers to render again when the work is done
---@field id? integer Kitty image id, once ready
---@field w? integer pixel width of the transmitted image, once ready
---@field h? integer pixel height of the transmitted image, once ready
---@field path? string the PNG or other file that was transmitted, once ready
---@field err? string why the last attempt failed
---@field failed_at? number when it failed for good, in ms (`vim.uv.hrtime()` / 1e6)
---@field invalid? boolean it was asked for without what it needs, and is not tried again for that reason

---@class render-markdown-images.Store
local M = {}

local uv = vim.uv or vim.loop
local image = require "render-markdown-images.image"
local log = require "render-markdown-images.log"

--- Tunables. Fields may be changed at run time; tests do.
M.limits = {
  jobs = 4, -- entries worked on at once
  retries = 3, -- further attempts after the first failure of an entry
  debounce = 50, -- ms a buffer's re-render is held back, so completions arriving together share it
  retry_delay = 500, -- ms before a failed attempt is tried again
  timeout = 60000, -- ms before an attempt that never answered is given up on
  -- ms after which a failed entry is tried again when it is asked for. A download fails because the network
  -- was down, a vault image because it was not there yet, a file because it was being written: none of that
  -- is for good. Asking is what retries, so nothing runs in the background and a document nobody looks at costs
  -- nothing.
  retry_failed_after = 30000,
}

---@type table<string, render-markdown-images.Entry>
local entries = {}
---@type string[]
local queue = {}
local running = 0
--- Bumped by `reset`. A job that started before it no longer counts as running and its answer is dropped.
local generation = 0
local pump_scheduled = false
---@type table<integer, uv.uv_timer_t>
local renders = {}

-- ============================================================================
-- Steps of the pipeline. `M.produce` and `M.transmit` are looked up on every use so that tests
-- can stand in for them.
-- ============================================================================

--- Make sure there is a local image file for `spec`.
---
--- `done(path)` on success, `done(nil, err, fatal, log_id)` otherwise. `fatal` means that trying again
--- cannot help. `log_id` names the cause for the log, which writes a cause once; without it the cause
--- is the key, so that every image that fails is written about, but only once. `false` keeps it out of
--- the log: the failure is not news.
---@param key string
---@param spec render-markdown-images.Spec
---@param done fun(path?: string, err?: string, fatal?: boolean, log_id?: string|false)
function M.produce(key, spec, done)
  local kind = spec.kind
  if kind == "file" then
    if vim.fn.filereadable(key) == 1 then return done(key) end
    return done(nil, "file not found: " .. key, true)
  elseif kind == "url" then
    image.download_async(key, function(path)
      if path then return done(path) end
      done(nil, "download failed: " .. key)
    end)
  elseif kind == "vault" then
    -- Looked for here, not while a document is rendered: a vault can be big and the search is a walk of it.
    local path = require("render-markdown-images.obsidian").resolve(spec.name, spec.dir)
    if path then return done(path) end
    return done(nil, ("not in the Obsidian vault: %s"):format(spec.name), true)
  elseif kind == "mermaid" then
    if not image.has_mmdc() then
      return done(nil, "no mermaid renderer (mmdr, mmdc or npx) found", true, "no mermaid renderer")
    end
    image.render_mermaid_async(spec.source, function(path)
      if path then return done(path) end
      done(nil, "mermaid rendering failed")
    end)
  elseif kind == "plantuml" then
    if not image.has_plantuml() then
      return done(
        nil,
        "no plantuml renderer (plantuml, java with $PLANTUML_JAR, or a server) found",
        true,
        "no plantuml renderer"
      )
    end
    image.render_plantuml_async(spec.source, function(path)
      if path then return done(path) end
      done(nil, "plantuml rendering failed")
    end)
  else
    done(nil, "unknown kind: " .. tostring(kind), true)
  end
end

--- Convert `path` to PNG if needed and hand it to the terminal.
--- `done(id, w, h)`; `id` is nil when it failed, `w` and `h` are set when conversion changed the size.
---@param path string
---@param done fun(id?: integer, w?: integer, h?: integer)
function M.transmit(path, done)
  image.transmit_image_async(path, done)
end

--- Render a buffer again. render-markdown re-parses it, which runs the handlers, which `get` the entries.
---@param buf integer
function M.render_buf(buf)
  local loaded, render_markdown = pcall(require, "render-markdown")
  if not loaded then return end
  local ok, err = pcall(render_markdown.render, { buf = buf, force = true })
  if not ok then vim.notify("render-markdown-images: re-render failed: " .. tostring(err), vim.log.levels.WARN) end
end

-- ============================================================================
-- Re-rendering
-- ============================================================================

--- Ask for `buf` to be rendered again, shortly. Asks made while one is pending join it.
---@param buf integer
function M.request_render(buf)
  if renders[buf] then return end
  renders[buf] = vim.defer_fn(function()
    renders[buf] = nil
    if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf) then M.render_buf(buf) end
  end, M.limits.debounce)
end

---@param timer uv.uv_timer_t
local function stop_timer(timer)
  if not timer:is_closing() then
    timer:stop()
    timer:close()
  end
end

-- ============================================================================
-- Jobs
-- ============================================================================

--- Run `fn` soon, on the main loop.
---@param ms integer
---@param fn fun()
local function after(ms, fn)
  if ms > 0 then
    vim.defer_fn(fn, ms)
  else
    vim.schedule(fn)
  end
end

local pump

local function schedule_pump()
  if pump_scheduled then return end
  pump_scheduled = true
  vim.schedule(function()
    pump_scheduled = false
    pump()
  end)
end

---@param entry render-markdown-images.Entry
---@param ok boolean
---@param result table|string `{ id, w, h, path }` on success, the error otherwise
---@param fatal? boolean
---@param log_id? string|false
local function attempt_done(entry, ok, result, fatal, log_id)
  if entries[entry.key] ~= entry then return end -- the store was reset meanwhile
  if ok then
    ---@cast result table
    entry.status, entry.err = "ready", nil
    entry.id, entry.w, entry.h, entry.path = result.id, result.w, result.h, result.path
    local bufs = entry.bufs
    entry.bufs = {}
    for buf in pairs(bufs) do
      M.request_render(buf)
    end
  elseif fatal or entry.attempts > M.limits.retries then
    entry.status, entry.err = "failed", tostring(result)
    entry.failed_at = (vim.uv or vim.loop).hrtime() / 1e6
    entry.bufs = {} -- a failed entry draws nothing, so there is nothing to render again
    -- Quietly: no message, just a line in the log, and one per cause.
    if log_id ~= false then
      log.warn(("%s %s: %s"):format(entry.spec.kind, entry.key, entry.err), log_id or entry.key)
    end
  else
    entry.err = tostring(result)
    after(M.limits.retry_delay, function()
      if entries[entry.key] ~= entry then return end
      queue[#queue + 1] = entry.key
      schedule_pump()
    end)
  end
end

--- The work for one entry. Answers through `settle(true, { id, w, h, path })` or
--- `settle(false, err, fatal, log_id)`.
---@param entry render-markdown-images.Entry
---@param settle fun(ok: boolean, result: table|string, fatal?: boolean, log_id?: string|false)
local function pipeline(entry, settle)
  local key, kind = entry.key, entry.spec.kind
  -- These are refusals, not failures: nothing went wrong, so nothing is logged.
  if (kind == "file" or kind == "url") and image.is_unsupported_format(key) then
    return settle(false, "unsupported format: " .. key, true, false)
  end
  if kind == "url" and image.is_badge_url(key) then return settle(false, "badge, not shown: " .. key, true, false) end

  M.produce(key, entry.spec, function(path, err, fatal, log_id)
    if not path then return settle(false, err or "no image produced", fatal, log_id) end
    local w, h = image.image_dimensions(path)
    -- A BMP, a TIFF or an SVG has no header read here: its size is that of the PNG it is converted to.
    local format = image.detect_format(path)
    if not w and (not format or format == "png") then
      return settle(false, "not a readable PNG, JPEG, WebP, BMP, TIFF or SVG image: " .. path, true)
    end
    if format == "svg" then
      local why = image.svg_refusal(path)
      if why then return settle(false, "SVG not shown, it " .. why .. ": " .. path, true) end
    end
    M.transmit(path, function(id, tx_w, tx_h)
      if not id then return settle(false, "transmitting failed: " .. path) end
      local width, height = tx_w or w, tx_h or h
      if not width then return settle(false, "no size after converting: " .. path) end
      settle(true, { id = id, w = width, h = height, path = path })
    end)
  end)
end

---@param entry render-markdown-images.Entry
local function start(entry)
  running = running + 1
  entry.attempts = entry.attempts + 1

  local started_in = generation
  local settled = false
  local watchdog = assert(uv.new_timer())

  local function finish(ok, result, fatal, log_id)
    if settled then return end -- a late answer, after the timeout
    settled = true
    stop_timer(watchdog)
    if started_in ~= generation then return end -- the store was reset; this job is no longer counted
    running = running - 1
    attempt_done(entry, ok, result, fatal, log_id)
    schedule_pump()
  end

  --- Answers may come from a fast event; the work after them is not allowed there.
  local function settle(...)
    if vim.in_fast_event() then
      local args = vim.F.pack_len(...)
      vim.schedule(function()
        finish(unpack(args, 1, args.n))
      end)
    else
      finish(...)
    end
  end

  watchdog:start(
    M.limits.timeout,
    0,
    vim.schedule_wrap(function()
      finish(false, "timed out")
    end)
  )

  local ok, err = pcall(pipeline, entry, settle)
  if not ok then settle(false, tostring(err)) end
end

pump = function()
  while running < M.limits.jobs and #queue > 0 do
    local entry = entries[table.remove(queue, 1)]
    if entry and entry.status == "working" then start(entry) end
  end
end

-- ============================================================================
-- Public API
-- ============================================================================

--- The key of a diagram: its kind and a hash of its source.
---@param kind "mermaid"|"plantuml"
---@param source string
---@return string
function M.diagram_key(kind, source)
  return kind .. ":" .. vim.fn.sha256(source):sub(1, 16)
end

--- What `key` is, when the caller did not say.
---@param key string
---@return render-markdown-images.Spec?
local function infer(key)
  if image.is_url(key) then return { kind = "url" } end
  if key:match "^mermaid:" or key:match "^plantuml:" or key:match "^vault:" then return nil end -- more is needed than the key says
  return { kind = "file" }
end

---@return number ms
local function now()
  return (vim.uv or vim.loop).hrtime() / 1e6
end

--- What is wrong with a spec, if anything: a diagram without its source, a vault name without a vault.
---@param spec? render-markdown-images.Spec nil when the key needed one and none was given
---@param key string
---@return string?
local function spec_problem(spec, key)
  if not spec then
    return key:match "^vault:" and "vault name or directory is missing" or "diagram source is missing"
  end
  local kind = spec.kind
  if (kind == "mermaid" or kind == "plantuml") and (spec.source or "") == "" then return "diagram source is missing" end
  if kind == "vault" and ((spec.name or "") == "" or (spec.dir or "") == "") then
    return "vault name or directory is missing"
  end
  return nil
end

--- Ask for an image. Never waits.
---
--- The first call for a key starts the work; `buf` is rendered again when it is done. Later calls
--- for the same key, from any buffer, join it.
---@param key string resolved file path, URL, or `diagram_key(...)`
---@param buf? integer the buffer to render again once the image is ready
---@param spec? render-markdown-images.Spec what to do for the key; guessed for paths and URLs, required for diagrams
---@return render-markdown-images.Status status
---@return render-markdown-images.Entry entry read-only; `id`, `w` and `h` are set when ready, `err` when failed
function M.get(key, buf, spec)
  local entry = entries[key]
  if not entry then
    spec = spec or infer(key)
    local problem = spec_problem(spec, key)
    entry = {
      key = key,
      spec = spec or { kind = "file" },
      status = problem and "failed" or "working",
      attempts = 0,
      bufs = {},
      err = problem,
      invalid = problem ~= nil,
      failed_at = problem and now() or nil,
    }
    entries[key] = entry
    if not problem then
      queue[#queue + 1] = key
      schedule_pump()
    end
  elseif entry.status == "failed" and entry.failed_at and now() - entry.failed_at >= M.limits.retry_failed_after then
    -- Asked for again long after it failed: try again. A spec that was never valid stays failed.
    if not entry.invalid then
      entry.status, entry.attempts, entry.failed_at = "working", 0, nil
      queue[#queue + 1] = key
      schedule_pump()
    end
  end
  if entry.status == "working" and buf then entry.bufs[buf] = true end
  return entry.status, entry
end

--- Like `get`, but starts nothing and remembers nothing.
---@param key string
---@return render-markdown-images.Status|"missing" status
---@return render-markdown-images.Entry? entry
function M.peek(key)
  local entry = entries[key]
  if not entry then return "missing", nil end
  return entry.status, entry
end

--- The Kitty ids of the images this store has sent to the terminal.
---@return integer[]
function M.image_ids()
  local ids = {}
  for _, entry in pairs(entries) do
    if entry.id then ids[#ids + 1] = entry.id end
  end
  table.sort(ids)
  return ids
end

--- Forget every entry of a kind, and delete its images from the terminal. They are asked for again, and made again,
--- the next time something needs them: for diagrams drawn in colours that are no longer the editor's.
---@param kind "file"|"url"|"vault"|"mermaid"|"plantuml"
---@return integer forgotten
function M.invalidate(kind)
  local ids, forgotten = {}, 0
  for key, entry in pairs(entries) do
    if entry.spec.kind == kind then
      if entry.id then ids[#ids + 1] = entry.id end
      entries[key] = nil
      forgotten = forgotten + 1
    end
  end
  if forgotten > 0 then
    queue = vim.tbl_filter(function(key)
      return entries[key] ~= nil
    end, queue)
    image.delete_images(ids)
  end
  return forgotten
end

--- Stop owing `buf` a re-render, for a buffer that is going away.
---@param buf integer
function M.forget_buf(buf)
  for _, entry in pairs(entries) do
    entry.bufs[buf] = nil
  end
  local timer = renders[buf]
  if timer then
    stop_timer(timer)
    renders[buf] = nil
  end
end

--- Every entry with its status, for `:checkhealth` and for finding out why something is not shown.
---@return { key: string, kind: string, status: render-markdown-images.Status, attempts: integer, err?: string, id?: integer }[]
function M.snapshot()
  local out = {}
  for key, entry in pairs(entries) do
    out[#out + 1] = {
      key = key,
      kind = entry.spec.kind,
      status = entry.status,
      attempts = entry.attempts,
      err = entry.err,
      id = entry.id,
    }
  end
  table.sort(out, function(a, b)
    return a.key < b.key
  end)
  return out
end

--- Counts, for tests and health checks.
---@return { entries: integer, running: integer, queued: integer, renders: integer }
function M.stats()
  return { entries = vim.tbl_count(entries), running = running, queued = #queue, renders = vim.tbl_count(renders) }
end

--- Forget every entry and pending re-render. Work already started is abandoned: it frees its place
--- at once, and whatever it answers later is dropped.
function M.reset()
  generation = generation + 1
  running = 0
  entries = {}
  queue = {}
  for buf, timer in pairs(renders) do
    stop_timer(timer)
    renders[buf] = nil
  end
end

return M
