--- `:RenderMarkdownImages <name>`: the plugin's one command, and what each name does.
---
--- The command itself is made by `plugin/render-markdown-images.lua`, which loads nothing until it is used.

local M = {}

---@param msg string
---@param level? integer
local function say(msg, level)
  vim.notify("render-markdown-images: " .. msg, level or vim.log.levels.INFO)
end

---@type table<string, fun()>
local subcommands = {
  toggle = function()
    local on = require("render-markdown-images").toggle()
    say(on and "images shown" or "images hidden")
  end,
  enable = function()
    require("render-markdown-images").enable()
    say "images shown"
  end,
  disable = function()
    require("render-markdown-images").disable()
    say "images hidden"
  end,
}

--- The names the command takes, sorted.
---@return string[]
function M.names()
  local names = vim.tbl_keys(subcommands)
  table.sort(names)
  return names
end

--- The names that start with what has been typed, for completion.
---@param lead string
---@return string[]
function M.complete(lead)
  return vim.tbl_filter(function(name)
    return vim.startswith(name, lead)
  end, M.names())
end

--- Run `:RenderMarkdownImages {args}`.
---@param args string[]
function M.run(args)
  local usage = "{" .. table.concat(M.names(), "|") .. "}"
  if #args == 0 then return say("usage: :RenderMarkdownImages " .. usage, vim.log.levels.ERROR) end
  local run = subcommands[args[1]]
  if not run or #args > 1 then
    return say(
      ("unknown command `%s`, use :RenderMarkdownImages %s"):format(table.concat(args, " "), usage),
      vim.log.levels.ERROR
    )
  end
  run()
end

return M
