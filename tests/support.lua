-- Helpers shared by tests: fake image files and waiting.

local M = {}

---@param n integer
---@return string four bytes, big endian
local function be32(n)
  return string.char(math.floor(n / 16777216) % 256, math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256)
end

--- Write a file with a valid PNG signature and header for a `w` x `h` image. That is all the plugin reads
--- of it, and enough for everything but a terminal that would actually draw it.
---@param path string
---@param w integer
---@param h integer
function M.make_png(path, w, h)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local f = assert(io.open(path, "wb"))
  f:write("\137PNG\r\n\26\n", be32(13), "IHDR", be32(w), be32(h), "\8\2\0\0\0", "\0\0\0\0")
  f:close()
end

--- Run the event loop for `ms` milliseconds.
---@param ms integer
function M.sleep(ms)
  vim.wait(ms, function()
    return false
  end, 5)
end

return M
