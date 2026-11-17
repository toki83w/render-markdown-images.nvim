-- log: warnings written once per cause, to a file under the state directory.
-- Run: nvim --headless -u NONE --noplugin -l tests/log_test.lua

package.path = vim.fn.getcwd() .. "/?.lua;" .. package.path
local h = require "tests.harness"

h.isolate_cache()
local log = require "render-markdown-images.log"

h.test("the log lives in the state directory", function()
  h.assert_eq(log.path(), vim.fn.stdpath "state" .. "/render-markdown-images.log", "path")
  h.assert_eq(log.path():find(vim.env.XDG_STATE_HOME, 1, true) ~= nil, true, "and tests keep it out of the real one")
end)

h.test("a warning is written to the file and kept in memory", function()
  log.reset()
  h.assert_eq(log.warn "something went wrong", true, "written")
  local lines = vim.fn.readfile(log.path())
  h.assert_eq(#lines, 1, "one line in the file")
  h.assert_eq(
    lines[1]:match "^%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d WARN something went wrong$" ~= nil,
    true,
    "dated, with a level"
  )
  h.assert_eq(log.recent(), lines, "the same in memory")
end)

h.test("the same cause is written once, by default the message itself", function()
  log.reset()
  vim.fn.delete(log.path())
  h.assert_eq(log.warn "same", true, "first time")
  h.assert_eq(log.warn "same", false, "second time")
  h.assert_eq(log.warn "different", true, "another message")
  h.assert_eq(#vim.fn.readfile(log.path()), 2, "two lines")
end)

h.test("an id says what makes two warnings the same", function()
  log.reset()
  vim.fn.delete(log.path())
  h.assert_eq(log.warn("first key failed", "tool missing"), true, "first")
  h.assert_eq(log.warn("second key failed", "tool missing"), false, "same id, other text")
  h.assert_eq(log.warn("second key failed", "other"), true, "other id, same text as before")
  local lines = vim.fn.readfile(log.path())
  h.assert_eq(#lines, 2, "two lines")
  h.assert_eq(lines[1]:find("first key failed", 1, true) ~= nil, true, "the first text is the one kept")
end)

h.test("a warning is one line", function()
  log.reset()
  vim.fn.delete(log.path())
  log.warn "line one\nline two"
  local lines = vim.fn.readfile(log.path())
  h.assert_eq(#lines, 1, "one line")
  h.assert_eq(lines[1]:find("line one line two", 1, true) ~= nil, true, "newlines became spaces")
end)

h.test("the file is appended to, and the directory made", function()
  log.reset()
  vim.fn.delete(vim.env.XDG_STATE_HOME, "rf")
  log.warn "a"
  log.reset()
  log.warn "b"
  h.assert_eq(#vim.fn.readfile(log.path()), 2, "both runs are in the file")
end)

h.test("recent keeps the last fifty, oldest first", function()
  log.reset()
  for i = 1, 60 do
    log.warn("warning " .. i)
  end
  local recent = log.recent()
  h.assert_eq(#recent, 50, "fifty")
  h.assert_eq(recent[1]:find("warning 11", 1, true) ~= nil, true, "from the eleventh")
  h.assert_eq(recent[50]:find("warning 60", 1, true) ~= nil, true, "to the last")
  recent[1] = "changed"
  h.assert_eq(log.recent()[1]:find("warning 11", 1, true) ~= nil, true, "a copy: changing it changes nothing")
end)

h.test("a log that cannot be written is no error", function()
  log.reset()
  local blocker = vim.fn.tempname()
  vim.fn.writefile({ "a file, where the state directory should be" }, blocker)
  local saved = vim.env.XDG_STATE_HOME
  vim.env.XDG_STATE_HOME = blocker
  local ok, written = pcall(log.warn, "cannot be written")
  vim.env.XDG_STATE_HOME = saved
  h.assert_eq(ok, true, "no error")
  h.assert_eq(written, true, "still counted as written")
  h.assert_eq(#log.recent(), 1, "and kept in memory")
end)

h.finish "log_test"
