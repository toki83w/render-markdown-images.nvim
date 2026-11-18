--- Image display support for render-markdown-images.nvim.
--- Copied from the toki83w fork of delphinus/md-render.nvim (MIT); see the README's credits.
--- Uses Kitty Graphics Protocol to display images in terminal.
--- Supports PNG, JPEG, and WebP formats.
---
--- Images are drawn as Unicode placeholders only (see placeholder.lua), inside
--- tmux and out of it:
---   1. transmit_image(): send the PNG to the terminal with a=t (store, no
---      display), always through the temporary-file medium (t=t): the terminal
---      reads a temp copy, whose path holds "tty-graphics-protocol", and
---      deletes it.
---   2. create_virtual_placement(): tell the terminal how big the image is in
---      cells (a=p,U=1). Cells holding U+10EEEE, coloured with the image id
---      and placement id, then show the matching slice of it.
--- The cells are ordinary text in Neovim's grid, so scrolling, cropping and
--- repaints are Neovim's business and nothing is re-placed after them.
---
--- Nothing in here checks the terminal: having the plugin configured says it speaks the
--- protocol. `probe()` can ask, for `:checkhealth`.
---
--- Terminal output goes through `vim.api.nvim_ui_send` (Neovim >= 0.12), which
--- emits a "ui_send" event to the attached TUI. This avoids the /dev/tty open
--- dance and survives `:restart`.

local M = {}

local uv = vim.uv or vim.loop
local ffi = require "ffi"
local async = require "render-markdown-images.async"
local tty_mod = require "render-markdown-images.tty"

local IS_WINDOWS = ffi.os == "Windows"

-- ============================================================================
-- Configuration
-- ============================================================================

--- The option this module reads, `plantuml_server`, lives in `render-markdown-images.config`;
--- it is read at call time, never copied.

---@return render-markdown-images.Config
local function config()
  return require("render-markdown-images.config").get()
end

-- ============================================================================
-- Batched terminal writes
-- ============================================================================

local _batch_buffer = nil
local _batch_stack = nil

--- Whether Neovim is running inside a tmux client. Cached; tmux can't be
--- entered or left within a running session.
local _in_tmux = nil
local function in_tmux()
  if _in_tmux == nil then _in_tmux = (vim.env.TMUX ~= nil and vim.env.TMUX ~= "") end
  return _in_tmux
end

--- Wrap a terminal escape sequence in tmux's passthrough envelope so it reaches
--- the host terminal instead of being consumed by tmux. tmux requires every
--- ESC (0x1b) in the payload to be doubled, wrapped in `\ePtmux;...\e\\`.
--- Requires `set -g allow-passthrough on` in tmux (>= 3.3).
---@param data string
---@return string
local function tmux_passthrough(data)
  return "\x1bPtmux;" .. data:gsub("\x1b", "\x1b\x1b") .. "\x1b\\"
end

---@param data string
local function term_write(data)
  if data == "" then return end
  -- Everything written here is a Kitty graphics APC sequence. Inside tmux it
  -- must be wrapped for passthrough or tmux swallows it and the host terminal
  -- never sees the image. The (possibly wrapped) fragment is what gets
  -- buffered, and flush sends it raw.
  if in_tmux() then data = tmux_passthrough(data) end
  if _batch_buffer then
    table.insert(_batch_buffer, data)
    return
  end
  vim.api.nvim_ui_send(data)
end

--- Start batching terminal writes. Subsequent term_write calls accumulate
--- in memory instead of writing to the terminal immediately.
--- Supports nesting: inner batches append to the parent batch on flush.
function M.begin_batch()
  if _batch_buffer then
    -- Already batching: push current buffer onto stack
    _batch_stack = _batch_stack or {}
    table.insert(_batch_stack, _batch_buffer)
  end
  _batch_buffer = {}
end

--- Flush all accumulated terminal writes as a single write operation.
--- If nested, appends to the parent batch instead of writing to terminal.
function M.flush_batch()
  if not _batch_buffer then return end
  local data = table.concat(_batch_buffer)
  -- Pop parent batch if nested
  if _batch_stack and #_batch_stack > 0 then
    _batch_buffer = table.remove(_batch_stack)
    if data ~= "" then table.insert(_batch_buffer, data) end
  else
    _batch_buffer = nil
    -- Buffered fragments are already tmux-wrapped where needed; send raw so we
    -- don't double-wrap.
    if data ~= "" then vim.api.nvim_ui_send(data) end
  end
end

-- ============================================================================
-- Terminal cell size detection via TIOCGWINSZ
-- ============================================================================

local _ffi_declared = false
local function ensure_ffi()
  if _ffi_declared then return end
  _ffi_declared = true
  -- ioctl/winsize are POSIX-only; Windows has no equivalent in MSVCRT.
  if IS_WINDOWS then return end
  ffi.cdef [[
    typedef struct { unsigned short row; unsigned short col; unsigned short xpixel; unsigned short ypixel; } winsize;
    int ioctl(int, unsigned long, ...);
    int open(const char *path, int flags);
    int close(int fd);
  ]]
end

local TIOCGWINSZ = (vim.fn.has "mac" == 1 or vim.fn.has "bsd" == 1) and 0x40087468 or 0x5413

---@return { cell_w: number, cell_h: number }?
function M.get_cell_size()
  if M._test_cell_size then return M._test_cell_size end
  if IS_WINDOWS then return nil end
  ensure_ffi()
  local sz = ffi.new "winsize"
  -- Try stdout (fd 1) first; after :restart it may be /dev/null,
  -- so fall back to opening the discovered TTY device.
  if ffi.C.ioctl(1, TIOCGWINSZ, sz) ~= 0 then
    local tty = tty_mod.get_tty_path()
    if not tty then return nil end
    local fd = ffi.C.open(tty, 0) -- O_RDONLY
    if fd < 0 then return nil end
    local rc = ffi.C.ioctl(fd, TIOCGWINSZ, sz)
    ffi.C.close(fd)
    if rc ~= 0 then return nil end
  end
  local xpixel, ypixel = sz.xpixel, sz.ypixel
  if xpixel == 0 or ypixel == 0 then
    xpixel = sz.col * 8
    ypixel = sz.row * 16
  end
  return { cell_w = xpixel / sz.col, cell_h = ypixel / sz.row }
end

-- ============================================================================
-- Work already under way
-- ============================================================================

--- Work in flight, keyed by what it will produce.
---
--- The same image is asked for again long before the first request has
--- answered. Rebuilding the content is what does it, and that happens for
--- reasons that have nothing to do with the image: a resize reflows the text
--- (`WinResized` → live rebuild), a fold or an expandable region toggles, and
--- every burst of typing behind the live update in a split does too. Each ask
--- used to start its own work — another JVM for a PlantUML diagram, another
--- browser for a Mermaid one — and for a download, another curl writing over
--- the file the first curl had not finished writing.
---@type table<string, vim.async.Task>
local _in_flight = {}

