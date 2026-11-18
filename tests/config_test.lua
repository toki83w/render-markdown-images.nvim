-- config defaults, merging and validation.
-- Run: nvim --headless -u NONE --noplugin -l tests/config_test.lua

package.path = vim.fn.getcwd() .. "/?.lua;" .. package.path
local h = require "tests.harness"
local config = require "render-markdown-images.config"
local rmi = require "render-markdown-images"

local function reset()
  config.setup(nil)
end

h.test("defaults", function()
  reset()
  h.assert_eq(config.get(), {
    images = { mode = "below" },
    diagrams = { mode = "below", mermaid = true, plantuml = true },
    plantuml_server = nil,
  }, "documented defaults")
end)

h.test("defaults() returns a fresh table each time", function()
  local a = config.defaults()
  a.images.mode = "replace"
  h.assert_eq(config.defaults().images.mode, "below", "mutating a copy does not leak")
end)

h.test("setup merges over defaults", function()
  rmi.setup { images = { mode = "replace" }, diagrams = { plantuml = false }, plantuml_server = "http://localhost:8080" }
  local c = config.get()
  h.assert_eq(c.images.mode, "replace", "images.mode overridden")
  h.assert_eq(c.diagrams.mode, "below", "diagrams.mode keeps default")
  h.assert_eq(c.diagrams.mermaid, true, "diagrams.mermaid keeps default")
  h.assert_eq(c.diagrams.plantuml, false, "diagrams.plantuml overridden")
  h.assert_eq(c.plantuml_server, "http://localhost:8080", "plantuml_server set")
  reset()
end)

h.test("setup() with no options keeps defaults", function()
  rmi.setup()
  h.assert_eq(config.get(), config.defaults(), "nil opts")
  rmi.setup {}
  h.assert_eq(config.get(), config.defaults(), "empty opts")
end)

h.test("setup is not cumulative", function()
  rmi.setup { images = { mode = "replace" } }
  rmi.setup { diagrams = { mode = "replace" } }
  h.assert_eq(config.get().images.mode, "below", "second call starts from the defaults")
  h.assert_eq(config.get().diagrams.mode, "replace", "second call applies")
  reset()
end)

h.test("mode accepts below and replace", function()
  for _, m in ipairs { "below", "replace" } do
    rmi.setup { images = { mode = m }, diagrams = { mode = m } }
    h.assert_eq(config.get().images.mode, m, "images.mode = " .. m)
    h.assert_eq(config.get().diagrams.mode, m, "diagrams.mode = " .. m)
  end
  reset()
end)

h.test("validation errors name the option", function()
  local P = "render-markdown-images: "
  h.assert_error(function()
    rmi.setup { images = { mode = "above" } }
  end, "`images.mode` must be", "images.mode")
  h.assert_error(function()
    rmi.setup { images = { mode = true } }
  end, "`images.mode` must be", "images.mode type")
  h.assert_error(function()
    rmi.setup { diagrams = { mode = "x" } }
  end, "`diagrams.mode` must be", "diagrams.mode")
  h.assert_error(function()
    rmi.setup { diagrams = { mermaid = "yes" } }
  end, "`diagrams.mermaid` must be a boolean", "mermaid")
  h.assert_error(function()
    rmi.setup { diagrams = { plantuml = 1 } }
  end, "`diagrams.plantuml` must be a boolean", "plantuml")
  h.assert_error(function()
    rmi.setup { plantuml_server = 5 }
  end, "`plantuml_server` must be", "server type")
  h.assert_error(function()
    rmi.setup { plantuml_server = "" }
  end, "`plantuml_server` must be", "server empty")
  h.assert_error(function()
    rmi.setup { images = "below" }
  end, "`images` must be a table", "images type")
  h.assert_error(function()
    rmi.setup "below"
  end, "setup() options", "opts type")
end)

h.test("unknown options are rejected", function()
  h.assert_error(function()
    rmi.setup { mode = "below" }
  end, "unknown option `mode`", "top level typo")
  h.assert_error(function()
    rmi.setup { enabled = true }
  end, "unknown option `enabled`", "there is no switch: the terminal is not asked, and the handlers are the on/off")
  h.assert_error(function()
    rmi.setup { enabled = "auto" }
  end, "unknown option `enabled`", "and no probe setting")
  h.assert_error(function()
    rmi.setup { images = { mod = "below" } }
  end, "unknown option `images.mod`", "nested typo")
  h.assert_error(function()
    rmi.setup { diagrams = { mermaide = true } }
  end, "unknown option `diagrams.mermaide`", "nested typo 2")
end)

h.test("a failed setup keeps the previous configuration", function()
  rmi.setup { images = { mode = "replace" } }
  pcall(rmi.setup, { diagrams = { mode = "nope" } })
  h.assert_eq(config.get().images.mode, "replace", "previous config survives")
  reset()
end)

h.finish "config_test"
