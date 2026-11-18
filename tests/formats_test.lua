-- Formats: what is told apart by its bytes, which SVGs are refused, how each format is converted, and what the
-- store does with them. The converter and the terminal are stand-ins; the real ones are tried by hand.
-- Run: nvim --headless -u NONE --noplugin -l tests/formats_test.lua

package.path = vim.fn.getcwd() .. "/?.lua;" .. package.path
local h = require "tests.harness"

local cache = h.isolate_cache()
local store = require "render-markdown-images.store"
local image = require "render-markdown-images.image"
local async = require "render-markdown-images.async"

local fixture = h.root .. "/tests/fixtures/test_4x4.png"
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")

--- A file with exactly these bytes.
---@param name string
---@param bytes string
---@return string path
local function file(name, bytes)
  local path = dir .. "/" .. name
  local f = assert(io.open(path, "wb"))
  f:write(bytes)
  f:close()
  return path
end

--- The bytes of a BMP header with a DIB header of `dib` bytes.
local function bmp_bytes(dib)
  return "BM" .. string.rep("\0", 12) .. string.char(dib % 256, 0, 0, 0) .. string.rep("\0", 40)
end

local SVG = '<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><rect width="10" height="10"/></svg>'

-- ============================================================================
-- detect_format: the bytes decide, the name does not
-- ============================================================================

h.test("formats are told by their first bytes", function()
  h.assert_eq(image.detect_format(fixture), "png", "PNG")
  h.assert_eq(image.detect_format(file("a.jpg", "\255\216\255\224\0\16JFIF")), "jpeg", "JPEG")
  h.assert_eq(image.detect_format(file("a.webp", "RIFF\0\0\0\0WEBPVP8 ")), "webp", "WebP")
  h.assert_eq(image.detect_format(file("a.bmp", bmp_bytes(40))), "bmp", "BMP")
  h.assert_eq(image.detect_format(file("a.tiff", "II*\0\8\0\0\0")), "tiff", "TIFF little-endian")
  h.assert_eq(image.detect_format(file("b.tiff", "MM\0*\0\0\0\8")), "tiff", "TIFF big-endian")
  h.assert_eq(image.detect_format(file("c.tiff", "II+\0\8\0\8\0")), "tiff", "BigTIFF")
  h.assert_eq(image.detect_format(file("a.svg", SVG)), "svg", "SVG")
end)

h.test("the name of a file does not matter", function()
  h.assert_eq(image.detect_format(file("really_svg.png", SVG)), "svg", "an SVG called .png")
  h.assert_eq(image.detect_format(file("really_bmp.jpg", bmp_bytes(124))), "bmp", "a BMP called .jpg")
  h.assert_eq(image.detect_format(file("really_text.svg", "just some words")), nil, "text called .svg")
end)

h.test("SVG is recognised behind a BOM, an XML declaration, comments and a doctype", function()
  h.assert_eq(image.detect_format(file("bom.svg", "\239\187\191" .. SVG)), "svg", "BOM")
  h.assert_eq(image.detect_format(file("blank.svg", "\n\n  \t" .. SVG)), "svg", "blank space first")
  h.assert_eq(
    image.detect_format(
      file(
        "full.svg",
        '<?xml version="1.0"?>\n<!-- made by hand -->\n<!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "x">\n' .. SVG
      )
    ),
    "svg",
    "declaration, comment, doctype"
  )
  h.assert_eq(image.detect_format(file("tag.svg", "<svg>")), "svg", "a bare <svg>")
end)