--- Do `produce` for `key`, or join the run already under way, and answer
--- `callback` either way.
---
--- A task is a value: whoever asks second awaits the first one's rather than
--- starting its own, and both get the same answer. `produce` runs once.
---@param key string what the work will produce, usually the file's path
---@param produce async fun(): ... the work, run only if nobody else is on it
---@param callback fun(...) given whatever `produce` returned, or nothing on failure
local function shared_work(key, produce, callback)
  local task = _in_flight[key]
  if not task then
    task = async.run(produce)
    _in_flight[key] = task
    -- Release the key once the work is done, so a later ask — a retry after a
    -- failure, or a source file that changed — is allowed to try again.
    task:on_complete(function()
      _in_flight[key] = nil
    end)
  end

  async.run(function()
    local answer = vim.F.pack_len(async.pawait(task))
    if answer[1] then
      callback(unpack(answer, 2, answer.n))
    else
      callback(nil)
    end
  end)
end

-- ============================================================================
-- Image dimension detection from file headers
-- ============================================================================

local function read_header(path, n)
  local f = io.open(path, "rb")
  if not f then return nil end
  local data = f:read(n)
  f:close()
  return data
end

local function be16(s, o)
  return s:byte(o) * 256 + s:byte(o + 1)
end
local function be32(s, o)
  return s:byte(o) * 16777216 + s:byte(o + 1) * 65536 + s:byte(o + 2) * 256 + s:byte(o + 3)
end
local function le16(s, o)
  return s:byte(o) + s:byte(o + 1) * 256
end
local function le24(s, o)
  return s:byte(o) + s:byte(o + 1) * 256 + s:byte(o + 2) * 65536
end

local function png_dimensions(path)
  local h = read_header(path, 24)
  if not h or #h < 24 or h:sub(1, 4) ~= "\137PNG" then return nil end
  return be32(h, 17), be32(h, 21)
end

