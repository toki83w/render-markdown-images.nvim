-- Demo: the store takes an image through its pipeline and re-renders the buffers that waited.
--
--   nvim --headless -u NONE --cmd 'set rtp^=.' -l scripts/store_demo.lua [image.png]
--
-- Two buffers ask for the same image and a third key does not exist. Rendering is replaced by a
-- logger, so nothing needs render-markdown here; the terminal's side is replaced by a logger as
-- well when there is no UI to send to. Without an argument the 4x4 fixture is used.

local store = require "render-markdown-images.store"
local image = require "render-markdown-images.image"

require("render-markdown-images").setup {} -- nothing asks the terminal; this demo has none
vim.o.termguicolors = true

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local path = vim.fn.fnamemodify(arg[1] or (root .. "/tests/fixtures/test_4x4.png"), ":p")
local missing = root .. "/does-not-exist.png"

local t0 = vim.uv.hrtime()
local function log(fmt, ...)
  io.stdout:write(("%5.1f ms  %s\n"):format((vim.uv.hrtime() - t0) / 1e6, fmt:format(...)))
end

-- Stand-ins: the re-render, and (without a UI) the terminal.
store.render_buf = function(buf)
  log("render-markdown.render({ buf = %d, force = true })   <- what a finished image triggers", buf)
end
if #vim.api.nvim_list_uis() == 0 then
  vim.api.nvim_ui_send = function(data)
    log("terminal <- %s", vim.inspect(data):sub(1, 90))
  end
end
image._set_in_tmux(false)

local buf1 = vim.api.nvim_create_buf(false, true)
local buf2 = vim.api.nvim_create_buf(false, true)

local function ask(key, buf)
  local status, entry = store.get(key, buf)
  log(
    "store.get(%s, buf %d) -> %s%s",
    vim.fn.fnamemodify(key, ":t"),
    buf,
    status,
    entry.err and (" (" .. entry.err .. ")") or ""
  )
end

ask(path, buf1)
ask(path, buf2)
ask(missing, buf1)
ask(path, buf1)
log("stats: %s", vim.inspect(store.stats(), { newline = " ", indent = "" }))

vim.wait(2000, function()
  return store.peek(path) ~= "working" and store.peek(missing) ~= "working"
end, 5)
vim.wait(200, function()
  return false
end, 5) -- let the debounced re-render happen

for _, key in ipairs { path, missing } do
  local status, entry = store.get(key)
  log(
    "%s: %s %s",
    vim.fn.fnamemodify(key, ":t"),
    status,
    vim.inspect({ id = entry.id, w = entry.w, h = entry.h, err = entry.err }, { newline = " ", indent = "" })
  )
end
