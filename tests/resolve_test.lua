-- image.resolve: URLs (cache only), local paths, and the Obsidian fallback.
-- Run: nvim --headless -u NONE --noplugin -l tests/resolve_test.lua

package.path = vim.fn.getcwd() .. "/?.lua;" .. package.path
local h = require "tests.harness"

local cache = h.isolate_cache()
local image = require "render-markdown-images.image"
local obsidian = require "render-markdown-images.obsidian"

local fixture = h.root .. "/tests/fixtures/test_4x4.png"

--- Copy the 4x4 fixture to `dest`, making parent directories.
---@param dest string
local function put_png(dest)
  vim.fn.mkdir(vim.fn.fnamemodify(dest, ":h"), "p")
  assert(vim.uv.fs_copyfile(fixture, dest))
end

--- Where `image.lua` caches a downloaded URL: <cache>/render-markdown-images/images/<sha256[:16]>.<ext>
---@param url string
---@param ext string
local function url_cache_path(url, ext)
  return string.format("%s/nvim/render-markdown-images/images/%s.%s", cache, vim.fn.sha256(url):sub(1, 16), ext)
end

h.test("is_url: only http(s)", function()
  h.assert_eq(image.is_url "https://example.test/a.png", true, "https")
  h.assert_eq(image.is_url "http://example.test/a.png", true, "http")
  h.assert_eq(image.is_url "ftp://example.test/a.png", false, "ftp")
  h.assert_eq(image.is_url "/tmp/a.png", false, "absolute path")
  h.assert_eq(image.is_url "a.png", false, "relative path")
end)

h.test("is_badge_url: shields and friends are badges, ordinary images are not", function()
  for _, url in ipairs {
    "https://img.shields.io/badge/a-b-green.svg",
    "https://badge.fury.io/js/foo.svg",
    "https://codecov.io/gh/a/b/branch/main/graph/badge.svg",
    "https://github.com/a/b/workflows/ci/badge.svg",
    "https://example.test/x/flat-square.png",
  } do
    h.assert_eq(image.is_badge_url(url), true, url)
  end
  h.assert_eq(image.is_badge_url "https://example.test/photo.jpg", false, "photo")
  h.assert_eq(image.is_badge_url "https://github.com/a/b/raw/main/screenshot.png", false, "github raw image")
end)

h.test("resolve: an uncached URL is nil (resolve never downloads)", function()
  h.assert_eq(image.resolve "https://example.test/nothing-cached.png", nil, "no download, no answer")
end)

h.test("resolve: a cached URL gives the cache path", function()
  local url = "https://example.test/cached.png"
  local path = url_cache_path(url, "png")
  put_png(path)
  h.assert_eq(image.get_cached(url), path, "get_cached finds it in the render-markdown-images cache")
  h.assert_eq(image.resolve(url), path, "resolve returns it")
  h.assert_eq(image.resolve(url .. "?width=300"), nil, "a different URL is a different entry")
end)

h.test("resolve: the cached file's extension comes from the URL, query stripped", function()
  local url = "https://example.test/photo.png"
  put_png(url_cache_path(url, "png"))
  h.assert_eq(image.resolve(url), url_cache_path(url, "png"), "extension kept")
end)

h.test("get_cached: a cache file that is not an image is discarded", function()
  local url = "https://example.test/corrupt.png"
  local path = url_cache_path(url, "png")
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local f = assert(io.open(path, "wb"))
  f:write "<html>not an image</html>"
  f:close()
  h.assert_eq(image.get_cached(url), nil, "not served")
  h.assert_eq(vim.fn.filereadable(path), 0, "and removed")
end)

h.test("resolve: a badge URL is nil even when cached", function()
  local url = "https://img.shields.io/badge/a-b-green.png"
  put_png(url_cache_path(url, "png"))
  h.assert_eq(image.resolve(url), nil, "badges are skipped")
end)

h.test("resolve: absolute and relative local paths", function()
  local dir = vim.fn.tempname()
  put_png(dir .. "/docs/pic.png")
  h.assert_eq(image.resolve(dir .. "/docs/pic.png"), dir .. "/docs/pic.png", "absolute")
  h.assert_eq(image.resolve("pic.png", dir .. "/docs"), dir .. "/docs/pic.png", "relative to base_dir")
  h.assert_eq(image.resolve("docs/pic.png", dir), dir .. "/docs/pic.png", "relative with a subdirectory")
  h.assert_eq(image.resolve("missing.png", dir .. "/docs"), nil, "missing")
  h.assert_eq(image.resolve(dir .. "/docs/missing.png"), nil, "missing, absolute")
end)

h.test("resolve: ~ is expanded", function()
  local home = vim.fn.tempname()
  put_png(home .. "/pic.png")
  local saved = vim.env.HOME
  vim.env.HOME = home
  local got = image.resolve "~/pic.png"
  vim.env.HOME = saved
  h.assert_eq(got, home .. "/pic.png", "home directory")
end)

h.test("resolve: falls back to the Obsidian vault when the path is not found locally", function()
  obsidian.reset_cache()
  local vault = vim.fn.tempname()
  vim.fn.mkdir(vault .. "/.obsidian", "p")
  vim.fn.mkdir(vault .. "/notes", "p")
  put_png(vault .. "/attachments/embed.png")
  h.assert_eq(image.resolve("embed.png", vault .. "/notes"), vault .. "/attachments/embed.png", "vault-wide lookup")
  h.assert_eq(image.resolve "embed.png", nil, "without a base_dir there is no vault to search")
  h.assert_eq(image.resolve("nope.png", vault .. "/notes"), nil, "and a name nowhere in the vault stays unresolved")
  obsidian.reset_cache()
end)

h.test("resolve: a local file wins over the vault", function()
  obsidian.reset_cache()
  local vault = vim.fn.tempname()
  vim.fn.mkdir(vault .. "/.obsidian", "p")
  put_png(vault .. "/notes/same.png")
  put_png(vault .. "/other/same.png")
  h.assert_eq(image.resolve("same.png", vault .. "/notes"), vault .. "/notes/same.png", "next to the note")
  obsidian.reset_cache()
end)

h.finish "resolve_test"
