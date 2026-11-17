-- Kitty Unicode placeholder tests: grid text and highlight groups
-- Run: nvim --headless -u NONE --noplugin -l tests/placeholder_test.lua

package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path

local placeholder = require "render-markdown-images.placeholder"

local pass_count = 0
local fail_count = 0

local function assert_eq(actual, expected, msg)
  if vim.deep_equal(actual, expected) then
    pass_count = pass_count + 1
  else
    fail_count = fail_count + 1
    print("FAIL: " .. msg)
    print("  expected: " .. vim.inspect(expected))
    print("  actual:   " .. vim.inspect(actual))
  end
end

local function assert_true(val, msg)
  if val then
    pass_count = pass_count + 1
  else
    fail_count = fail_count + 1
    print("FAIL: " .. msg)
  end
end

local function test(name, fn)
  local ok, err = pcall(fn)
  if not ok then
    fail_count = fail_count + 1
    print("ERROR: " .. name .. ": " .. tostring(err))
  end
end

--- Code points of every character in `s`, composing characters included.
---@param s string
---@return integer[]
local function codepoints(s)
  local cps = {}
  local pos = vim.str_utf_pos(s)
  for i, start in ipairs(pos) do
    cps[i] = vim.fn.char2nr(s:sub(start, (pos[i + 1] or #s + 1) - 1))
  end
  return cps
end

local PH = 0x10EEEE

-- ============================================================================
-- Table
-- ============================================================================

test("MAX is 297, the size of Kitty's diacritics table", function()
  assert_eq(placeholder.MAX, 297, "297 rows/columns")
end)

test("the table starts and ends where Kitty's does", function()
  -- Row 1 / column 1 is the first entry (number 0), the last cell the last entry.
  assert_eq(codepoints(placeholder.row_text(1, 1)), { PH, 0x0305, 0x0305 }, "first entry is U+0305")
  assert_eq(
    codepoints(placeholder.row_text(placeholder.MAX, placeholder.MAX):sub(-12)),
    { PH, 0x1D244, 0x1D244 },
    "last entry is U+1D244"
  )
end)

test("every row and column has its own diacritic", function()
  local seen, dups = {}, 0
  for n = 1, placeholder.MAX do
    local cps = codepoints(placeholder.row_text(n, 1))
    if seen[cps[2]] then dups = dups + 1 end
    seen[cps[2]] = true
  end
  assert_eq(dups, 0, "no diacritic is used twice")
end)

-- ============================================================================
-- row_text
-- ============================================================================

test("row_text: a 2x3 grid is placeholder + row + column per cell", function()
  -- Row 1 and 2 of a grid 3 columns wide; diacritics 1, 2 and 3 are
  -- U+0305, U+030D and U+030E.
  assert_eq(
    codepoints(placeholder.row_text(1, 3)),
    { PH, 0x0305, 0x0305, PH, 0x0305, 0x030D, PH, 0x0305, 0x030E },
    "row 1: row diacritic fixed, column diacritic counting up"
  )
  assert_eq(
    codepoints(placeholder.row_text(2, 3)),
    { PH, 0x030D, 0x0305, PH, 0x030D, 0x030D, PH, 0x030D, 0x030E },
    "row 2: the row diacritic changes"
  )
end)

test("row_text: the row diacritic comes before the column diacritic", function()
  assert_eq(
    codepoints(placeholder.row_text(2, 1)),
    { PH, 0x030D, 0x0305 },
    "row 2, column 1 is (row=U+030D, col=U+0305)"
  )
  assert_eq(codepoints(placeholder.row_text(1, 2)), { PH, 0x0305, 0x0305, PH, 0x0305, 0x030D }, "row 1, columns 1-2")
end)

test("row_text: one cell per column, each a single character", function()
  local text = placeholder.row_text(1, 20)
  assert_eq(vim.fn.strchars(text), 60, "three code points per cell")
  assert_eq(vim.api.nvim_strwidth(text), 20, "one display column per cell")
end)

test("row_text: columns are clamped to the table", function()
  local text = placeholder.row_text(1, 1000)
  assert_eq(vim.api.nvim_strwidth(text), placeholder.MAX, "no more cells than diacritics")
end)

test("row_text: a row outside the table has no text", function()
  assert_eq(placeholder.row_text(0, 1), nil, "row 0")
  assert_eq(placeholder.row_text(placeholder.MAX + 1, 1), nil, "row 298")
end)

-- ============================================================================
-- Highlights
-- ============================================================================

local function get_hl(name)
  return vim.api.nvim_get_hl(0, { name = name, link = false })
end

test("ensure_hl: fg is the image id, sp the placement id, nocombine on", function()
  local name = placeholder.ensure_hl(0x010203, 7)
  assert_eq(name, "RenderMdImg_7", "named after the placement")
  local hl = get_hl(name)
  assert_eq(hl.fg, 0x010203, "fg carries the image id")
  assert_eq(hl.sp, 7, "sp carries the placement id")
  assert_eq(hl.nocombine, true, "nocombine keeps the ids from being blended")
  -- Neovim sends the underline colour (SGR 58), which carries `sp`, only for an
  -- underlined cell; without this the placement id never leaves Neovim.
  assert_eq(hl.underline, true, "underline makes Neovim send the placement id")
  placeholder.delete_hl(name)
end)

test("ensure_hl: redefining a group points it at the new image", function()
  local name = placeholder.ensure_hl(101, 8)
  placeholder.ensure_hl(102, 8)
  assert_eq(get_hl(name).fg, 102, "fg follows the latest call")
  placeholder.delete_hl(name)
end)

test("delete_hl: clears the group", function()
  local name = placeholder.ensure_hl(101, 10)
  placeholder.delete_hl(name)
  assert_eq(get_hl(name), {}, "no attributes left")
end)

print(string.format("\nplaceholder_test: %d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then os.exit(1) end
