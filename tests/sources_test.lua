-- Where images come from: remote URLs, and names in an Obsidian vault. discover -> store -> marks, with the
-- download stubbed (a function given to `set_download_fn`, or a stand-in for `image.download_async`) and a
-- vault made on disk. Nothing goes over the network.
-- Run: nvim --headless -u NONE --noplugin -l tests/sources_test.lua

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
local obsidian = require "render-markdown-images.obsidian"
local async = require "render-markdown-images.async"

local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
local pngs = root .. "/pngs"
support.make_png(pngs .. "/wide.png", 400, 200) -- 40 x 10 cells at 10x20 px
support.make_png(pngs .. "/small.png", 40, 20) -- 4 x 1 cells

--- Downloads asked for, and what they answer: a path to give back, or false for a failure.
---@type { calls: string[], answers: table<string, string|false> }
local downloads

local function reset()
  h.unstub()
  store.reset()
  marks.reset()
  obsidian.reset_cache()
  rmi.setup()
  rmi.set_download_fn(nil)
  image.reset_cache()
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

  downloads = { calls = {}, answers = {} }
  h.stub(image, "download_async", function(url, callback)
    table.insert(downloads.calls, url)
    local answer = downloads.answers[url]
    callback(answer or nil)
  end)
end

local function finish_test()
  h.unstub()
  store.reset()
  marks.reset()
  obsidian.reset_cache()
  rmi.set_download_fn(nil)
  image._test_cell_size = nil
  image.reset_cache()
  rmi.setup()
end

--- A markdown buffer shown in the current window, named in `dir`.
---@param lines string[]
---@param dir? string
---@return integer buf
local function open(lines, dir)
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buf, ("%s/doc-%d.md"):format(dir or root, buf))
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_current_buf(buf)
  vim.bo[buf].filetype = "markdown"
  vim.treesitter.start(buf, "markdown")
  vim.treesitter.get_parser(buf, "markdown"):parse(true)
  return buf
end

---@param buf integer
---@return render.md.Mark[]
local function run(buf)
  local tree_root = vim.treesitter.get_parser(buf, "markdown"):parse(true)[1]:root()
  return handlers.new().markdown.parse { buf = buf, root = tree_root, last = true }
end

---@param buf integer
---@param n? integer
---@return render.md.Mark[]
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

--- A vault with a notes folder and `files` (paths in the vault) holding a 40 x 20 px image.
---@param files string[]
---@param app? string content of .obsidian/app.json
---@return string vault
local function make_vault(files, app)
  local vault = vim.fn.tempname()
  vim.fn.mkdir(vault .. "/.obsidian", "p")
  vim.fn.mkdir(vault .. "/notes", "p")
  if app then vim.fn.writefile({ app }, vault .. "/.obsidian/app.json") end
  for _, file in ipairs(files) do
    support.make_png(vault .. "/" .. file, 40, 20)
  end
  return vault
end

-- ============================================================================
-- source_key: what is asked for, without waiting or searching
-- ============================================================================

local function key_of(src, dir, embed)
  return handlers.source_key({ src = src, embed = embed or false }, dir or root)
end

h.test("source_key: a URL is its own key, and the store works out what it is", function()
  reset()
  h.assert_eq({ key_of "https://example.test/a.png" }, { "https://example.test/a.png", nil }, "https")
  h.assert_eq(
    { key_of "http://example.test/a.png?x=1&y=2" },
    { "http://example.test/a.png?x=1&y=2", nil },
    "http, with a query"
  )
  finish_test()
end)

h.test("source_key: badges, GIFs and videos are not worth any work", function()
  reset()
  for _, src in ipairs {
    "https://img.shields.io/badge/a-b-green.svg",
    "https://github.com/a/b/workflows/ci/badge.svg",
    "https://example.test/anim.gif",
    "https://example.test/clip.mp4?x=1",
    "local.gif",
    "clip.webm",
  } do
    h.assert_eq({ key_of(src) }, {}, src)
  end
  finish_test()
end)

