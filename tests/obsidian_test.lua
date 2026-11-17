-- Obsidian vault detection and file resolution.
-- Run: nvim --headless -u NONE --noplugin -l tests/obsidian_test.lua

package.path = vim.fn.getcwd() .. "/?.lua;" .. package.path
local h = require "tests.harness"
local obsidian = require "render-markdown-images.obsidian"

local root = vim.fn.tempname()

--- Create `path` (relative to the temp root) with `content`, making parent directories.
---@param path string
---@param content? string
---@return string absolute
local function write(path, content)
  local abs = root .. "/" .. path
  vim.fn.mkdir(vim.fn.fnamemodify(abs, ":h"), "p")
  local f = assert(io.open(abs, "wb"))
  f:write(content or "x")
  f:close()
  return abs
end

--- A fresh vault directory named `name`, with `app` as .obsidian/app.json (nil: no app.json).
---@param name string
---@param app? string
---@return string vault
local function vault(name, app)
  obsidian.reset_cache()
  write(name .. "/.obsidian/workspace.json", "{}")
  if app then write(name .. "/.obsidian/app.json", app) end
  return root .. "/" .. name
end

h.test("find_vault_root: walks up to the directory holding .obsidian", function()
  local v = vault "v1"
  write "v1/notes/deep/er/note.md"
  h.assert_eq(obsidian.find_vault_root(v), v, "the vault itself")
  h.assert_eq(obsidian.find_vault_root(v .. "/notes/deep/er"), v, "a nested directory")
end)

h.test("find_vault_root: nil outside a vault, and remembered", function()
  vault "v2"
  write "plain/note.md"
  h.assert_eq(obsidian.find_vault_root(root .. "/plain"), nil, "a directory with no vault above it")
  h.assert_eq(obsidian.find_vault_root(root .. "/plain"), nil, "same answer from the cache")
end)

h.test("get_attachment_folder: reads attachmentFolderPath from app.json", function()
  local v = vault("v3", '{"attachmentFolderPath":"assets/img"}')
  obsidian.find_vault_root(v)
  h.assert_eq(obsidian.get_attachment_folder(v), "assets/img", "configured folder")
  h.assert_eq(obsidian.get_attachment_folder(v), "assets/img", "and again, from the cache")
end)

h.test("get_attachment_folder: missing, malformed or incomplete config is nil", function()
  for name, app in pairs {
    v4a = false, -- no app.json
    v4b = "{ not json",
    v4c = '{"somethingElse":1}',
  } do
    local v = vault(name, app or nil)
    obsidian.find_vault_root(v)
    h.assert_eq(obsidian.get_attachment_folder(v), nil, name)
  end
end)

h.test("resolve: attachment folder relative to the vault", function()
  local v = vault("v5", '{"attachmentFolderPath":"attachments"}')
  local img = write "v5/attachments/pic.png"
  write "v5/notes/note.md"
  h.assert_eq(obsidian.resolve("pic.png", v .. "/notes"), img, "found in the attachment folder")
  h.assert_eq(obsidian.resolve("sub/dir/pic.png", v .. "/notes"), img, "only the basename counts")
end)

h.test("resolve: attachment folder './' is relative to the note", function()
  local v = vault("v6", '{"attachmentFolderPath":"./media"}')
  local img = write "v6/notes/media/pic.png"
  h.assert_eq(obsidian.resolve("pic.png", v .. "/notes"), img, "next to the note, under media/")
  local v2 = vault("v7", '{"attachmentFolderPath":"./"}')
  local img2 = write "v7/notes/pic.png"
  h.assert_eq(obsidian.resolve("pic.png", v2 .. "/notes"), img2, "'./' alone means the note's own directory")
end)

h.test("resolve: vault root, then a vault-wide search", function()
  local v = vault "v8"
  local at_root = write "v8/rootpic.png"
  local buried = write "v8/a/b/c/buried.png"
  h.assert_eq(obsidian.resolve("rootpic.png", v .. "/a"), at_root, "at the vault root")
  h.assert_eq(obsidian.resolve("buried.png", v), buried, "anywhere in the vault")
  h.assert_eq(obsidian.resolve("absent.png", v), nil, "not in the vault at all")
end)

h.test("resolve: the attachment folder wins over the vault root", function()
  local v = vault("v9", '{"attachmentFolderPath":"att"}')
  local att = write("v9/att/dup.png", "attachment")
  write("v9/dup.png", "root")
  h.assert_eq(obsidian.resolve("dup.png", v), att, "attachment folder first")
end)

h.test("resolve: a cached answer is dropped when the file goes away", function()
  local v = vault "v10"
  local p = write "v10/gone.png"
  h.assert_eq(obsidian.resolve("gone.png", v), p, "found")
  os.remove(p)
  h.assert_eq(obsidian.resolve("gone.png", v), nil, "not served from the cache once deleted")
end)

h.test("resolve: nil outside a vault", function()
  vault "v11"
  write "outside/pic.png"
  h.assert_eq(obsidian.resolve("pic.png", root .. "/outside"), nil, "no vault, no resolution")
end)

vim.fn.delete(root, "rf")
h.finish "obsidian_test"
