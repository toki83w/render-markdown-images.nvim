--- `:checkhealth render-markdown-images`
---
--- Read-only: it reports what it finds and what to change, and changes nothing itself. This is the only place that
--- looks at the terminal. The plugin never asks it whether it can show images, since configuring the plugin says
--- it can; what it answers is reported here, for finding out why nothing shows. The same goes for 'termguicolors'
--- and 'ambiwidth': drawing does not check them, so an error here is what a missing or garbled image comes from.
local M = {}

--- The oldest tmux that passes graphics sequences through (`allow-passthrough`).
local MIN_TMUX = { 3, 3 }

--- Run `tmux <args>` and return its output, or nil if it failed. Replaceable so the checks can be tested without
--- a tmux server.
---@param args string[]
---@return string?
function M._tmux(args)
  local ok, res = pcall(function()
    return vim.system(vim.list_extend({ "tmux" }, args), { text = true }):wait(1000)
  end)
  if ok and res and res.code == 0 then return vim.trim(res.stdout or "") end
  return nil
end

--- The formats `magick` can read, from `magick -list format` (names in capitals), or nil if it could not be
--- asked. Replaceable so the checks can be tested without ImageMagick.
---@return table<string, boolean>?
function M._magick_formats()
  local ok, res = pcall(function()
    return vim.system({ "magick", "-list", "format" }, { text = true }):wait(5000)
  end)
  if not ok or not res or res.code ~= 0 then return nil end
  local formats = {}
  for line in (res.stdout or ""):gmatch "[^\n]+" do
    -- `     WEBP* WEBP      rw+   WebP Image Format`: name, module, mode (read, write, multi-frame)
    local name, mode = line:match "^%s+([%w_%-]+)%*?%s+%S+%s+([r%-][w%-][%+%-])"
    if name and mode:sub(1, 1) == "r" then formats[name:upper()] = true end
  end
  return formats
end

--- `"tmux 3.3a"` / `"tmux next-3.4"` -> 3, 3 / 3, 4.
---@param out string?
---@return integer? major, integer? minor
local function parse_tmux_version(out)
  local major, minor = (out or ""):match "(%d+)%.(%d+)"
  if not major then return nil end
  return tonumber(major), tonumber(minor)
end

---@return render-markdown-images.Config
local function config()
  return require("render-markdown-images.config").get()
end

-- ============================================================================
-- Neovim
-- ============================================================================

local function check_neovim(h)
  h.start "render-markdown-images: Neovim"
  if vim.fn.has "nvim-0.12" == 1 and vim.api.nvim_ui_send then
    local v = vim.version()
    h.ok(
      string.format("Neovim %d.%d.%d (has `nvim_ui_send`, used for every terminal write)", v.major, v.minor, v.patch)
    )
  else
    h.error("Neovim 0.12 or newer is required (`vim.api.nvim_ui_send`)", "Upgrade Neovim")
  end
  h.info("async runtime: " .. require("render-markdown-images.async").backend)
end

-- ============================================================================
-- Terminal
-- ============================================================================