h.test("source_key: other schemes are not files", function()
  reset()
  for _, src in ipairs {
    "data:image/png;base64,AAAA",
    "mailto:a@b.test",
    "ftp://example.test/a.png",
    "file:///tmp/a.png",
  } do
    h.assert_eq({ key_of(src) }, {}, src)
  end
  finish_test()
end)

h.test("source_key: a file next to the note is its resolved path", function()
  reset()
  h.assert_eq({ key_of "pngs/small.png" }, { root .. "/pngs/small.png", nil }, "a path")
  h.assert_eq({ key_of "pngs/missing.png" }, {}, "a missing one, outside any vault, is nothing")
  finish_test()
end)

h.test("source_key: in a vault a name that is not a local file is the vault's to find", function()
  reset()
  local vault = make_vault({ "attachments/pic.png" }, '{"attachmentFolderPath":"attachments"}')
  local key, spec = key_of("pic.png", vault .. "/notes", true)
  h.assert_eq(key, "vault:" .. vault .. ":pic.png", "keyed by vault and name")
  h.assert_eq(spec, { kind = "vault", name = "pic.png", dir = vault .. "/notes" }, "with the way to look it up")
  h.assert_eq(store.stats().entries, 0, "nothing was searched for or asked of the store")
  finish_test()
end)

h.test("source_key: a file next to the note wins over the vault", function()
  reset()
  local vault = make_vault({ "attachments/pic.png", "notes/pic.png" }, '{"attachmentFolderPath":"attachments"}')
  h.assert_eq({ key_of("pic.png", vault .. "/notes", true) }, { vault .. "/notes/pic.png", nil }, "the local one")
  finish_test()
end)

h.test("source_key: no search on a render: a miss costs a stat and a walk up for .obsidian, once", function()
  reset()
  local vault = make_vault({}, nil)
  local searched = 0
  local resolve = obsidian.resolve
  h.stub(obsidian, "resolve", function(...)
    searched = searched + 1
    return resolve(...)
  end)
  for _ = 1, 20 do
    key_of("not-there.png", vault .. "/notes", true)
  end
  h.assert_eq(searched, 0, "the vault was never searched by source_key")
  finish_test()
end)

-- ============================================================================
-- Remote images
-- ============================================================================

local URL = "https://example.test/pic.png"