h.test("what only looks like an image is not one", function()
  h.assert_eq(
    image.detect_format(file("bm.txt", "BM is a word, and this is text in a file of no size at all")),
    nil,
    "BM and text"
  )
  h.assert_eq(image.detect_format(file("bmp_dib.bmp", bmp_bytes(41))), nil, "BM with no DIB header size")
  h.assert_eq(
    image.detect_format(file("page.html", "<html><body><svg></svg></body></html>")),
    nil,
    "an HTML page with an SVG in it"
  )
  h.assert_eq(image.detect_format(file("late.txt", "see <svg> for more")), nil, "text that mentions <svg>")
  h.assert_eq(image.detect_format(file("a.gif", "GIF89a\1\0\1\0")), nil, "GIF")
  h.assert_eq(image.detect_format(file("a.pdf", "%PDF-1.7")), nil, "PDF")
  h.assert_eq(image.detect_format(file("riff.wav", "RIFF\0\0\0\0WAVEfmt ")), nil, "a RIFF that is not WebP")
  h.assert_eq(image.detect_format(file("empty", "")), nil, "an empty file")
  h.assert_eq(image.detect_format(dir .. "/does_not_exist"), nil, "a missing file")
  h.assert_eq(image.is_convertible_format(fixture), false, "PNG needs no conversion")
  h.assert_eq(image.is_convertible_format(file("c.svg", SVG)), true, "SVG does")
end)

-- ============================================================================
-- svg_refusal: only itself
-- ============================================================================

h.test("an SVG that keeps to itself is accepted", function()
  local own =
    [[<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="10" height="10">
    <defs><linearGradient id="g"><stop offset="0"/></linearGradient><path id="p" d="M0 0"/></defs>
    <rect fill="url(#g)" stroke="url('#g')" width="10" height="10"/>
    <use xlink:href="#p"/><use href="#p"/>
    <image href="data:image/png;base64,iVBORw0KGgo=" width="1" height="1"/>
    <image xlink:href="data:image/jpeg;base64,/9j/4AAQ" width="1" height="1"/>
    <text>see http://example.org for more</text>
  </svg>]]
  h.assert_eq(image.svg_refusal(file("own.svg", own)), nil, "no reason")
end)

h.test("an SVG that points outside itself is refused, whichever way it does", function()
  local function refused(name, body, expect)
    local why = image.svg_refusal(file(name .. ".svg", body))
    h.assert_eq(why ~= nil, true, name .. " is refused")
    if expect then h.assert_eq(why:find(expect, 1, true) ~= nil, true, name .. " says why: " .. tostring(why)) end
  end
  refused("file", '<svg xmlns:xlink="x"><image xlink:href="file:///etc/hostname"/></svg>', "outside itself")
  refused("relative", '<svg><image href="other.png"/></svg>', "outside itself")
  refused("remote", "<svg><image href='http://example.org/a.png'/></svg>", "outside itself")
  refused("upper", '<svg><image HREF="https://example.org/a.png"/></svg>', "outside itself")
  refused("src", '<svg><foreignObject><img src="http://example.org/a.png"/></foreignObject></svg>', "outside itself")
  refused("css", '<svg><rect style="fill:url(http://example.org/x)"/></svg>', "outside itself")
  refused("css_quoted", "<svg><rect style=\"fill:url('file:///etc/passwd')\"/></svg>", "outside itself")
  refused("escaped", '<svg><image href="&#102;ile:///etc/hostname"/></svg>', "outside itself")
  refused("svg_in_svg", '<svg><image href="data:image/svg+xml;base64,PHN2Zz4="/></svg>', "outside itself")
  refused("entity", '<!DOCTYPE svg [<!ENTITY x SYSTEM "file:///etc/passwd">]><svg><text>&x;</text></svg>', "entities")
  refused("stylesheet_pi", '<?xml-stylesheet href="a.css"?><svg/>', "stylesheet")
  refused("import", "<svg><style>@import url(a.css);</style></svg>", "stylesheet")
  refused("big", "<svg>" .. string.rep("x", 5 * 1024 * 1024 + 1) .. "</svg>", "larger than")
  h.assert_eq(image.svg_refusal(dir .. "/missing.svg") ~= nil, true, "a missing file is refused too")
end)

-- ============================================================================
-- Conversion: one command per format
-- ============================================================================

---@param present table<string, boolean>
local function with_executables(present)
  h.stub(vim.fn, "executable", function(name)
    return present[name] and 1 or 0
  end)
  image.reset_cache()