local function check_terminal(h, image, in_tmux)
  h.start "render-markdown-images: terminal"
  h.info("$TERM: " .. (vim.env.TERM or "unset") .. (in_tmux and " (inside tmux)" or ""))

  if jit.os == "Windows" then
    h.warn("Windows is not a platform this plugin was made for", "The terminal size is read with POSIX calls")
  end

  -- The one place the terminal is asked. Nothing at run time depends on the answer.
  local probe = image.probe()
  local unused = "Nothing depends on this answer: images are drawn whatever it is."
  if probe == "ok" then
    h.ok "the terminal answered the Kitty graphics protocol query"
  elseif probe == "da1_first" then
    h.warn(
      "the terminal answered a device attributes query without answering the Kitty graphics one: it does not implement the protocol",
      "Use a terminal that implements the Kitty graphics protocol with Unicode placeholders. " .. unused
    )
  elseif probe == "no_reply" then
    if in_tmux then
      -- Through tmux the answer often does not arrive although the images are drawn: this is not a finding.
      h.info(
        "the terminal's answer to the Kitty graphics protocol query did not arrive within 1 s. "
          .. "Through tmux that is common even when images work; if they show, ignore it. "
          .. "If they do not, see the tmux section below."
      )
    else
      h.warn(
        "the terminal did not answer the Kitty graphics protocol query within 1 s",
        "If it does implement the protocol, ignore this. " .. unused
      )
    end
  else
    h.info "no terminal is attached to this Neovim (headless?), so it could not be asked whether it speaks the Kitty graphics protocol"
  end

  -- An image is told apart by two colours on its cells: the image id in the foreground and the placement id in
  -- the underline colour.
  if vim.o.termguicolors then
    h.ok "'termguicolors' is on"
  else
    h.error(
      "'termguicolors' is off: the image id is carried in a 24-bit colour, and without it images do not show",
      "Run  :set termguicolors"
    )
  end

  if vim.o.ambiwidth == "single" then
    h.ok "'ambiwidth' is single"
  else
    h.error(
      "'ambiwidth' is "
        .. vim.o.ambiwidth
        .. ": the placeholder character U+10EEEE is ambiguous-width and would take two cells",
      "Run  :set ambiwidth=single"
    )
  end
end

-- ============================================================================
-- tmux
-- ============================================================================

local function check_tmux(h)
  h.start "render-markdown-images: tmux"

  local major, minor = parse_tmux_version(M._tmux { "-V" })
  if not major then
    h.warn("could not read the tmux version (`tmux -V`)", "Needs tmux " .. table.concat(MIN_TMUX, ".") .. " or newer")
  elseif major > MIN_TMUX[1] or (major == MIN_TMUX[1] and minor >= MIN_TMUX[2]) then
    h.ok(string.format("tmux %d.%d (>= %s)", major, minor, table.concat(MIN_TMUX, ".")))
  else
    h.error(
      string.format("tmux %d.%d is too old: `allow-passthrough` needs %s", major, minor, table.concat(MIN_TMUX, ".")),
      "Upgrade tmux"
    )
  end

  local passthrough = M._tmux { "show", "-Apv", "allow-passthrough" }
  if passthrough == "on" or passthrough == "all" then
    h.ok("allow-passthrough is " .. passthrough)
  elseif passthrough == nil then
    h.warn(
      "could not read the tmux option `allow-passthrough`",
      "Graphics sequences only reach the terminal with `set -g allow-passthrough on`"
    )
  else
    h.error(
      "allow-passthrough is "
        .. (passthrough ~= "" and passthrough or "off")
        .. ": tmux swallows the graphics sequences",
      "Add to your tmux.conf:  set -g allow-passthrough on"
    )
  end

  local features = M._tmux { "display-message", "-p", "#{client_termfeatures}" }
  if features == nil then
    h.warn "could not read the client's terminal features from tmux"
    return
  end
  local have = {}
  for _, feature in ipairs(vim.split(features, ",", { plain = true })) do
    have[feature] = true
  end
  local termname = M._tmux { "display-message", "-p", "#{client_termname}" }
  if not termname or termname == "" then termname = "xterm*" end

  -- tmux drops whichever of the two colours its client is not declared to support.
  if have.RGB then
    h.ok "tmux passes 24-bit colour (RGB) through to the terminal"
  else
    h.error(
      "tmux does not pass RGB through: the image id, which is carried in a colour, would be rounded to a palette entry and the image would not show",
      string.format("Add to your tmux.conf:  set -as terminal-features ',%s:RGB'", termname)
    )
  end
  if have.usstyle then
    h.ok "tmux passes coloured underlines (usstyle) through to the terminal"
  else
    h.error(
      "tmux does not pass underline colours through: the placement id is carried in one, so an image shown at two sizes can pick the wrong one",
      string.format("Add to your tmux.conf:  set -as terminal-features ',%s:usstyle'", termname)
    )
  end
end