h.test("a remote image: working while it downloads, then drawn under its line", function()
  reset()
  downloads.answers[URL] = pngs .. "/wide.png"
  local buf = open { "text", "", "![remote](" .. URL .. ")", "", "more" }
  h.assert_eq(run(buf), {}, "nothing while pending")
  h.assert_eq(store.peek(URL) ~= "missing", true, "but it is asked for, under its URL")
  local result = run_until_marks(buf)
  h.assert_eq(#result, 1, "one mark")
  h.assert_eq(result[1].start_row, 2, "under its row")
  h.assert_eq(#result[1].opts.virt_lines, 10, "10 rows: the downloaded file is 400x200 px")
  h.assert_eq(downloads.calls, { URL }, "downloaded once, through the stand-in")
  finish_test()
end)

h.test("a remote image: the buffer is rendered again when the download is done", function()
  reset()
  downloads.answers[URL] = pngs .. "/small.png"
  local rendered = {}
  h.stub(store, "render_buf", function(buf)
    rendered[#rendered + 1] = buf
  end)
  local buf = open { "![remote](" .. URL .. ")" }
  run(buf)
  h.wait_for(function()
    return #rendered > 0
  end, 3000)
  h.assert_eq(rendered, { buf }, "once")
  finish_test()
end)

h.test("a remote image in replace mode replaces its row", function()
  reset()
  rmi.setup { images = { mode = "replace" } }
  h.stub(package.loaded, "render-markdown.lib.replacements", {})
  downloads.answers[URL] = pngs .. "/small.png"
  local buf = open { "text", "", "![remote](" .. URL .. ")", "", "more" }
  local result = run_until_marks(buf)
  h.assert_eq(#result, 1, "one mark")
  h.assert_eq(
    { result[1].start_row, result[1].opts.conceal_lines, result[1].replace ~= nil },
    { 2, "", true },
    "the row concealed, the image as its replacement"
  )
  finish_test()
end)

h.test("a remote image among text keeps the text, and goes below", function()
  reset()
  downloads.answers[URL] = pngs .. "/small.png"
  local buf = open { "see ![remote](" .. URL .. ") here", "", "end" }
  local result = run_until_marks(buf)
  h.assert_eq(#result, 1, "below mode: one mark, nothing concealed")
  h.assert_eq({ result[1].conceal, result[1].opts.conceal }, { false, nil }, "the source stays")
  finish_test()
end)

h.test("the same URL twice is one download and one store entry", function()
  reset()
  downloads.answers[URL] = pngs .. "/small.png"
  local buf = open { "![a](" .. URL .. ")", "", "![b](" .. URL .. ")" }
  local result = run_until_marks(buf, 2)
  settle()
  h.assert_eq(#result, 2, "drawn twice")
  h.assert_eq(downloads.calls, { URL }, "downloaded once")
  h.assert_eq(store.stats().entries, 1, "one entry")
  finish_test()
end)

h.test("a badge asks for nothing: no entry, no download", function()
  reset()
  local buf = open { "![build](https://img.shields.io/github/actions/workflow/status/a/b/ci.yml)", "", "text" }
  h.assert_eq(run(buf), {}, "no marks")
  settle()
  h.assert_eq(store.stats().entries, 0, "no entry")
  h.assert_eq(downloads.calls, {}, "no download")
  finish_test()
end)

h.test("GIFs and data URIs are skipped too", function()
  reset()
  local buf = open { "![a](https://example.test/anim.gif)", "", "![b](data:image/png;base64,iVBORw0KGgo=)" }
  run(buf)
  settle()
  h.assert_eq({ store.stats().entries, #downloads.calls }, { 0, 0 }, "nothing asked for")
  finish_test()
end)

h.test("a download that fails: nothing drawn, quietly, and retried when it is asked for again later", function()
  reset()
  h.stub(store.limits, "retry_failed_after", 60)
  downloads.answers[URL] = false
  local buf = open { "![remote](" .. URL .. ")" }
  run(buf)
  h.wait_for(function()
    return store.peek(URL) == "failed"
  end, 3000)
  h.assert_eq(#downloads.calls, 4, "four attempts: the first and three retries")
  h.assert_eq(run(buf), {}, "no marks, the source stays")
  run(buf)
  h.assert_eq(#downloads.calls, 4, "asking again at once does not download again")

  downloads.answers[URL] = pngs .. "/small.png"
  support.sleep(100)
  run(buf)
  local result = run_until_marks(buf)
  h.assert_eq(#result, 1, "asked again after the network is back: drawn")
  finish_test()
end)

h.test("a download that is not an image is a failure, not a crash", function()
  reset()
  local junk = root .. "/junk.png"
  vim.fn.writefile({ "<html>404</html>" }, junk)
  downloads.answers[URL] = junk
  local buf = open { "![remote](" .. URL .. ")" }
  run(buf)
  h.wait_for(function()
    return store.peek(URL) == "failed"
  end, 3000)
  h.assert_eq(select(2, store.get(URL)).err:find("not a readable", 1, true) ~= nil, true, "says what is wrong with it")
  finish_test()
end)

-- ---------------------------------------------------------------------------
-- The real download path: `set_download_fn`, the cache, curl's command line
-- ---------------------------------------------------------------------------

h.test("set_download_fn: the function takes the job, and what it wrote is shown", function()
  reset()
  h.unstub() -- the real image.download_async from here on
  h.stub(vim.api, "nvim_ui_send", function() end)
  h.stub(store, "render_buf", function() end)
  h.stub(store.limits, "debounce", 10)
  local n = 100
  h.stub(store, "transmit", function(_, done)
    n = n + 1
    done(n)
  end)
  local asked = {}
  rmi.set_download_fn(function(url, output_path, callback)
    asked[#asked + 1] = { url, vim.fn.fnamemodify(output_path, ":h:t") }
    vim.uv.fs_copyfile(pngs .. "/wide.png", output_path)
    callback(true)
    return true
  end)
  local buf = open { "![private](https://private.example.test/pic.png)" }
  local result = run_until_marks(buf)
  h.assert_eq(#result, 1, "drawn")
  h.assert_eq(#result[1].opts.virt_lines, 10, "from the file the function wrote")
  h.assert_eq(
    asked,
    { { "https://private.example.test/pic.png", "images" } },
    "asked once, to write into the images cache"
  )
  finish_test()
end)

h.test("set_download_fn: returning false leaves the URL to curl", function()
  reset()
  h.unstub()
  h.stub(vim.api, "nvim_ui_send", function() end)
  h.stub(store, "render_buf", function() end)
  local curl = {}
  h.stub(async, "system", function(cmd)
    curl[#curl + 1] = cmd
    vim.uv.fs_copyfile(pngs .. "/small.png", cmd[#cmd - 1])
    return { code = 0 }
  end)
  h.stub(store, "transmit", function(_, done)
    done(101)
  end)
  rmi.set_download_fn(function()
    return false
  end)
  local buf = open { "![x](https://example.test/curled.png)" }
  run_until_marks(buf)
  h.assert_eq(#curl, 1, "curl ran")
  local cmd = curl[1]
  h.assert_eq(cmd[1], "curl", "curl")
  h.assert_eq(cmd[#cmd], "https://example.test/curled.png", "with the URL last")
  local function after(flag)
    for i, v in ipairs(cmd) do
      if v == flag then return cmd[i + 1] end
    end
  end
  h.assert_eq(after "--max-time", "10", "bounded in time")
  h.assert_eq(after "--max-filesize", "20000000", "and in size")
  h.assert_eq(after "--proto", "=http,https", "http(s) only")
  h.assert_eq(after "--proto-redir", "=http,https", "also after a redirect")
  h.assert_eq(vim.tbl_contains(cmd, "-sfL"), true, "silent, failing on HTTP errors, following redirects")
  finish_test()
end)

h.test("the cache serves a second session: no download when the file is already there", function()
  reset()
  h.unstub()
  h.stub(vim.api, "nvim_ui_send", function() end)
  h.stub(store, "render_buf", function() end)
  h.stub(store.limits, "debounce", 10)
  local n = 100
  h.stub(store, "transmit", function(_, done)
    n = n + 1
    done(n)
  end)
  local downloaded = 0
  rmi.set_download_fn(function(_, output_path, callback)
    downloaded = downloaded + 1
    vim.uv.fs_copyfile(pngs .. "/wide.png", output_path)
    callback(true)
    return true
  end)
  local url = "https://example.test/cached-between-sessions.png"
  local buf = open { "![x](" .. url .. ")" }
  h.assert_eq(#run_until_marks(buf), 1, "first session: drawn")
  h.assert_eq(downloaded, 1, "after one download")

  -- A new session: nothing in memory, the cache directory as it was.
  store.reset()
  marks.reset()
  image.reset_cache()
  local reopened = open { "![x](" .. url .. ")" }
  local result = run_until_marks(reopened)
  h.assert_eq(#result, 1, "second session: drawn")
  h.assert_eq(downloaded, 1, "without a second download")
  finish_test()
end)

-- ============================================================================
-- Obsidian vaults
-- ============================================================================

h.test("a wikilink embed in a vault note is found in the attachments folder", function()
  reset()
  local vault = make_vault({ "attachments/pic.png" }, '{"attachmentFolderPath":"attachments"}')
  local buf = open({ "![[pic.png|300]]", "", "text" }, vault .. "/notes")
  h.assert_eq(run(buf), {}, "pending")
  local result = run_until_marks(buf)
  h.assert_eq(#result, 1, "drawn")
  h.assert_eq(#result[1].opts.virt_lines, 1, "40x20 px is one row")
  finish_test()
end)

h.test("the standard syntax falls back to the vault too, and a nested name finds its file", function()
  reset()
  local vault = make_vault({ "attachments/pic.png", "deep/er/other.png" }, '{"attachmentFolderPath":"attachments"}')
  local buf = open({ "![a](pic.png)", "", "![b](other.png)", "", "![[deep/er/other.png]]" }, vault .. "/notes")
  local result = run_until_marks(buf, 3)
  h.assert_eq(#result, 3, "all three")
  finish_test()
end)

h.test("in replace mode a vault image replaces its row", function()
  reset()
  rmi.setup { images = { mode = "replace" } }
  h.stub(package.loaded, "render-markdown.lib.replacements", {})
  local vault = make_vault({ "attachments/pic.png" }, '{"attachmentFolderPath":"attachments"}')
  local buf = open({ "text", "", "![[pic.png]]", "", "more" }, vault .. "/notes")
  local result = run_until_marks(buf)
  h.assert_eq(
    { result[1].start_row, result[1].opts.conceal_lines, result[1].replace ~= nil },
    { 2, "", true },
    "row 2 concealed, image as the replacement"
  )
  finish_test()
end)

h.test("a vault image is searched for once, not on every render", function()
  reset()
  local vault = make_vault({ "elsewhere/deep/pic.png" }, nil) -- no attachment folder: a search of the vault
  local searched = 0
  local resolve = obsidian.resolve
  h.stub(obsidian, "resolve", function(...)
    searched = searched + 1
    return resolve(...)
  end)
  local buf = open({ "![[pic.png]]" }, vault .. "/notes")
  run_until_marks(buf)
  for _ = 1, 10 do
    run(buf)
  end
  h.assert_eq(searched, 1, "one search, and the answer remembered")
  finish_test()
end)

h.test("a name that is nowhere in the vault: nothing drawn, one search, quietly, and again later", function()
  reset()
  h.stub(store.limits, "retry_failed_after", 80)
  local vault = make_vault({}, '{"attachmentFolderPath":"attachments"}')
  local searched = 0
  local resolve = obsidian.resolve
  h.stub(obsidian, "resolve", function(...)
    searched = searched + 1
    return resolve(...)
  end)
  local buf = open({ "![[later.png]]", "", "text" }, vault .. "/notes")
  run(buf)
  h.wait_for(function()
    return store.peek("vault:" .. vault .. ":later.png") == "failed"
  end, 3000)
  h.assert_eq(searched, 1, "searched once: not finding something is not worth four attempts")
  for _ = 1, 10 do
    h.assert_eq(run(buf), {}, "nothing drawn, the source stays")
  end
  h.assert_eq(searched, 1, "and not searched again on every render")
  local err = select(2, store.get("vault:" .. vault .. ":later.png")).err
  h.assert_eq(err, "not in the Obsidian vault: later.png", "the entry says so")

  -- The file turns up. Some time later, rendering again looks again.
  support.make_png(vault .. "/attachments/later.png", 40, 20)
  obsidian.reset_cache()
  support.sleep(120)
  run(buf)
  local result = run_until_marks(buf)
  h.assert_eq(#result, 1, "drawn once it is there")
  h.assert_eq(searched, 2, "after a second search")
  finish_test()
end)

h.test("the real fixture vault", function()
  reset()
  local note = h.root .. "/tests/fixtures/vault/notes/note.md"
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buf, note)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.fn.readfile(note))
  vim.api.nvim_set_current_buf(buf)
  vim.bo[buf].filetype = "markdown"
  vim.treesitter.start(buf, "markdown")
  run_until_marks(buf, 2)
  settle()
  local result = run(buf)
  h.assert_eq(#result, 3, "the embed alone, the embed in a sentence, the standard syntax")
  h.assert_eq(
    store.peek("vault:" .. h.root .. "/tests/fixtures/vault:no-such-picture.png"),
    "failed",
    "the missing one failed"
  )
  finish_test()
end)

h.test("a note outside any vault asks nothing about names it cannot find", function()
  reset()
  local buf = open { "![[nowhere.png]]", "", "![x](nowhere.png)" }
  run(buf)
  settle()
  h.assert_eq(store.stats().entries, 0, "no entries")
  finish_test()
end)

h.finish "sources_test"