local function jpeg_dimensions(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local data = f:read "*a"
  f:close()
  if not data or #data < 2 or data:byte(1) ~= 0xFF or data:byte(2) ~= 0xD8 then return nil end
  local pos = 3
  while pos < #data - 1 do
    if data:byte(pos) ~= 0xFF then
      pos = pos + 1
      goto continue
    end
    local marker = data:byte(pos + 1)
    if marker >= 0xC0 and marker <= 0xCF and marker ~= 0xC4 and marker ~= 0xC8 then
      if pos + 9 <= #data then return be16(data, pos + 7), be16(data, pos + 5) end
    end
    if pos + 3 <= #data then
      pos = pos + 2 + be16(data, pos + 2)
    else
      break
    end
    ::continue::
  end
  return nil
end

local function webp_dimensions(path)
  local h = read_header(path, 30)
  if not h or #h < 16 or h:sub(1, 4) ~= "RIFF" or h:sub(9, 12) ~= "WEBP" then return nil end
  local chunk_type = h:sub(13, 16)
  if chunk_type == "VP8 " and #h >= 30 then
    if h:byte(24) == 0x9D and h:byte(25) == 0x01 and h:byte(26) == 0x2A then
      return bit.band(le16(h, 27), 0x3FFF), bit.band(le16(h, 29), 0x3FFF)
    end
  elseif chunk_type == "VP8L" and #h >= 26 then
    if h:byte(22) == 0x2F then
      local b = le16(h, 23) + le16(h, 25) * 65536
      return bit.band(b, 0x3FFF) + 1, bit.band(bit.rshift(b, 14), 0x3FFF) + 1
    end
  elseif chunk_type == "VP8X" and #h >= 30 then
    return le24(h, 25) + 1, le24(h, 28) + 1
  end
  return nil
end

---@param path string
---@return integer? width, integer? height
function M.image_dimensions(path)
  local h = read_header(path, 4)
  if not h then return nil end
  if h:sub(1, 4) == "\137PNG" then return png_dimensions(path) end
  if h:byte(1) == 0xFF and h:byte(2) == 0xD8 then return jpeg_dimensions(path) end
  if h:sub(1, 4) == "RIFF" then return webp_dimensions(path) end
  return nil
end

--- Extensions of formats this plugin cannot display: GIF and video.
local UNSUPPORTED_EXTENSIONS = {
  gif = true,
  mp4 = true,
  webm = true,
  mov = true,
  avi = true,
  mkv = true,
  m4v = true,
}

--- Whether a path or URL names a format this plugin does not display.
---
--- A local file of such a format already fails `image_dimensions`, but a URL
--- is not looked at until it has been downloaded. Going by the extension lets a
--- link to a GIF or a video be skipped from the start instead of being fetched
--- only to be rejected.
---@param path string
---@return boolean
function M.is_unsupported_format(path)
  local ext = path:gsub("[?#].*$", ""):match "%.(%w+)$"
  return ext ~= nil and UNSUPPORTED_EXTENSIONS[ext:lower()] == true
end

-- ============================================================================
-- Mermaid diagram rendering
-- ============================================================================

--- Get cache directory for rendered mermaid diagrams
---@return string
local function get_mermaid_cache_dir()
  local dir = vim.fn.stdpath "cache" .. "/render-markdown-images/mermaid"
  vim.fn.mkdir(dir, "p")
  return dir
end

--- Find the mmdc executable (mermaid CLI).
--- Searches PATH first, then falls back to npx.
---@return string[]? command prefix (e.g. {"mmdc"} or {"npx", "-y", "@mermaid-js/mermaid-cli"})
local _mmdc_cmd = nil
local _mmdc_checked = false

local function find_mmdc()
  if _mmdc_checked then return _mmdc_cmd end
  _mmdc_checked = true
  -- Prefer mmdr (native Rust renderer): no browser/Node, starts in ms, so it
  -- never hits the 30s render timeout the npx fallback can. Its CLI differs
  -- from mmdc's; build_mmdc_cmd() branches on the renderer name below.
  if vim.fn.executable "mmdr" == 1 then
    _mmdc_cmd = { "mmdr" }
  elseif vim.fn.executable "mmdc" == 1 then
    _mmdc_cmd = { "mmdc" }
  elseif vim.fn.executable "npx" == 1 then
    _mmdc_cmd = { "npx", "-y", "@mermaid-js/mermaid-cli" }
  end
  return _mmdc_cmd
end

--- Check if mermaid rendering is available
---@return boolean
function M.has_mmdc()
  return find_mmdc() ~= nil
end

--- Detect whether Neovim is using a dark or light background and return
--- the appropriate mermaid theme name and background color hex string.
---@return string theme, string bg_hex
local function mermaid_theme_args()
  local bg = vim.o.background -- "dark" or "light"
  local hl = vim.api.nvim_get_hl(0, { name = "NormalFloat", link = false })
  if not hl.bg then hl = vim.api.nvim_get_hl(0, { name = "Normal", link = false }) end
  local bg_color = hl.bg
  if bg == "dark" then
    local hex = bg_color and string.format("#%06x", bg_color) or "#1e1e2e"
    return "dark", hex
  else
    local hex = bg_color and string.format("#%06x", bg_color) or "#ffffff"
    return "default", hex
  end
end

--- Supersampling factor for mermaid diagrams, matching mermaid-cli's `-s 2`.
--- Applied for the mmdr renderer, which otherwise renders at natural size.
--- Part of the cache key so changing it invalidates previously cached PNGs.
local MERMAID_SCALE = 2

--- Compute cache path for mermaid source (includes theme and scale in hash).
---@param source string
---@return string
local function mermaid_cache_path(source)
  local theme, bg_hex = mermaid_theme_args()
  local key = source .. "|" .. theme .. "|" .. bg_hex .. "|s" .. MERMAID_SCALE
  local hash = vim.fn.sha256(key):sub(1, 16)
  return get_mermaid_cache_dir() .. "/" .. hash .. ".png"
end

--- Build the renderer command arguments with theme-aware colors.
---
--- Supports two CLIs:
---   * mmdc (mermaid-cli): -t <theme> -b <bg> -s <scale>
---   * mmdr (native Rust): -e png -t <theme>, background via a -c config file
---     (mmdr has no -b/-s flags).
---@param cmd_prefix string[]
---@param input_path string
---@param output_path string
---@return string[]
local function build_mmdc_cmd(cmd_prefix, input_path, output_path)
  local theme, bg_hex = mermaid_theme_args()
  local cmd = vim.list_extend({}, cmd_prefix)

  if cmd_prefix[1] == "mmdr" then
    -- mmdr defaults to SVG and takes the background through a config file.
    local cfg_path = vim.fn.tempname() .. ".json"
    local f = io.open(cfg_path, "w")
    if f then
      f:write(string.format('{"themeVariables":{"background":%q}}', bg_hex))
      f:close()
    end

    vim.list_extend(cmd, {
      "-i",
      input_path,
      "-o",
      output_path,
      "-e",
      "png",
      "-t",
      theme,
    })
    if f then vim.list_extend(cmd, { "-c", cfg_path }) end

    -- mmdc rendered at -s 2 (2x supersampling) for crisp output. mmdr has no
    -- scale flag; it renders at the diagram's natural pixel size, which is
    -- small and looks blurry once scaled up into terminal cells. Query the
    -- natural size and render at MERMAID_SCALE x both dimensions to match.
    -- Passing only -w distorts the aspect ratio (mmdr defaults the other axis),
    -- so we always pass both -w and -H.
    local size_cmd = { "mmdr", "-i", input_path, "-e", "png", "-t", theme, "--size" }
    if f then vim.list_extend(size_cmd, { "-c", cfg_path }) end
    local ok, res = pcall(function()
      return vim.system(size_cmd, { text = true }):wait()
    end)
    if ok and res and res.code == 0 and res.stdout then
      local nat_w = tonumber(res.stdout:match '"width"%s*:%s*([%d%.]+)')
      local nat_h = tonumber(res.stdout:match '"height"%s*:%s*([%d%.]+)')
      if nat_w and nat_h and nat_w > 0 and nat_h > 0 then
        local w = math.floor(nat_w * MERMAID_SCALE + 0.5)
        local h = math.floor(nat_h * MERMAID_SCALE + 0.5)
        vim.list_extend(cmd, { "-w", tostring(w), "-H", tostring(h) })
      end
    end
    -- If the size query failed we fall back to natural size (still renders,
    -- just not supersampled).
    return cmd
  end

  -- mmdc / npx-mermaid-cli
  vim.list_extend(cmd, {
    "-i",
    input_path,
    "-o",
    output_path,
    "-t",
    theme,
    "-b",
    bg_hex,
    "-s",
    "2",
  })
  return cmd
end

--- Check if a mermaid diagram is already cached (no rendering).
---@param source string mermaid diagram source code
---@return string? cached_path
function M.get_mermaid_cached(source)
  local cache_path = mermaid_cache_path(source)
  if vim.fn.filereadable(cache_path) == 1 then return cache_path end
  return nil
end

--- Render mermaid source code to a PNG image (synchronous, cached).
---@param source string mermaid diagram source code
---@return string? png_path
function M.render_mermaid(source)
  local cmd_prefix = find_mmdc()
  if not cmd_prefix then return nil end

  local cache_path = mermaid_cache_path(source)
  if vim.fn.filereadable(cache_path) == 1 then return cache_path end

  local tmp_input = vim.fn.tempname() .. ".mmd"
  local f = io.open(tmp_input, "w")
  if not f then return nil end
  f:write(source)
  f:close()

  local cmd = build_mmdc_cmd(cmd_prefix, tmp_input, cache_path)
  vim.system(cmd, { text = true, timeout = 30000 }):wait()
  os.remove(tmp_input)

  if vim.fn.filereadable(cache_path) == 1 then return cache_path end
  return nil
end

--- Render mermaid source code to a PNG image (asynchronous, cached).
---@param source string mermaid diagram source code
---@param callback fun(png_path: string?)
function M.render_mermaid_async(source, callback)
  local cmd_prefix = find_mmdc()
  if not cmd_prefix then
    callback(nil)
    return
  end

  local cache_path = mermaid_cache_path(source)
  if vim.fn.filereadable(cache_path) == 1 then
    callback(cache_path)
    return
  end

  shared_work(cache_path, function()
    local tmp_input = vim.fn.tempname() .. ".mmd"
    local f = io.open(tmp_input, "w")
    if not f then return nil end
    f:write(source)
    f:close()

    async.system(build_mmdc_cmd(cmd_prefix, tmp_input, cache_path), { text = true, timeout = 30000 })
    os.remove(tmp_input)
    return vim.fn.filereadable(cache_path) == 1 and cache_path or nil
  end, callback)
end

-- ============================================================================
-- PlantUML diagram rendering
-- ============================================================================

--- Get cache directory for rendered PlantUML diagrams
---@return string
local function get_plantuml_cache_dir()
  local dir = vim.fn.stdpath "cache" .. "/render-markdown-images/plantuml"
  vim.fn.mkdir(dir, "p")
  return dir
end

--- Hex-encode a diagram source for PlantUML's "~h" URL scheme.
--- The server also accepts deflate+custom-base64, but that needs a compression
--- library; the hex scheme trades a longer URL for zero dependencies.
---@param source string
---@return string hex digits, without the "~h" prefix
local function plantuml_encode_hex(source)
  local parts = {}
  for i = 1, #source do
    parts[i] = string.format("%02x", source:byte(i))
  end
  return table.concat(parts)
end

--- Exposed for testing.
---@param source string
---@return string
function M._plantuml_encode_hex(source)
  return plantuml_encode_hex(source)
end

--- Find a local PlantUML renderer.
--- Prefers a `plantuml` wrapper on PATH; otherwise uses `java -jar` only when
--- PLANTUML_JAR explicitly points at a readable jar.
---@return string[]? command prefix
local _plantuml_cmd = nil
local _plantuml_checked = false

local function find_plantuml()
  if _plantuml_checked then return _plantuml_cmd end
  _plantuml_checked = true
  if vim.fn.executable "plantuml" == 1 then
    _plantuml_cmd = { "plantuml" }
  elseif vim.fn.executable "java" == 1 and vim.env.PLANTUML_JAR and vim.fn.filereadable(vim.env.PLANTUML_JAR) == 1 then
    _plantuml_cmd = { "java", "-jar", vim.env.PLANTUML_JAR }
  end
  return _plantuml_cmd
end

--- Check if PlantUML rendering is available, locally or via a configured
--- server. Network availability can't be cheaply probed, so a server plus
--- curl counts as viable without asking whether it answers.
---@return boolean
function M.has_plantuml()
  if find_plantuml() ~= nil then return true end
  return config().plantuml_server ~= nil and vim.fn.executable "curl" == 1
end

--- Compute cache path for PlantUML source.
--- Hashes source only: unlike mermaid's -t/-b flags, nothing here varies the
--- output by theme or background.
---@param source string
---@return string
local function plantuml_cache_path(source)
  local hash = vim.fn.sha256(source):sub(1, 16)
  return get_plantuml_cache_dir() .. "/" .. hash .. ".png"
end

--- Check if a PlantUML diagram is already cached (no rendering).
---@param source string PlantUML diagram source code
---@return string? cached_path
function M.get_plantuml_cached(source)
  local cache_path = plantuml_cache_path(source)
  if vim.fn.filereadable(cache_path) == 1 then return cache_path end
  return nil
end

--- Render PlantUML source via a remote HTTP server.
---
--- Only ever reached when the user has named a server: a diagram is the
--- document, and sending it somewhere is not a fallback this plugin will pick
--- on its own. Without a local renderer and without a server, a `plantuml`
--- fence stays a code block — which is what a `mermaid` fence does without
--- `mmdc`.
---@async
---@param source string
---@param cache_path string
---@return string? png_path
local function render_plantuml_remote(source, cache_path)
  local server = config().plantuml_server
  if not server or vim.fn.executable "curl" ~= 1 then return nil end
  local url = server:gsub("/+$", "") .. "/png/~h" .. plantuml_encode_hex(source)
  local cmd = { "curl", "-sfL", "--max-time", "15", "--max-filesize", "20000000", "-o", cache_path, url }
  async.system(cmd, { text = true })
  if vim.fn.filereadable(cache_path) == 1 then return cache_path end
  os.remove(cache_path)
  return nil
end

--- Render PlantUML source code to a PNG image (asynchronous, cached).
--- Tries a local renderer first, and falls back to a server only when the user
--- has named one — see `M.setup`.
---@param source string PlantUML diagram source code
---@param callback fun(png_path: string?)
function M.render_plantuml_async(source, callback)
  local cache_path = plantuml_cache_path(source)
  if vim.fn.filereadable(cache_path) == 1 then
    callback(cache_path)
    return
  end

  shared_work(cache_path, function()
    local cmd_prefix = find_plantuml()
    if not cmd_prefix then return render_plantuml_remote(source, cache_path) end

    local cmd = vim.list_extend(vim.list_extend({}, cmd_prefix), { "-tpng", "-pipe" })
    local result = async.system(cmd, { stdin = source, text = false, timeout = 30000 })
    if result.stdout and #result.stdout > 0 then
      local f = io.open(cache_path, "wb")
      if f then
        f:write(result.stdout)
        f:close()
      end
    end
    if vim.fn.filereadable(cache_path) == 1 then return cache_path end
    return render_plantuml_remote(source, cache_path)
  end, callback)
end

--- Check if file is a format the terminal can display directly (no conversion needed)
---@param path string
---@return boolean
function M.is_native_format(path)
  local h = read_header(path, 4)
  if not h then return false end
  -- Only PNG is natively supported by Kitty graphics protocol (f=100).
  -- Every other format has to be converted to PNG before transmission.
  return h:sub(1, 4) == "\137PNG"
end

-- ============================================================================
-- Kitty Graphics Protocol support detection
-- ============================================================================

-- Mutable module state hoisted here so M.reset_cache() (defined below, before the
-- sections that use these) resolves to the same upvalues. Declaring them only in
-- the later sections left reset_cache() writing to accidental globals instead.
local _convert_cmd = nil
local _convert_checked = false
local _image_id = 100
local _session_cleared = false

--- Send `payload` to the terminal and call `on_response(sequence)` for every
--- `TermResponse` until it returns true or `opts.timeout` ms (default 1000)
--- pass; `opts.on_timeout` is called in the second case. Returns the id of the
--- `TermResponse` autocommand.
---
--- Neovim >= 0.13 has this as `vim.tty.request`. Neovim 0.12 does not, so this
--- is the same contract on top of what 0.12 offers (the way its own
--- `vim.tty.query` is written). `vim.tty.query_apc` is no substitute: it only
--- passes APC replies on, and the probe needs to see the DA1 reply as well.
---@param payload string
---@param opts { timeout?: integer, on_timeout?: fun() }
---@param on_response fun(sequence: string): boolean?
---@return integer
local function tty_request(payload, opts, on_response)
  local has_tty, tty = pcall(require, "vim.tty")
  if has_tty and type(tty) == "table" and type(tty.request) == "function" then
    return tty.request(payload, opts, on_response)
  end

  local timer = assert(uv.new_timer())
  local id = vim.api.nvim_create_autocmd("TermResponse", {
    nested = true,
    callback = function(ev)
      local sequence = ev.data and ev.data.sequence
      if type(sequence) ~= "string" then return end
      local stop = on_response(sequence)
      -- Done: the timeout must not fire on top of an answer.
      if stop and not timer:is_closing() then timer:close() end
      return stop
    end,
  })
  vim.api.nvim_ui_send(payload)
  timer:start(opts.timeout or 1000, 0, function()
    vim.schedule(function()
      pcall(vim.api.nvim_del_autocmd, id)
      if opts.on_timeout then opts.on_timeout() end
    end)
    if not timer:is_closing() then timer:close() end
  end)
  return id
end

--- The question put to the terminal: "do you speak the Kitty graphics
--- protocol?", as a query (`a=q`) about a 1x1 RGB pixel, which is answered and
--- never drawn. A terminal that does answers `ESC _ G i=31 ; OK ESC \`.
local PROBE_ID = 31
local PROBE_QUERY = "\x1b_Gi=" .. PROBE_ID .. ",s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\"

--- Primary Device Attributes, asked right behind the query. Every terminal
--- answers it, so a terminal that does not know the graphics protocol is told
--- apart from a slow one: its DA1 answer arrives, and the graphics one does not
--- come before it.
local DA1_QUERY = "\x1b[c"

local PROBE_TIMEOUT_MS = 1000
local _probe_timeout_ms = PROBE_TIMEOUT_MS

---@alias render-markdown-images.ProbeResult
---| "ok" the terminal answered the graphics query
---| "no_reply" nothing arrived in time
---| "da1_first" the DA1 answer came first: the terminal does not know the protocol
---| "not_asked" no question was put (it is not needed, or no terminal is attached)

---@type render-markdown-images.ProbeResult
local _probe_result = "not_asked"
-- A question is out, and what came of it so far (nil: nothing yet).
local _probing = false
---@type render-markdown-images.ProbeResult?
local _probe_answer = nil

---@param sequence string
---@return boolean
local function is_probe_answer(sequence)
  local control, status = sequence:match "^\x1b_G([^;\x1b]*);([^\x1b]*)"
  return control ~= nil and status == "OK" and ("," .. control .. ","):find(",i=" .. PROBE_ID .. ",", 1, true) ~= nil
end

---@param sequence string
---@return boolean
local function is_da1_answer(sequence)
  return sequence:match "^\x1b%[%?[%d;:]*c" ~= nil
end

--- Ask the terminal whether it speaks the Kitty graphics protocol. Blocks until
--- it has answered or `_probe_timeout_ms` has passed. The answer is kept for
--- the session, except "not_asked".
---
--- Rendering never calls this: it is for `:checkhealth`. Through tmux the answer may
--- not arrive although the terminal would draw the images.
---
--- Inside tmux the query is wrapped for passthrough so that it reaches the
--- outer terminal, and DA1 is not asked: tmux answers that itself, before the
--- outer terminal could, so it says nothing about the terminal.
---@return render-markdown-images.ProbeResult
function M.probe()
  if _probe_result ~= "not_asked" then return _probe_result end
  -- A scheduled callback run by the wait below may ask as well: share the
  -- answer. It waits for the answer, not for the end of the question, which
  -- cannot come before this call returns.
  if _probing then
    vim.wait(_probe_timeout_ms + 500, function()
      return _probe_answer ~= nil
    end, 10)
    return _probe_answer or "not_asked"
  end
  -- Nobody to ask (headless, or a server nobody is attached to). Not stored: a
  -- UI may attach later.
  if #vim.api.nvim_list_uis() == 0 then return "not_asked" end

  local tmux = in_tmux()
  _probing = true
  _probe_answer = nil
  local id = tty_request(tmux and tmux_passthrough(PROBE_QUERY) or (PROBE_QUERY .. DA1_QUERY), {
    timeout = _probe_timeout_ms,
    on_timeout = function()
      _probe_answer = _probe_answer or "no_reply"
    end,
  }, function(sequence)
    if is_probe_answer(sequence) then
      _probe_answer = "ok"
      return true
    end
    if not tmux and is_da1_answer(sequence) then
      _probe_answer = "da1_first"
      return true
    end
  end)

  -- `vim.wait` is refused where Neovim cannot run its event loop (a libuv
  -- callback): then there is no way to ask now, and nothing is stored.
  local waited = pcall(vim.wait, _probe_timeout_ms + 500, function()
    return _probe_answer ~= nil
  end, 10)
  _probing = false
  if _probe_answer == nil then pcall(vim.api.nvim_del_autocmd, id) end
  if not waited then return "not_asked" end
  _probe_result = _probe_answer or "no_reply"
  return _probe_result
end

--- What the terminal said to the graphics query, for `:checkhealth`.
---@return render-markdown-images.ProbeResult
function M.probe_result()
  return _probe_result
end

--- Whether Neovim is running inside tmux.
---@return boolean
function M.in_tmux()
  return in_tmux()
end

function M.reset_cache()
  _in_tmux = nil
  _probe_result = "not_asked"
  _probing = false
  _probe_answer = nil
  _probe_timeout_ms = PROBE_TIMEOUT_MS
  _session_cleared = false
  _convert_cmd = nil
  _convert_checked = false
  _plantuml_cmd = nil
  _plantuml_checked = false
  _mmdc_cmd = nil
  _mmdc_checked = false
  tty_mod.reset()
end

--- Override tmux detection for testing. `nil` goes back to reading `$TMUX`.
---@param val boolean?
function M._set_in_tmux(val)
  _in_tmux = val
end

--- Shorten (or lengthen) the wait for the terminal's answer, for testing.
--- `reset_cache()` puts it back.
---@param ms integer
function M._set_probe_timeout(ms)
  _probe_timeout_ms = ms
end

--- Reset image ID counter for testing.
function M._reset_image_id()
  _image_id = 100
end

-- ============================================================================
-- URL detection and download with cache
-- ============================================================================

--- Custom download function for authenticated or special URL handling.
--- Signature: fn(url, output_path, callback) -> handled
---   - url: the image URL to download
---   - output_path: absolute path where the image file should be saved
---   - callback: fun(ok: boolean) — call with true on success, false on failure
---   - return true if this function handles the URL (callback will be called later)
---   - return false to fall back to the default curl downloader
---@type fun(url: string, output_path: string, callback: fun(ok: boolean)): boolean
local _custom_download_fn = nil

--- Register a custom download function for URL images.
--- The function is called before the default curl downloader. If it returns
--- true, it is expected to handle the download and call the callback. If it
--- returns false, the default curl-based downloader is used as a fallback.
---@param fn fun(url: string, output_path: string, callback: fun(ok: boolean)): boolean
function M.set_download_fn(fn)
  _custom_download_fn = fn
end

--- Check if a string is an HTTP(S) URL
---@param s string
---@return boolean
function M.is_url(s)
  return s:match "^https?://" ~= nil
end

--- URLs that are badges or tiny icons — not worth displaying as block images
local BADGE_PATTERNS = {
  "img%.shields%.io",
  "badge%.fury%.io",
  "badgen%.net",
  "badges%.gitter%.im",
  "coveralls%.io/repos",
  "travis%-ci%.org",
  "ci%.appveyor%.com",
  "codecov%.io",
  "scan%.coverity%.com",
  "repology%.org/badge",
  "badges%.debian%.net",
  "github%.com/.*badge",
  "github%.com/.*/workflows/.*/badge",
  "img%.shields%.io",
  "flat%-square",
  "for%-the%-badge",
}

--- Check if a URL looks like a badge/shield image
---@param url string
---@return boolean
function M.is_badge_url(url)
  for _, pat in ipairs(BADGE_PATTERNS) do
    if url:match(pat) then return true end
  end
  return false
end

-- In-memory cache: URL -> local file path
local _url_cache = {}

--- Get cache directory for downloaded images
---@return string
local function get_cache_dir()
  local dir = vim.fn.stdpath "cache" .. "/render-markdown-images/images"
  vim.fn.mkdir(dir, "p")
  return dir
end

--- Generate a cache filename from a URL
---@param url string
---@return string
local function url_to_cache_path(url)
  -- Use a hash of the URL as filename, preserve extension
  local hash = vim.fn.sha256(url):sub(1, 16)
  local ext = url:match "%.(%w+)$" or "png"
  -- Clean extension (remove query params)
  ext = ext:match "^(%w+)" or "png"
  return get_cache_dir() .. "/" .. hash .. "." .. ext
end

--- Check if a URL is already cached (in-memory or on disk).
---@param url string
---@return string? cached_path
function M.get_cached(url)
  if _url_cache[url] and vim.fn.filereadable(_url_cache[url]) == 1 then
    -- Validate cached file is a recognized image format
    if M.image_dimensions(_url_cache[url]) then return _url_cache[url] end
    -- Stale/corrupt cache entry: remove file and clear in-memory cache
    os.remove(_url_cache[url])
    _url_cache[url] = nil
    return nil
  end
  local cache_path = url_to_cache_path(url)
  if vim.fn.filereadable(cache_path) == 1 then
    -- Validate cached file is a recognized image format
    if M.image_dimensions(cache_path) then
      _url_cache[url] = cache_path
      return cache_path
    end
    -- Stale/corrupt cache file: remove it
    os.remove(cache_path)
    return nil
  end
  return nil
end

--- Validate a downloaded file and update cache.
---@param url string
---@param cache_path string
---@return string? path  nil when the download is not usable
local function finalize_download(url, cache_path)
  if vim.fn.filereadable(cache_path) == 1 and M.image_dimensions(cache_path) then
    _url_cache[url] = cache_path
    return cache_path
  end
  os.remove(cache_path)
  return nil
end

--- Offer the download to the user's `set_download_fn`, if one is registered.
---
--- That function answers twice: it returns whether it took the job, and calls
--- back with the outcome if it did. A user's function is free to call back
--- before it returns, so reading `taken` after the await is only sound because
--- `vim.async` queues the resume rather than running it from inside the
--- callback. 0.12's `vim._async` did resume inline, which is one of the reasons
--- the plugin carries a copy of `vim.async` for it.
---@async
---@param url string
---@param cache_path string
---@return boolean taken  whether the user's function took the job
---@return boolean ok  what it reported; meaningless when `taken` is false
local function custom_download(url, cache_path)
  if not _custom_download_fn then return false, false end
  local taken = false
  local ok = async.await(1, function(callback)
    taken = _custom_download_fn(url, cache_path, callback)
    if not taken then callback(false) end
  end)
  return taken, ok
end

--- Download a URL to a local file asynchronously.
---@param url string
---@param callback fun(path: string?)  called with local path on success, nil on failure
function M.download_async(url, callback)
  if M.is_badge_url(url) then
    callback(nil)
    return
  end

  local cached = M.get_cached(url)
  if cached then
    callback(cached)
    return
  end

  local cache_path = url_to_cache_path(url)

  shared_work(cache_path, function()
    -- Try custom download function first (e.g. for authenticated GitHub Enterprise URLs)
    local taken, ok = custom_download(url, cache_path)
    if taken then
      if not ok then return nil end
      return finalize_download(url, cache_path)
    end

    -- Default: download with curl
    -- The URL comes out of a document, so what it may lead to is limited: http(s) only, redirects included.
    local cmd = {
      "curl",
      "-sfL",
      "--proto",
      "=http,https",
      "--proto-redir",
      "=http,https",
      "--max-time",
      "10",
      "--max-filesize",
      "20000000",
      "-o",
      cache_path,
      url,
    }
    if async.system(cmd, { text = true }).code ~= 0 then
      os.remove(cache_path)
      return nil
    end
    return finalize_download(url, cache_path)
  end, callback)
end

--- Resolve an image source to a local file path (cache-only for URLs).
--- For URLs: returns cached path or nil (no download).
--- For local files: resolves path immediately.
---@param src string  image source (URL or path)
---@param base_dir? string  base directory for resolving relative paths
---@return string? resolved_path
function M.resolve(src, base_dir)
  if M.is_url(src) then
    if M.is_badge_url(src) then return nil end
    return M.get_cached(src)
  end

  local resolved = vim.fn.expand(src)
  if resolved:sub(1, 1) ~= "/" and base_dir then resolved = base_dir .. "/" .. resolved end

  if vim.fn.filereadable(resolved) == 1 then return resolved end

  -- Fallback: try Obsidian vault resolution
  if base_dir then
    local obsidian = require "render-markdown-images.obsidian"
    local vault_resolved = obsidian.resolve(src, base_dir)
    if vault_resolved then return vault_resolved end
  end

  return nil
end

-- ============================================================================
-- Image conversion tool detection
-- ============================================================================

--- Detect the best available tool for static image conversion (JPEG/WebP → PNG).
--- Priority: sips (macOS) → ffmpeg → magick
---@return string? tool  "sips", "ffmpeg", or "magick"
local function find_convert_tool()
  if _convert_checked then return _convert_cmd end
  _convert_checked = true
  if vim.fn.has "mac" == 1 and vim.fn.executable "sips" == 1 then
    _convert_cmd = "sips"
  elseif vim.fn.executable "ffmpeg" == 1 then
    _convert_cmd = "ffmpeg"
  elseif vim.fn.executable "magick" == 1 then
    _convert_cmd = "magick"
  end
  return _convert_cmd
end

--- Maximum dimension (in pixels) for converted PNG output.
--- Larger source images are downscaled to fit within this bound.
local MAX_CONVERT_DIM = 2000

--- Build a command to convert a static image to PNG with resize.
---@param tool string  "sips", "ffmpeg", or "magick"
---@param src string  input file path
---@param dst string  output PNG path
---@return string[]
local function build_convert_cmd(tool, src, dst)
  local dim = tostring(MAX_CONVERT_DIM)
  if tool == "sips" then
    -- -Z resizes only if the image is larger than the specified dimension
    return { "sips", "-s", "format", "png", "-Z", dim, src, "--out", dst }
  elseif tool == "ffmpeg" then
    -- scale filter with force_original_aspect_ratio keeps aspect ratio;
    -- -vframes 1 ensures only one frame for static images
    return {
      "ffmpeg",
      "-y",
      "-i",
      src,
      "-vframes",
      "1",
      "-vf",
      "scale='min(" .. dim .. ",iw)':'min(" .. dim .. ",ih)':force_original_aspect_ratio=decrease",
      dst,
    }
  else
    return { "magick", src, "-resize", dim .. "x" .. dim .. ">", dst }
  end
end

-- ============================================================================
-- Image conversion
-- ============================================================================

--- Get cache directory for converted PNGs (JPEG/WebP → PNG).
---@return string
local function get_converted_cache_dir()
  local dir = vim.fn.stdpath "cache" .. "/render-markdown-images/converted"
  vim.fn.mkdir(dir, "p")
  return dir
end

--- Build a stable cache path for a converted PNG.
--- Includes mtime so updates to the source invalidate the cache automatically,
--- and MAX_CONVERT_DIM so changing the resize bound creates a separate entry.
---@param src_path string  absolute path to the source image
---@return string? cache_path  nil if mtime cannot be read
local function get_converted_cache_path(src_path)
  local mtime = vim.fn.getftime(src_path)
  if mtime < 0 then return nil end
  local hash = vim.fn.sha256(src_path):sub(1, 16)
  return string.format("%s/%s_%d_%d.png", get_converted_cache_dir(), hash, mtime, MAX_CONVERT_DIM)
end

--- Atomically install a freshly converted PNG into the cache.
--- Renames tmp → cache_path; on collision (race), keeps the existing cache file.
---@param tmp string
---@param cache_path string
---@return boolean ok
local function install_to_cache(tmp, cache_path)
  if vim.fn.filereadable(cache_path) == 1 then
    os.remove(tmp)
    return true
  end
  local ok = uv.fs_rename(tmp, cache_path)
  if not ok then
    -- Rename failed (e.g. cross-device); fall back to copy + unlink
    local data
    local f = io.open(tmp, "rb")
    if f then
      data = f:read "*a"
      f:close()
    end
    if not data then return false end
    local out = io.open(cache_path, "wb")
    if not out then return false end
    out:write(data)
    out:close()
    os.remove(tmp)
  end
  return true
end

--- Ensure image is in a format the terminal can display natively (synchronous).
--- PNG is passed through. JPEG/WebP are converted to PNG and cached
--- on disk so subsequent calls for the same source skip re-conversion.
---@param path string
---@return string? png_path, boolean is_temp
function M.ensure_png(path)
  if M.is_native_format(path) then return path, false end
  local tool = find_convert_tool()
  if not tool then return nil, false end
  local cache_path = get_converted_cache_path(path)
  if cache_path and vim.fn.filereadable(cache_path) == 1 then return cache_path, false end
  local tmp = vim.fn.tempname() .. ".png"
  local result = vim.system(build_convert_cmd(tool, path, tmp), { text = true }):wait()
  if result.code ~= 0 then return nil, false end
  if cache_path and install_to_cache(tmp, cache_path) then return cache_path, false end
  return tmp, true
end

--- Ensure image is in a native format (asynchronous).
---@param path string
---@param callback fun(png_path: string?, is_temp: boolean)
function M.ensure_png_async(path, callback)
  if M.is_native_format(path) then
    callback(path, false)
    return
  end
  local tool = find_convert_tool()
  if not tool then
    callback(nil, false)
    return
  end
  local cache_path = get_converted_cache_path(path)
  if cache_path and vim.fn.filereadable(cache_path) == 1 then
    callback(cache_path, false)
    return
  end
  local tmp = vim.fn.tempname() .. ".png"
  async.run(function()
    if async.system(build_convert_cmd(tool, path, tmp), { text = true }).code ~= 0 then
      callback(nil, false)
      return
    end
    if cache_path and install_to_cache(tmp, cache_path) then
      callback(cache_path, false)
    else
      callback(tmp, true)
    end
  end)
end

--- Choose the rounding direction (floor vs ceil) for the dependent dimension
--- that best preserves the original pixel aspect ratio.
---@param fixed_cells integer  the already-determined cell count (cols or rows)
---@param fixed_cell_px number  pixel size of the fixed dimension's cell
---@param dep_px number  target pixel size of the dependent dimension
---@param dep_cell_px number  pixel size of the dependent dimension's cell
---@param dep_max integer  upper bound for the dependent cell count
---@param img_w integer  original image width
---@param img_h integer  original image height
---@param fixed_is_cols boolean  true when fixed dimension is columns
---@return integer
local function best_round(fixed_cells, fixed_cell_px, dep_px, dep_cell_px, dep_max, img_w, img_h, fixed_is_cols)
  local r_floor = math.max(1, math.floor(dep_px / dep_cell_px))
  local r_ceil = math.min(dep_max, math.ceil(dep_px / dep_cell_px))
  if r_floor == r_ceil then return r_floor end
  local target = img_w / img_h
  local fl_ratio, cl_ratio
  if fixed_is_cols then
    fl_ratio = (fixed_cells * fixed_cell_px) / (r_floor * dep_cell_px)
    cl_ratio = (fixed_cells * fixed_cell_px) / (r_ceil * dep_cell_px)
  else
    fl_ratio = (r_floor * dep_cell_px) / (fixed_cells * fixed_cell_px)
    cl_ratio = (r_ceil * dep_cell_px) / (fixed_cells * fixed_cell_px)
  end
  if math.abs(fl_ratio - target) <= math.abs(cl_ratio - target) then return r_floor end
  return r_ceil
end

---@param img_w integer
---@param img_h integer
---@param max_cols integer
---@param max_rows integer
---@return integer cols, integer rows
function M.calc_display_size(img_w, img_h, max_cols, max_rows)
  local cell = M.get_cell_size()
  if not cell then return math.min(20, max_cols), math.min(10, max_rows) end

  -- Work in pixel space to minimize aspect-ratio distortion from rounding.
  local max_w = max_cols * cell.cell_w
  local max_h = max_rows * cell.cell_h

  -- Scale to fit within bounds (don't upscale)
  local scale = math.min(max_w / img_w, max_h / img_h, 1.0)

  local pixel_w = img_w * scale
  local pixel_h = img_h * scale

  -- Determine the constraining dimension and compute the other
  -- with optimal rounding to best preserve the aspect ratio.
  local cols, rows
  if max_w / img_w <= max_h / img_h then
    -- Width-constrained: fix cols, compute rows
    cols = math.min(max_cols, math.ceil(pixel_w / cell.cell_w))
    rows = best_round(cols, cell.cell_w, pixel_h, cell.cell_h, max_rows, img_w, img_h, true)
  else
    -- Height-constrained: fix rows, compute cols
    rows = math.min(max_rows, math.ceil(pixel_h / cell.cell_h))
    cols = best_round(rows, cell.cell_h, pixel_w, cell.cell_w, max_cols, img_w, img_h, false)
  end

  return math.max(1, cols), math.max(1, rows)
end

-- ============================================================================
-- Transmitting images
-- ============================================================================

--- Copy image bytes into a temporary file suitable for the Kitty graphics
--- temporary-file medium (t=t).
---
--- Terminals may refuse the plain-file medium (t=f) for security reasons —
--- it would let any application make the terminal read any file on disk. They
--- accept t=t, but only for files that live in a temp dir ($TMPDIR, /tmp, /dev/shm) AND whose path contains
--- the literal substring "tty-graphics-protocol"; the file is deleted by the
--- terminal once it has been read. We therefore copy the source PNG into a
--- freshly created, correctly named temp file for each transmission.
---@param src_path string  absolute path to a PNG file
---@return string?  path to the temp copy, or nil on failure
local function copy_to_graphics_tempfile(src_path)
  local in_f = io.open(src_path, "rb")
  if not in_f then return nil end
  local data = in_f:read "*a"
  in_f:close()
  if not data then return nil end

  -- The file must live in a temp dir ($TMPDIR, /tmp, /dev/shm) and its path
  -- must contain the literal substring "tty-graphics-protocol". vim.fn.tempname()
  -- gives a unique, collision-free path under the temp dir; we append the magic
  -- filename so the terminal accepts it.
  local base = vim.fn.tempname() -- e.g. /tmp/nvim.user/XXXXXX/0
  -- `mkdir()` raises (E739) rather than returning 0 when it cannot make it.
  local made, ok = pcall(vim.fn.mkdir, base, "p")
  if not made or ok == 0 then return nil end
  local name = base .. "/tty-graphics-protocol.png"

  local out_f = io.open(name, "wb")
  if not out_f then return nil end
  out_f:write(data)
  out_f:close()
  return name
end

--- Send a PNG to the terminal and have it stored, not displayed (a=t), through
--- the temporary-file medium (t=t). That is the only medium used: the terminal
--- reads a copy made here and deletes it. Nothing is sent when the copy cannot
--- be made.
---@param png_path string
---@return integer? image_id
local function transmit_png(png_path)
  local tmp = copy_to_graphics_tempfile(png_path)
  if not tmp then return nil end
  _image_id = _image_id + 1
  local id = _image_id
  -- a=t: transmit and store, q=2: suppress all responses
  term_write(string.format("\x1b_Ga=t,f=100,t=t,i=%d,q=2;%s\x1b\\", id, vim.base64.encode(tmp)))
  return id
end

--- Transmit image data to terminal (store without displaying).
--- The image is shown by giving it a virtual placement and drawing its
--- placeholder cells.
---@param path string absolute path to image file
---@return integer? image_id
function M.transmit_image(path)
  local png_path, is_temp = M.ensure_png(path)
  if not png_path then return nil end

  local id = transmit_png(png_path)
  -- The terminal read a copy; a conversion nobody caches is not needed again.
  if is_temp then os.remove(png_path) end
  return id
end

--- Transmit image asynchronously (converts to PNG if needed, then transmits).
--- When the image is converted (e.g. JPEG→PNG with resize), the callback
--- receives the actual transmitted image dimensions so callers can update
--- their placement's size accordingly.
---@param path string absolute path to image file
---@param callback fun(image_id: integer?, tx_w: integer?, tx_h: integer?)
function M.transmit_image_async(path, callback)
  M.ensure_png_async(path, function(png_path, is_temp)
    if not png_path then
      callback(nil)
      return
    end
    local id = transmit_png(png_path)
    -- Return actual transmitted dimensions when the converted PNG differs from
    -- the source (conversion may have resized, e.g. large JPEG → 2000px PNG).
    -- Cached PNGs are not "temp" but their dimensions still differ from the
    -- source, so callers must use these to compute correct placement sizes.
    local tx_w, tx_h
    if id and png_path ~= path then
      tx_w, tx_h = M.image_dimensions(png_path)
    end
    if is_temp then os.remove(png_path) end
    callback(id, tx_w, tx_h)
  end)
end

--- The Kitty placeholder diacritics table has 297 entries, which caps the
--- rows and columns of a virtual placement.
local MAX_PLACEHOLDER_CELLS = 297

--- Create a virtual placement for an image already transmitted with a=t.
---
--- A virtual placement (`U=1`) draws nothing by itself. It tells the terminal
--- how large the image is in cells, so that cells holding the placeholder
--- character U+10EEEE (foreground colour = image id, underline colour =
--- placement id) show the matching slice of the image. Those cells are plain
--- text, which is what lets tmux track them per pane.
---@param image_id integer  Kitty image ID from transmit_image()
---@param placement_id integer
---@param cols integer
---@param rows integer
function M.create_virtual_placement(image_id, placement_id, cols, rows)
  cols = math.max(1, math.min(cols, MAX_PLACEHOLDER_CELLS))
  rows = math.max(1, math.min(rows, MAX_PLACEHOLDER_CELLS))
  term_write(string.format("\x1b_Ga=p,U=1,i=%d,p=%d,c=%d,r=%d,q=2\x1b\\", image_id, placement_id, cols, rows))
end

--- Delete one virtual placement, keeping the transmitted image data.
---@param image_id integer
---@param placement_id integer
function M.delete_virtual_placement(image_id, placement_id)
  term_write(string.format("\x1b_Ga=d,d=i,i=%d,p=%d,q=2\x1b\\", image_id, placement_id))
end

--- Delete all images and placements from terminal memory.
function M.delete_all()
  term_write "\x1b_Ga=d,d=A,q=2\x1b\\"
end

--- Delete a stored image from terminal memory: its placements, virtual ones
--- included, and its data (`d=I`; lowercase would leave the data behind).
---@param image_id integer
function M.delete_image(image_id)
  term_write(string.format("\x1b_Ga=d,d=I,i=%d\x1b\\", image_id))
end

--- Delete multiple images
---@param image_ids integer[]
function M.delete_images(image_ids)
  if #image_ids == 0 then return end
  local parts = {}
  for _, id in ipairs(image_ids) do
    table.insert(parts, string.format("\x1b_Ga=d,d=I,i=%d\x1b\\", id))
  end
  term_write(table.concat(parts))
end

--- Clear all images from terminal memory (once per Neovim session).
--- Removes stale image data from previous sessions that may interfere
--- with new transmissions using the same ID range.
function M.clear_all()
  if _session_cleared then return end
  _session_cleared = true
  -- d=A: delete all stored image data and placements
  term_write "\x1b_Ga=d,d=A\x1b\\"
  -- Reset the ID counter to ensure clean state
  _image_id = 100

  -- Ensure images are cleaned up when Neovim exits (e.g. on :restart)
  vim.api.nvim_create_autocmd("VimLeavePre", {
    once = true,
    callback = function()
      M.delete_all()
    end,
  })
end

return M
