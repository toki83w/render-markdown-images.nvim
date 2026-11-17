--- A small log of things that went wrong in the background.
---
--- Work here happens out of sight: a diagram that cannot be rendered just draws nothing. The reason
--- goes to `stdpath("state")/render-markdown-images.log`, once per cause and session, where
--- `:checkhealth` and a curious user can find it, instead of into a notification nobody asked for.

---@class render-markdown-images.Log
local M = {}

local MAX_RECENT = 50

---@type table<string, true>
local seen = {}
---@type string[]
local recent = {}

---@return string
function M.path()
  return vim.fn.stdpath "state" .. "/render-markdown-images.log"
end

--- Write a warning, unless one with the same `id` was written before in this session.
---@param msg string
---@param id? string what makes two warnings the same; the message itself when not given
---@return boolean written
function M.warn(msg, id)
  id = id or msg
  if seen[id] then return false end
  seen[id] = true

  local line = ("%s WARN %s"):format(os.date "%Y-%m-%d %H:%M:%S", (msg:gsub("\n", " ")))
  recent[#recent + 1] = line
  if #recent > MAX_RECENT then table.remove(recent, 1) end

  -- A log that cannot be written is not worth an error of its own.
  pcall(function()
    vim.fn.mkdir(vim.fn.fnamemodify(M.path(), ":h"), "p")
    local f = assert(io.open(M.path(), "a"))
    f:write(line, "\n")
    f:close()
  end)
  return true
end

--- The warnings of this session, oldest first.
---@return string[]
function M.recent()
  return vim.list_slice(recent)
end

--- Forget what has been written, so the same causes are written again. For tests.
function M.reset()
  seen = {}
  recent = {}
end

return M