-- ============================================================================
-- Tools
-- ============================================================================

local function check_tools(h, image)
  h.start "render-markdown-images: tools"
  local cfg = config()

  local function tool(name, purpose)
    if vim.fn.executable(name) == 1 then
      h.ok(name .. " found (" .. purpose .. ")")
      return true
    end
    return false
  end

  if not tool("curl", "remote images") then
    h.warn("curl not found: remote images are not downloaded", "Install curl, or register `set_download_fn()`")
  end

  -- JPEG, WebP, BMP, TIFF and SVG are converted to PNG before they can be shown; PNG is not.
  if tool("magick", "JPEG, WebP, BMP, TIFF and SVG to PNG conversion") then
    local formats = M._magick_formats()
    if formats then
      local missing = {}
      for _, name in ipairs { "JPEG", "WEBP", "BMP", "TIFF", "SVG" } do
        -- ImageMagick's own SVG renderer is listed as MSVG; a build with librsvg lists SVG.
        local reads = formats[name] or (name == "SVG" and formats.MSVG)
        if not reads then missing[#missing + 1] = name end
      end
      if #missing == 0 then
        h.ok "magick reads JPEG, WebP, BMP, TIFF and SVG"
      else
        h.warn(
          "magick cannot read " .. table.concat(missing, ", ") .. ": images of those formats are not shown",
          "Install an ImageMagick built with the libraries for them (libwebp, librsvg, ...); `magick -list format` shows what it reads"
        )
      end
    end
  else
    h.warn(
      "magick not found: JPEG, WebP, BMP, TIFF and SVG images are not shown",
      "Install ImageMagick 7 (the `magick` command; ImageMagick 6, which has only `convert`, is not used)"
    )
  end

  if not cfg.diagrams.mermaid then
    h.info "Mermaid diagrams are turned off: `diagrams.mermaid = false`"
  else
    local mermaid
    for _, name in ipairs { "mmdr", "mmdc", "npx" } do
      if vim.fn.executable(name) == 1 then
        mermaid = name
        break
      end
    end
    if mermaid then
      h.ok("Mermaid diagrams: " .. mermaid)
    else
      h.warn(
        "no Mermaid renderer found: mermaid fences stay code blocks",
        "Install mmdr or @mermaid-js/mermaid-cli (mmdc)"
      )
    end
  end

  if not cfg.diagrams.plantuml then
    h.info "PlantUML diagrams are turned off: `diagrams.plantuml = false`"
  elseif image.has_plantuml() then
    h.ok "PlantUML diagrams: a renderer is available"
  else
    h.warn(
      "no PlantUML renderer: plantuml fences stay code blocks",
      "Install `plantuml`, or set $PLANTUML_JAR to a jar, or name a server with `plantuml_server`"
    )
  end
end

-- ============================================================================
-- render-markdown
-- ============================================================================

local function check_render_markdown(h)
  h.start "render-markdown-images: render-markdown.nvim"

  local installed = pcall(require, "render-markdown")
  if not installed then
    h.error(
      "render-markdown.nvim is not installed: this plugin draws through its custom handlers",
      "Install MeanderingProgrammer/render-markdown.nvim"
    )
    return
  end
  h.ok "render-markdown.nvim is installed"

  local ok, state = pcall(require, "render-markdown.state")
  local registered = ok and state.custom_handlers or nil
  if registered == nil then
    h.warn(
      "render-markdown.nvim has not been set up yet, so its custom handlers could not be read",
      "Call `require('render-markdown').setup { custom_handlers = require('render-markdown-images').handlers() }`"
    )
  else
    local ours = require("render-markdown-images.handlers").parse
    local markdown = registered.markdown
    if type(markdown) == "table" and markdown.parse == ours then
      if markdown.extends then
        h.ok "the handler is registered for `markdown`, and extends render-markdown's own"
      else
        h.warn(
          "the handler is registered for `markdown` without `extends = true`: render-markdown's own rendering of markdown is dropped",
          "Register the table `require('render-markdown-images').handlers()` gives, unchanged"
        )
      end
    elseif type(markdown) == "table" then
      h.error(
        "render-markdown has a custom handler for `markdown` that is not this plugin's: it would draw nothing",
        "Register `custom_handlers = require('render-markdown-images').handlers()`, or call this plugin's `parse` from yours"
      )
    else
      h.error(
        "this plugin's handler is not registered with render-markdown: no image or diagram is drawn",
        "Add to the render-markdown options:  custom_handlers = require('render-markdown-images').handlers()"
      )
    end
  end

  local cfg = config()
  if cfg.images.mode == "replace" or cfg.diagrams.mode == "replace" then
    if require("render-markdown-images.handlers").can_replace() then
      h.ok "replace mode is available (Neovim 0.11+, and render-markdown draws a mark's `replace`)"
    else
      h.warn(
        '`mode = "replace"` is set, but this Neovim or this render-markdown cannot hide the source and draw its replacement: images are drawn below their source instead',
        "Needs Neovim 0.11 or newer and a recent render-markdown.nvim"
      )
    end
  end
end

-- ============================================================================
-- snacks.nvim
-- ============================================================================

--- snacks.nvim draws images in markdown documents too. With both on, each image is drawn twice. Silent when
--- snacks is not there; nothing here may fail because of it.
local function check_snacks(h)
  local ok, snacks = pcall(require, "snacks")
  if not ok or type(snacks) ~= "table" then return end
  local read, enabled, doc = pcall(function()
    local c = snacks.image and snacks.image.config
    return c and c.enabled, c and c.doc and c.doc.enabled
  end)
  if read and enabled and doc then
    h.start "render-markdown-images: snacks.nvim"
    h.warn(
      "snacks.nvim draws images in markdown documents too (`image.enabled` and `image.doc.enabled`): each image would be drawn twice",
      "Set  image = { doc = { enabled = false } }  in the snacks options"
    )
  end
end

-- ============================================================================
-- Configuration, cache and log
-- ============================================================================

local function check_files(h)
  h.start "render-markdown-images: configuration"
  local cfg = config()
  h.info(
    ("images: %s, diagrams: %s (mermaid %s, plantuml %s)"):format(
      cfg.images.mode,
      cfg.diagrams.mode,
      cfg.diagrams.mermaid and "on" or "off",
      cfg.diagrams.plantuml and "on" or "off"
    )
  )
  if cfg.plantuml_server then
    h.info("PlantUML server: " .. cfg.plantuml_server .. " (diagram source is sent there when no local renderer works)")
  end
  if not require("render-markdown-images.lifecycle").is_enabled() then
    h.warn(
      "images are switched off at run time: none is looked for or drawn",
      "Run  :RenderMarkdownImages enable  (or toggle)  to show them again"
    )
  end
  h.info("cache: " .. vim.fn.stdpath "cache" .. "/render-markdown-images")

  local log = require "render-markdown-images.log"
  local lines = log.recent()
  if #lines == 0 then
    h.ok("nothing went wrong in the background this session (log: " .. log.path() .. ")")
  else
    h.warn(
      ("%d thing%s went wrong in the background this session (log: %s)"):format(
        #lines,
        #lines == 1 and "" or "s",
        log.path()
      ),
      vim.list_slice(lines, math.max(1, #lines - 4))
    )
  end
end

function M.check()
  local h = vim.health
  local image = require "render-markdown-images.image"
  local in_tmux = image.in_tmux()

  --- One section failing is not a reason for the others to be missing.
  local function section(name, fn, ...)
    local ok, err = pcall(fn, h, ...)
    if not ok then h.error(("the %s check failed: %s"):format(name, tostring(err))) end
  end

  section("Neovim", check_neovim)
  section("terminal", check_terminal, image, in_tmux)
  if in_tmux then section("tmux", check_tmux) end
  section("tools", check_tools, image)
  section("render-markdown", check_render_markdown)
  section("snacks", check_snacks)
  section("configuration", check_files)
end

return M
