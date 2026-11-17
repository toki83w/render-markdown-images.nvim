-- The copied modules live under this plugin's names, and follow its configuration.
-- Run: nvim --headless -u NONE --noplugin -l tests/wiring_test.lua

package.path = vim.fn.getcwd() .. "/?.lua;" .. package.path
local h = require "tests.harness"

local cache = h.isolate_cache()
local IMAGE = "render-markdown-images.image"

local function reset()
  h.unstub()
  require("render-markdown-images").setup()
end

h.test("setup() does not load the image module", function()
  package.loaded[IMAGE] = nil
  require("render-markdown-images").setup { enabled = false }
  h.assert_eq(package.loaded[IMAGE], nil, "still not loaded")
  reset()
end)

h.test("setup() after the image module is loaded makes it decide again", function()
  local saved = vim.o.termguicolors
  vim.o.termguicolors = true
  local rmi = require "render-markdown-images"
  local image = require(IMAGE)
  rmi.setup { enabled = true }
  h.assert_eq(image.supports_kitty(), true, "enabled = true is on without asking the terminal")
  rmi.setup { enabled = false }
  h.assert_eq(image.supports_kitty(), false, "off as soon as setup says so")
  rmi.setup { enabled = true }
  h.assert_eq(image.supports_kitty(), true, "and on again")
  h.assert_eq(image.probe_result(), "not_asked", "never asking the terminal")
  vim.o.termguicolors = saved
  reset()
end)

h.test("a rejected setup() leaves the image module's decision alone", function()
  local saved = vim.o.termguicolors
  vim.o.termguicolors = true
  local rmi = require "render-markdown-images"
  local image = require(IMAGE)
  rmi.setup { enabled = true }
  h.assert_eq(image.supports_kitty(), true, "on")
  h.assert_error(function()
    rmi.setup { enabled = "maybe" }
  end, "`enabled`", "refused")
  h.assert_eq(image.supports_kitty(), true, "still on")
  vim.o.termguicolors = saved
  reset()
end)

h.test("plantuml_server comes from the plugin configuration", function()
  local rmi = require "render-markdown-images"
  local image = require(IMAGE)
  h.stub(vim.fn, "executable", function(name)
    return name == "curl" and 1 or 0
  end)
  image.reset_cache()
  rmi.setup()
  h.assert_eq(image.has_plantuml(), false, "no server, no renderer")
  rmi.setup { plantuml_server = "https://plantuml.example.test" }
  h.assert_eq(image.has_plantuml(), true, "a server named in setup() is used")
  rmi.setup()
  h.assert_eq(image.has_plantuml(), false, "and forgotten again")
  reset()
  image.reset_cache()
end)

h.test("cache directories are under render-markdown-images", function()
  local image = require(IMAGE)
  local base = cache .. "/nvim/render-markdown-images"
  -- Each lookup creates its directory; ask for something that is not there.
  image.get_mermaid_cached "x"
  image.get_plantuml_cached "x"
  image.get_cached "https://example.test/x.png"
  for _, name in ipairs { "mermaid", "plantuml", "images" } do
    h.assert_eq(vim.fn.isdirectory(base .. "/" .. name), 1, name .. " cache")
  end
  h.assert_eq(vim.fn.isdirectory(cache .. "/nvim/md-render"), 0, "nothing under md-render's name")
end)

h.test("placeholder highlight groups use this plugin's prefix", function()
  local placeholder = require "render-markdown-images.placeholder"
  local name = placeholder.ensure_hl(0x010203, 42)
  h.assert_eq(name, "RenderMdImg_42", "named after the placement id")
  placeholder.delete_hl(name)
  h.assert_eq(placeholder.ns, nil, "the preview-only overlay namespace is gone")
  h.assert_eq(placeholder.render, nil, "and its renderer")
  h.assert_eq(placeholder.clear, nil, "and its cleaner")
end)

h.test("no md-render names are left in the sources", function()
  local files = vim.fn.glob(h.root .. "/lua/**/*.lua", false, true)
  vim.list_extend(files, { h.root .. "/scripts/vendor-async.sh" })
  h.assert_eq(#files > 10, true, "found the sources (" .. #files .. ")")
  local stale = {}
  for _, path in ipairs(files) do
    local lineno = 0
    for line in io.lines(path) do
      lineno = lineno + 1
      -- Credits in comments are fine; identifiers, requires, paths and messages are not.
      local code = line:gsub("^%s*%-%-.*$", "")
      if code:find("MdRender", 1, true) or code:find("md_render", 1, true) or code:find "md%-render" then
        stale[#stale + 1] = vim.fn.fnamemodify(path, ":.") .. ":" .. lineno .. ": " .. vim.trim(line)
      end
    end
  end
  h.assert_eq(stale, {}, "stale names")
end)

h.finish "wiring_test"
