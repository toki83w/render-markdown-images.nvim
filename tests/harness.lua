-- Minimal assertion harness shared by tests/*_test.lua.
-- Run a test with: nvim --headless -u NONE --noplugin -l tests/<name>_test.lua
-- (from the repository root; `make test` does this for every test).

local root = vim.fn.getcwd()
package.path = table.concat({ root .. "/lua/?.lua", root .. "/lua/?/init.lua", root .. "/?.lua", package.path }, ";")

local M = { root = root }

local pass_count, fail_count = 0, 0

---@param actual any
---@param expected any
---@param msg string
function M.assert_eq(actual, expected, msg)
  if vim.deep_equal(actual, expected) then
    pass_count = pass_count + 1
  else
    fail_count = fail_count + 1
    print("FAIL: " .. msg)
    print("  expected: " .. vim.inspect(expected))
    print("  actual:   " .. vim.inspect(actual))
  end
end

--- Assert that `fn` raises an error whose message contains `needle` (plain match).
---@param fn fun()
---@param needle string
---@param msg string
function M.assert_error(fn, needle, msg)
  local ok, err = pcall(fn)
  if ok then
    fail_count = fail_count + 1
    print("FAIL: " .. msg .. " (no error raised)")
  elseif not tostring(err):find(needle, 1, true) then
    fail_count = fail_count + 1
    print("FAIL: " .. msg)
    print("  expected error containing: " .. needle)
    print("  actual error:              " .. tostring(err))
  else
    pass_count = pass_count + 1
  end
end

--- Run a named test case; an unexpected error counts as a failure.
---@param name string
---@param fn fun()
function M.test(name, fn)
  local ok, err = pcall(fn)
  if not ok then
    fail_count = fail_count + 1
    print("ERROR: " .. name .. ": " .. tostring(err))
  end
end

local stubs = {}

--- Replace `tbl[key]` with `value` until `M.unstub()`.
---@param tbl table
---@param key string
---@param value any
function M.stub(tbl, key, value)
  table.insert(stubs, { tbl = tbl, key = key, value = tbl[key] })
  tbl[key] = value
end

--- Undo every `M.stub`, newest first.
function M.unstub()
  for i = #stubs, 1, -1 do
    local s = stubs[i]
    s.tbl[s.key] = s.value
  end
  stubs = {}
end

--- Make `vim.fn.stdpath("cache")` point at a fresh temporary directory, so tests never touch the
--- user's real cache. Returns the directory.
---@return string
function M.isolate_cache()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  vim.env.XDG_CACHE_HOME = dir
  return dir
end

--- Pump the event loop until `pred()` is true (or `ms` pass). Returns whether it became true.
---@param pred fun(): boolean
---@param ms? integer
---@return boolean
function M.wait_for(pred, ms)
  return vim.wait(ms or 2000, pred, 10)
end

--- Print the summary and exit non-zero when anything failed.
---@param name string
function M.finish(name)
  print(string.format("%s: %d passed, %d failed", name, pass_count, fail_count))
  if fail_count > 0 then os.exit(1) end
  os.exit(0)
end

--- Locate a sibling plugin checkout. Order: `$<env>`, ~/software/neovim_plugins/<name>, lazy.nvim's data dir.
---@param env string
---@param name string
---@return string?
function M.find_plugin(env, name)
  local candidates = {
    vim.env[env] or "", -- not nil: ipairs would stop at a hole
    vim.fn.expand("~/software/neovim_plugins/" .. name),
    vim.fn.stdpath "data" .. "/lazy/" .. name,
  }
  for _, dir in ipairs(candidates) do
    if dir ~= "" and vim.fn.isdirectory(dir .. "/lua") == 1 then return dir end
  end
end

return M
