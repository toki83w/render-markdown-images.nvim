-- ensure_png: which tool converts, with what command line, and where the result is cached.
-- No real converter is run.
-- Run: nvim --headless -u NONE --noplugin -l tests/convert_test.lua

package.path = vim.fn.getcwd() .. "/?.lua;" .. package.path
local h = require "tests.harness"

local cache = h.isolate_cache()
local image = require "render-markdown-images.image"
local async = require "render-markdown-images.async"

local fixture = h.root .. "/tests/fixtures/test_4x4.png"
local CONVERTED_DIR = cache .. "/nvim/render-markdown-images/converted"

---@param present table<string, boolean>
local function with_executables(present)
  h.stub(vim.fn, "executable", function(name)
    return present[name] and 1 or 0
  end)
  image.reset_cache()
end

--- Stand in for the converter: record the command and write the PNG it was asked for.
---@param code? integer exit code to report (default 0; non-zero writes nothing)
---@return { calls: string[][] }
local function stub_converter(code)
  local rec = { calls = {} }
  h.stub(async, "system", function(cmd)
    table.insert(rec.calls, cmd)
    if (code or 0) == 0 then assert(vim.uv.fs_copyfile(fixture, cmd[#cmd])) end
    return { code = code or 0 }
  end)
  return rec
end

--- A file that is not a PNG, so it has to be converted.
---@return string path
local function make_source()
  local path = vim.fn.tempname() .. ".jpg"
  local f = assert(io.open(path, "wb"))
  f:write "\255\216\255\224 not really a jpeg"
  f:close()
  return path
end

--- Call `ensure_png_async` and wait for the callback. Returns answered, png_path, is_temp.
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

local function reset()
  h.unstub()
  image.reset_cache()
end

h.test("a PNG needs no conversion, whatever tools exist", function()
  reset()
  with_executables { ffmpeg = true, magick = true }
  local rec = stub_converter()
  local done, png, is_temp = convert(fixture)
  h.assert_eq({ done, png, is_temp }, { true, fixture, false }, "passed through untouched")
  h.assert_eq(#rec.calls, 0, "nothing spawned")
  h.assert_eq(image.is_native_format(fixture), true, "is_native_format")
  h.assert_eq(image.is_native_format(make_source()), false, "a JPEG is not")
  h.assert_eq(image.is_native_format "/no/such/file.png", false, "nor a missing file")
  reset()
end)

h.test("ffmpeg is preferred over magick, with a bounded-size scale filter", function()
  reset()
  with_executables { ffmpeg = true, magick = true }
  local rec = stub_converter()
  local src = make_source()
  local done, png = convert(src)
  h.assert_eq(done, true, "answered")
  local cmd = rec.calls[1]
  h.assert_eq(cmd[1], "ffmpeg", "ffmpeg")
  h.assert_eq({ unpack(cmd, 2, 4) }, { "-y", "-i", src }, "reads the source")
  h.assert_eq(cmd[#cmd]:match "%.png$" ~= nil, true, "writes a PNG")
  h.assert_eq(vim.tbl_contains(cmd, "-vframes"), true, "a single frame")
  h.assert_eq(
    vim.tbl_contains(cmd, "scale='min(2000,iw)':'min(2000,ih)':force_original_aspect_ratio=decrease"),
    true,
    "scaled down to 2000 px, never up"
  )
  h.assert_eq(png:find(CONVERTED_DIR .. "/", 1, true) ~= nil, true, "result lives in the render-markdown-images cache")
  reset()
end)

h.test("magick is used when ffmpeg is missing", function()
  reset()
  with_executables { magick = true }
  local rec = stub_converter()
  local src = make_source()
  convert(src)
  h.assert_eq({ unpack(rec.calls[1], 1, 4) }, { "magick", src, "-resize", "2000x2000>" }, "command")
  reset()
end)

if vim.fn.has "mac" == 0 then
  h.test("sips is only for macOS", function()
    reset()
    with_executables { sips = true, magick = true }
    local rec = stub_converter()
    convert(make_source())
    h.assert_eq(rec.calls[1][1], "magick", "sips is ignored elsewhere")
    reset()
  end)
end

h.test("no tool: nothing converted, nothing spawned", function()
  reset()
  with_executables {}
  local rec = stub_converter()
  local done, png, is_temp = convert(make_source())
  h.assert_eq({ done, png, is_temp }, { true, nil, false }, "nil answer")
  h.assert_eq(#rec.calls, 0, "no process")
  reset()
end)

h.test("a failing converter answers nil", function()
  reset()
  with_executables { ffmpeg = true }
  stub_converter(1)
  local done, png, is_temp = convert(make_source())
  h.assert_eq({ done, png, is_temp }, { true, nil, false }, "nil answer")
  reset()
end)

h.test("converted PNGs are cached by source path and mtime", function()
  reset()
  with_executables { ffmpeg = true }
  local rec = stub_converter()
  local src = make_source()
  local _, first, first_temp = convert(src)
  local hash = vim.fn.sha256(src):sub(1, 16)
  h.assert_eq(first_temp, false, "a cached result is not temporary")
  h.assert_eq(
    first,
    string.format("%s/%s_%d_2000.png", CONVERTED_DIR, hash, vim.fn.getftime(src)),
    "<converted>/<hash>_<mtime>_<max dimension>.png"
  )
  h.assert_eq(image.image_dimensions(first), 4, "and it is the converter's output")

  local _, second = convert(src)
  h.assert_eq(second, first, "same path the second time")
  h.assert_eq(#rec.calls, 1, "converted once")

  local later = vim.fn.getftime(src) + 5
  vim.uv.fs_utime(src, later, later)
  local _, third = convert(src)
  h.assert_eq(third ~= first, true, "a changed source gets a new entry")
  h.assert_eq(#rec.calls, 2, "and is converted again")
  reset()
end)

h.finish "convert_test"
