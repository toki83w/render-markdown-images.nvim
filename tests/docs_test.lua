-- The documentation says what the code does: every option and function is in the README and the help file, the
-- help file builds, its links go somewhere, and the Lua in the README is Lua.
-- Run: nvim --headless -u NONE --noplugin -l tests/docs_test.lua

package.path = vim.fn.getcwd() .. "/?.lua;" .. package.path
local h = require "tests.harness"

local config = require "render-markdown-images.config"

---@param path string
---@return string
local function read(path)
  return table.concat(vim.fn.readfile(h.root .. "/" .. path), "\n")
end

local readme = read "README.md"
local help = read "doc/render-markdown-images.txt"

--- The dotted names of every option, from the defaults: `images.mode`, `diagrams.mermaid`, ...
---@return string[]
local function option_names()
  local out = {}
  local function walk(prefix, t)
    for key, value in pairs(t) do
      local name = prefix == "" and key or (prefix .. "." .. key)
      if type(value) == "table" then
        walk(name, value)
      else
        out[#out + 1] = name
      end
    end
  end
  walk("", config.defaults())
  table.sort(out)
  return out
end

-- The options with a default of nil do not show in the table above.
local OPTIONS = vim.list_extend(option_names(), { "plantuml_server" })

h.test("every option is in the README, with its default, and in the help file with a tag", function()
  h.assert_eq(#OPTIONS >= 5, true, "found the options (" .. table.concat(OPTIONS, ", ") .. ")")
  for _, name in ipairs(OPTIONS) do
    h.assert_eq(readme:find("`" .. name .. "`", 1, true) ~= nil, true, name .. " in the README")
    h.assert_eq(
      help:find("*render-markdown-images-" .. name .. "*", 1, true) ~= nil,
      true,
      name .. " tagged in the help"
    )
  end
end)

h.test("the defaults the README shows are the defaults", function()
  local defaults = config.defaults()
  h.assert_eq(readme:find('images = { mode = "' .. defaults.images.mode .. '" }', 1, true) ~= nil, true, "images.mode")
  h.assert_eq(readme:find('mode = "' .. defaults.diagrams.mode .. '",', 1, true) ~= nil, true, "diagrams.mode")
  h.assert_eq(readme:find("mermaid = " .. tostring(defaults.diagrams.mermaid) .. ",", 1, true) ~= nil, true, "mermaid")
  h.assert_eq(
    readme:find("plantuml = " .. tostring(defaults.diagrams.plantuml) .. ",", 1, true) ~= nil,
    true,
    "plantuml"
  )
  h.assert_eq(readme:find("plantuml_server = nil", 1, true) ~= nil, true, "plantuml_server")
  h.assert_eq(
    help:find('images = { mode = "' .. defaults.images.mode .. '" }', 1, true) ~= nil,
    true,
    "help: images.mode"
  )
end)

h.test("every public function is documented in both", function()
  local public = {}
  for name, value in pairs(require "render-markdown-images") do
    if type(value) == "function" then public[#public + 1] = name end
  end
  table.sort(public)
  h.assert_eq(
    public,
    { "disable", "enable", "handlers", "is_enabled", "set_download_fn", "setup", "toggle" },
    "the public API (add new functions to the docs)"
  )
  for _, name in ipairs(public) do
    h.assert_eq(readme:find("rmi." .. name, 1, true) ~= nil, true, name .. " in the README")
    h.assert_eq(
      help:find("*render-markdown-images." .. name .. "()*", 1, true) ~= nil,
      true,
      name .. " tagged in the help"
    )
  end
end)

h.test("every option the README table lists is one setup() takes, and the other way round", function()
  -- Each row of the options table starts with the option in backticks.
  local listed = {}
  for name in readme:gmatch "\n| `([%w_.]+)`%s*|" do
    listed[#listed + 1] = name
  end
  table.sort(listed)
  local expected = vim.deepcopy(OPTIONS)
  table.sort(expected)
  h.assert_eq(listed, expected, "the table")
  for _, name in ipairs(listed) do
    local opts = {}
    local node = opts
    local parts = vim.split(name, ".", { plain = true })
    for i, part in ipairs(parts) do
      if i == #parts then
        node[part] = name:find("mode", 1, true) and "replace"
          or (name == "plantuml_server" and "https://x.test" or true)
      else
        node[part] = {}
        node = node[part]
      end
    end
    h.assert_eq(pcall(config.resolve, opts), true, name .. " is accepted")
  end
end)

h.test("the Lua in the README is Lua", function()
  local n = 0
  for code in readme:gmatch "```lua\n(.-)\n```" do
    n = n + 1
    -- A block may be an expression (a lazy.nvim spec) as well as statements.
    local fn, err = loadstring(code)
    if not fn then fn = loadstring("return " .. code) end
    h.assert_eq(fn ~= nil, true, "block " .. n .. " compiles" .. (err and (": " .. err) or ""))
  end
  h.assert_eq(n >= 3, true, "found the blocks (" .. n .. ")")
end)

h.test("the Lua in the help file is Lua", function()
  local n = 0
  for code in help:gmatch ">lua\n(.-)\n<\n" do
    n = n + 1
    local fn, err = loadstring(code)
    if not fn then fn = loadstring("return " .. code) end
    h.assert_eq(fn ~= nil, true, "block " .. n .. " compiles" .. (err and (": " .. err) or ""))
  end
  h.assert_eq(n >= 2, true, "found the blocks (" .. n .. ")")
end)

h.test("the help file builds, and every link in it goes to a tag", function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir .. "/doc", "p")
  vim.fn.writefile(
    vim.fn.readfile(h.root .. "/doc/render-markdown-images.txt"),
    dir .. "/doc/render-markdown-images.txt"
  )
  h.assert_eq(pcall(vim.cmd, "helptags " .. vim.fn.fnameescape(dir .. "/doc")), true, "helptags runs")
  local tags = {}
  for _, line in ipairs(vim.fn.readfile(dir .. "/doc/tags")) do
    tags[line:match "^([^\t]+)"] = true
  end
  h.assert_eq(tags["render-markdown-images.txt"], true, "the file's own tag")
  h.assert_eq(tags["render-markdown-images-contents"], true, "the contents")
  for _, tag in ipairs {
    "render-markdown-images.setup()",
    "render-markdown-images.handlers()",
    "render-markdown-images.set_download_fn()",
  } do
    h.assert_eq(tags[tag], true, tag)
  end
  -- Links to Neovim's own help are not ours to check; ours all start with the plugin's name.
  local missing = {}
  for link in help:gmatch "|(render%-markdown%-images[^|%s]*)|" do
    if not tags[link] then missing[#missing + 1] = link end
  end
  h.assert_eq(missing, {}, "no link to a tag that is not there")
  vim.fn.delete(dir, "rf")
end)

h.test("the help file keeps to 78 columns", function()
  local long = {}
  for i, line in ipairs(vim.fn.readfile(h.root .. "/doc/render-markdown-images.txt")) do
    if vim.fn.strdisplaywidth(line) > 78 then long[#long + 1] = i .. ": " .. line:sub(1, 40) end
  end
  h.assert_eq(long, {}, "lines longer than 78 columns")
end)

h.test("the README's links to files are to files that exist", function()
  local n = 0
  -- [text](target) that is not an image, outside code spans, and not a web address or an anchor.
  local text = ("\n" .. readme):gsub("\n```[^\n]*\n.-\n```", ""):gsub("`[^`\n]*`", "")
  for before, target in text:gmatch "(.?)%[[^%]]*%]%(([^)%s]+)%)" do
    if before ~= "!" and not target:find "^https?:" and not target:find "^#" then
      n = n + 1
      h.assert_eq(vim.uv.fs_stat(h.root .. "/" .. target) ~= nil, true, target .. " exists")
    end
  end
  h.assert_eq(n >= 1, true, "found a link to check (" .. n .. ")")
  h.assert_eq(
    vim.uv.fs_stat(h.root .. "/lua/render-markdown-images/vendor/LICENSE-neovim.txt") ~= nil,
    true,
    "Neovim's licence is kept"
  )
end)

h.test("the notices name every borrowed thing", function()
  local notices = read "THIRD_PARTY_NOTICES.md"
  for _, needle in ipairs {
    "md-render.nvim",
    "Copyright (c) 2026 delphinus",
    "vim.async",
    "Apache-2.0",
    "snacks.nvim",
    "render-markdown.nvim",
  } do
    h.assert_eq(notices:find(needle, 1, true) ~= nil, true, needle)
  end
  for _, file in ipairs { "image.lua", "placeholder.lua", "async.lua", "tty.lua", "obsidian.lua" } do
    h.assert_eq(notices:find(file, 1, true) ~= nil, true, file .. " is credited")
  end
end)

h.test("the demos the README names exist", function()
  for _, path in ipairs { "scripts/demo_below.lua", "scripts/demo_below.md", "tests/fixtures/vault/notes/note.md" } do
    h.assert_eq(vim.uv.fs_stat(h.root .. "/" .. path) ~= nil, true, path)
    h.assert_eq(readme:find(path, 1, true) ~= nil, true, path .. " is in the README")
  end
end)

h.test("every command is documented in both, and is defined by the plugin directory", function()
  local plugin = read "plugin/render-markdown-images.lua"
  local defined = {}
  for name in plugin:gmatch 'nvim_create_user_command%("(%w+)"' do
    defined[#defined + 1] = name
  end
  table.sort(defined)
  h.assert_eq(defined, { "RenderMarkdownImages" }, "the commands (add new ones to the docs)")
  for _, name in ipairs(defined) do
    h.assert_eq(readme:find("`:" .. name .. " <name>`", 1, true) ~= nil, true, name .. " in the README")
    h.assert_eq(help:find("*:" .. name .. "*", 1, true) ~= nil, true, name .. " tagged in the help")
  end
  -- And every name it takes.
  local names = require("render-markdown-images.command").names()
  h.assert_eq(names, { "disable", "enable", "toggle" }, "the names (add new ones to the docs)")
  for _, sub in ipairs(names) do
    h.assert_eq(readme:find("`:RenderMarkdownImages " .. sub .. "`", 1, true) ~= nil, true, sub .. " in the README")
    h.assert_eq(help:find("*:RenderMarkdownImages-" .. sub .. "*", 1, true) ~= nil, true, sub .. " tagged in the help")
  end
end)

h.finish "docs_test"