end

--- Stand in for the converter: record the command and write the PNG it was asked for.
local function stub_converter()
  local rec = { calls = {} }
  h.stub(async, "system", function(cmd)
    table.insert(rec.calls, cmd)
    assert(vim.uv.fs_copyfile(fixture, cmd[#cmd]))
    return { code = 0 }
  end)
  return rec
end

local function reset()
  h.unstub()
  image.reset_cache()
  store.reset()
end

--- Convert `path` and wait for the answer.
---@return boolean done, string? png, boolean? is_temp
local function convert(path)
  local done, png, is_temp = false, nil, nil
  image.ensure_png_async(path, function(p, t)
    png, is_temp, done = p, t, true
  end)
  h.wait_for(function()
    return done
  end)
  return done, png, is_temp
end

--- The command's arguments after `magick` and its resource limits.
---@param cmd string[]
---@return string[]
local function after_limits(cmd)
  local out, i = {}, 2
  while cmd[i] == "-limit" do
    i = i + 3
  end
  for j = i, #cmd do
    out[#out + 1] = cmd[j]
  end
  return out
end

h.test("every conversion has resource limits", function()
  reset()
  with_executables { magick = true }
  local rec = stub_converter()
  convert(file("limits.bmp", bmp_bytes(40)))
  local cmd = rec.calls[1]
  h.assert_eq(
    { unpack(cmd, 1, 10) },
    { "magick", "-limit", "time", "30", "-limit", "memory", "1GiB", "-limit", "map", "1GiB" },
    "time, memory, map"
  )
  reset()
end)

h.test("BMP and TIFF are read as what they are, first page only, and scaled down", function()
  reset()
  with_executables { magick = true }
  local rec = stub_converter()
  local bmp, tiff = file("one.bmp", bmp_bytes(40)), file("one.tiff", "II*\0\8\0\0\0")
  convert(bmp)
  convert(tiff)
  local dst1, dst2 = rec.calls[1][#rec.calls[1]], rec.calls[2][#rec.calls[2]]
  h.assert_eq(after_limits(rec.calls[1]), { "bmp:" .. bmp .. "[0]", "-resize", "2000x2000>", dst1 }, "BMP")
  h.assert_eq(after_limits(rec.calls[2]), { "tiff:" .. tiff .. "[0]", "-resize", "2000x2000>", dst2 }, "TIFF")
  h.assert_eq(dst1:match "%.png$" ~= nil, true, "a PNG is written")
  reset()
end)

h.test("a JPEG and a WebP are read as what they are too", function()
  reset()
  with_executables { magick = true }
  local rec = stub_converter()
  local jpg, webp = file("one.jpg", "\255\216\255\224 x"), file("one.webp", "RIFF\0\0\0\0WEBPVP8 ")
  convert(jpg)
  convert(webp)
  h.assert_eq(after_limits(rec.calls[1])[1], "jpeg:" .. jpg .. "[0]", "JPEG")
  h.assert_eq(after_limits(rec.calls[2])[1], "webp:" .. webp .. "[0]", "WebP")
  reset()
end)

h.test("an SVG is drawn at twice its size, on white", function()
  reset()
  with_executables { magick = true }
  local rec = stub_converter()
  local svg = file("one.svg", SVG)
  convert(svg)
  local dst = rec.calls[1][#rec.calls[1]]
  h.assert_eq(after_limits(rec.calls[1]), {
    "-density",
    "192",
    "-background",
    "white",
    "svg:" .. svg .. "[0]",
    "-alpha",
    "remove",
    "-alpha",
    "off",
    "-resize",
    "2000x2000>",
    dst,
  }, "density and background before the file, the alpha channel dropped after it")
  reset()
end)

h.test("an SVG that points outside itself is not handed to magick", function()
  reset()
  with_executables { magick = true }
  local rec = stub_converter()
  local done, png, is_temp = convert(file("evil.svg", '<svg><image href="file:///etc/hostname"/></svg>'))
  h.assert_eq({ done, png, is_temp }, { true, nil, false }, "nil answer")
  h.assert_eq(#rec.calls, 0, "no process")
  reset()
end)

h.test("a file of no known format is not handed to magick", function()
  reset()
  with_executables { magick = true }
  local rec = stub_converter()
  local done, png = convert(file("what.png.bin", "GIF89a\1\0\1\0"))
  h.assert_eq({ done, png }, { true, nil }, "nil answer")
  h.assert_eq(#rec.calls, 0, "no process")
  reset()
end)

-- ============================================================================
-- The store: the size comes from the converted PNG
-- ============================================================================

local function stub_produce_path(path)
  h.stub(store, "produce", function(_, _, done)
    done(path)
  end)
end

--- Wait for `key` to leave "working" and answer what it came to.
---@return string status, table? entry
local function settled(key)
  store.get(key, nil)
  h.wait_for(function()
    return (store.peek(key)) ~= "working" and (store.peek(key)) ~= "missing"
  end, 3000)
  return store.get(key, nil)
end

h.test("the store shows a BMP, a TIFF and an SVG at the size of their PNG", function()
  for _, case in ipairs {
    { "bmp", bmp_bytes(40) },
    { "tiff", "II*\0\8\0\0\0" },
    { "svg", SVG },
  } do
    reset()
    local path = file("store." .. case[1], case[2])
    stub_produce_path(path)
    h.stub(store, "render_buf", function() end)
    h.stub(store, "transmit", function(_, done)
      done(77, 24, 16)
    end)
    local status, entry = settled(path)
    h.assert_eq(status, "ready", case[1] .. " is ready")
    h.assert_eq({ entry.id, entry.w, entry.h }, { 77, 24, 16 }, case[1] .. ": the size of the converted PNG")
  end
  reset()
end)

h.test("a conversion that gives no size is a failure, not a picture of no size", function()
  reset()
  local path = file("nosize.bmp", bmp_bytes(40))
  stub_produce_path(path)
  h.stub(store, "render_buf", function() end)
  h.stub(store, "transmit", function(_, done)
    done(77)
  end)
  local status, entry = settled(path)
  h.assert_eq(status, "failed", "failed")
  h.assert_eq(entry.err:find("no size", 1, true) ~= nil, true, "says so: " .. tostring(entry.err))
  reset()
end)

h.test("an SVG that points outside itself fails with the reason, and is not transmitted", function()
  reset()
  local path = file("evil_store.svg", '<svg><image href="http://example.org/a.png"/></svg>')
  stub_produce_path(path)
  h.stub(store, "render_buf", function() end)
  local transmitted = 0
  h.stub(store, "transmit", function(_, done)
    transmitted = transmitted + 1
    done(1, 1, 1)
  end)
  local status, entry = settled(path)
  h.assert_eq(status, "failed", "failed")
  h.assert_eq(entry.err:find("outside itself", 1, true) ~= nil, true, "says why: " .. tostring(entry.err))
  h.assert_eq(transmitted, 0, "nothing was transmitted")
  reset()
end)

h.test("something that is not an image of a known format fails, whatever its name", function()
  reset()
  h.stub(store, "render_buf", function() end)
  h.stub(store, "transmit", function(_, done)
    done(1, 1, 1)
  end)
  for _, case in ipairs {
    { "junk.png", "<html>404</html>" },
    { "short.png", "\137PNG" },
    { "gif.svg", "GIF89a\1\0\1\0" },
  } do
    local path = file("store_" .. case[1], case[2])
    stub_produce_path(path)
    local status, entry = settled(path)
    h.assert_eq(status, "failed", case[1] .. " failed")
    h.assert_eq(
      entry.err:find("not a readable", 1, true) ~= nil,
      true,
      case[1] .. " says what is wrong: " .. tostring(entry.err)
    )
  end
  reset()
end)

vim.fn.delete(dir, "rf")
h.finish "formats_test"
