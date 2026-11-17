---@class render-markdown-images.ImagesConfig
---@field mode "below"|"replace"

---@class render-markdown-images.DiagramsConfig
---@field mode "below"|"replace"
---@field mermaid boolean
---@field plantuml boolean

---@class render-markdown-images.Config
---@field enabled "auto"|boolean
---@field images render-markdown-images.ImagesConfig
---@field diagrams render-markdown-images.DiagramsConfig
---@field plantuml_server string?

---@class render-markdown-images.Config.Module
local M = {}

local PREFIX = "render-markdown-images: "

M.MODES = { "below", "replace" }

---@return render-markdown-images.Config
function M.defaults()
  return {
    -- "auto" probes the terminal for Kitty graphics support; true/false skip the probe.
    enabled = "auto",
    images = { mode = "below" },
    diagrams = { mode = "below", mermaid = true, plantuml = true },
    -- Unset on purpose. A PlantUML fence is rendered by a local `plantuml` or
    -- `java -jar $PLANTUML_JAR` if there is one; naming a server here, e.g.
    -- "https://www.plantuml.com/plantuml", is what allows the source of a diagram
    -- to leave the machine, and nothing else turns that on.
    plantuml_server = nil,
  }
end

---@type render-markdown-images.Config
local current = M.defaults()

--- Raise a configuration error naming the offending option.
---@param path string
---@param expected string
---@param got any
local function fail(path, expected, got)
  error(("%s`%s` must be %s, got %s"):format(PREFIX, path, expected, vim.inspect(got)), 0)
end

---@param path string
---@param value any
local function check_mode(path, value)
  if not vim.tbl_contains(M.MODES, value) then fail(path, '"below" or "replace"', value) end
end

---@param path string
---@param value any
local function check_boolean(path, value)
  if type(value) ~= "boolean" then fail(path, "a boolean", value) end
end

---@param path string
---@param value any
---@param known table<string, true>
local function check_keys(path, value, known)
  if type(value) ~= "table" then fail(path, "a table", value) end
  for key in pairs(value) do
    if not known[key] then
      local full = path == "" and tostring(key) or (path .. "." .. tostring(key))
      error(("%sunknown option `%s`"):format(PREFIX, full), 0)
    end
  end
end

--- Validate a (merged) configuration. Raises an error describing the first problem.
---@param cfg render-markdown-images.Config
function M.validate(cfg)
  check_keys("", cfg, { enabled = true, images = true, diagrams = true, plantuml_server = true })

  if cfg.enabled ~= "auto" and type(cfg.enabled) ~= "boolean" then
    fail("enabled", '"auto", true or false', cfg.enabled)
  end

  check_keys("images", cfg.images, { mode = true })
  check_mode("images.mode", cfg.images.mode)

  check_keys("diagrams", cfg.diagrams, { mode = true, mermaid = true, plantuml = true })
  check_mode("diagrams.mode", cfg.diagrams.mode)
  check_boolean("diagrams.mermaid", cfg.diagrams.mermaid)
  check_boolean("diagrams.plantuml", cfg.diagrams.plantuml)

  local server = cfg.plantuml_server
  if server ~= nil and (type(server) ~= "string" or server == "") then
    fail("plantuml_server", "nil or a non-empty string", server)
  end
end

--- Merge user options over the defaults and validate. Does not touch the active configuration.
---@param opts? table
---@return render-markdown-images.Config
function M.resolve(opts)
  if opts ~= nil and type(opts) ~= "table" then fail("setup() options", "a table", opts) end
  local merged = vim.tbl_deep_extend("force", M.defaults(), opts or {})
  M.validate(merged)
  return merged
end

--- Validate `opts` and make the result the active configuration.
--- On error the previous configuration stays in place.
---@param opts? table
---@return render-markdown-images.Config
function M.setup(opts)
  current = M.resolve(opts)
  return current
end

---@return render-markdown-images.Config
function M.get()
  return current
end

return M
