-- Demo: show an image in a scratch buffer through the copied image core.
--
-- Needs a terminal that speaks the Kitty graphics protocol (foot, kitty, WezTerm, Ghostty, ...),
-- directly or inside tmux (>= 3.3 with `set -g allow-passthrough on`).
--
--   RMI_DEMO_IMAGE=photo.png nvim -u NONE --cmd 'set rtp^=.' -S scripts/demo.lua
--
-- It transmits the PNG (t=t), creates a virtual placement sized to fit, and writes the Unicode
-- placeholder cells into the buffer, which is all the terminal needs to draw the picture.

vim.o.termguicolors = true
vim.o.ambiwidth = "single"
vim.o.number = false
vim.o.showmode = false

local image = require "render-markdown-images.image"
local placeholder = require "render-markdown-images.placeholder"

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local path = vim.fn.fnamemodify(vim.env.RMI_DEMO_IMAGE or (root .. "/tests/fixtures/test_4x4.png"), ":p")

local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(buf)

local function say(lines)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
end

image.clear_all()
local w, h = image.image_dimensions(path)
local id = image.transmit_image(path)
if not (w and id) then
  say { "render-markdown-images demo", "", "could not transmit " .. path }
  return
end

local cols, rows = image.calc_display_size(w, h, 40, 15)
local placement_id = 1
image.create_virtual_placement(id, placement_id, cols, rows)
local hl = placeholder.ensure_hl(id, placement_id)

local lines =
  { "render-markdown-images demo: " .. vim.fn.fnamemodify(path, ":t") .. " (" .. w .. "x" .. h .. " px)", "" }
local first = #lines
for r = 1, rows do
  lines[#lines + 1] = placeholder.row_text(r, cols)
end
lines[#lines + 1] = ""
lines[#lines + 1] = string.format("image id %d, placement %d, %d x %d cells; :q to leave", id, placement_id, cols, rows)
say(lines)

for r = 1, rows do
  vim.api.nvim_buf_set_extmark(buf, vim.api.nvim_create_namespace "rmi_demo", first + r - 1, 0, {
    end_row = first + r,
    end_col = 0,
    hl_group = hl,
    hl_eol = false,
  })
end
