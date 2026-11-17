-- Image module unit tests: escape sequence verification
-- Run: nvim --headless -u NONE --noplugin -l tests/image_test.lua

package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path

-- Keep the plugin's cache directories out of the user's real cache.
vim.env.XDG_CACHE_HOME = vim.fn.tempname()

local image = require "render-markdown-images.image"
local cfg = require "render-markdown-images.config"
local uv = vim.uv or vim.loop

local pass_count = 0
local fail_count = 0

local function assert_eq(actual, expected, msg)
  if vim.deep_equal(actual, expected) then
    pass_count = pass_count + 1
  else
    fail_count = fail_count + 1
    print("FAIL: " .. msg)
    print("  expected: " .. vim.inspect(expected))
    print("  actual:   " .. vim.inspect(actual))
  end
end

local function assert_true(val, msg)
  if val then
    pass_count = pass_count + 1
  else
    fail_count = fail_count + 1
    print("FAIL: " .. msg)
  end
end

local function assert_match(actual, pattern, msg)
  if type(actual) == "string" and actual:match(pattern) then
    pass_count = pass_count + 1
  else
    fail_count = fail_count + 1
    print("FAIL: " .. msg)
    print("  expected match: " .. pattern)
    print("  actual:         " .. tostring(actual))
  end
end

local function assert_nil(val, msg)
  if val == nil then
    pass_count = pass_count + 1
  else
    fail_count = fail_count + 1
    print("FAIL: " .. msg)
    print("  expected nil, got: " .. vim.inspect(val))
  end
end

local function test(name, fn)
  local ok, err = pcall(fn)
  if not ok then
    fail_count = fail_count + 1
    print("ERROR: " .. name .. ": " .. tostring(err))
  end
end

--- Configure the plugin the way `require("render-markdown-images").setup` does.
---@param opts? table
local function set_config(opts)
  cfg.setup(opts)
  image.setup()
end

-- ============================================================================
-- Test helper: capture escape sequences written by image module
--
-- image.lua now writes via vim.api.nvim_ui_send, so we monkey-patch that API
-- to capture output (matches Neovim's own test/functional/ui/img_spec.lua).
-- ============================================================================

local captured = {}
local _orig_ui_send = nil

local function setup_capture()
  captured = {}
  _orig_ui_send = vim.api.nvim_ui_send
  vim.api.nvim_ui_send = function(data)
    table.insert(captured, data)
  end
  image._set_kitty_supported(true)
  image._set_in_tmux(false) -- keep the output unwrapped even when the suite runs inside tmux
  image._reset_image_id()
end

local function teardown()
  if _orig_ui_send then
    vim.api.nvim_ui_send = _orig_ui_send
    _orig_ui_send = nil
  end
  image._set_kitty_supported(nil)
  image.reset_cache()
end

--- Concatenate all captured writes into a single string
local function captured_output()
  return table.concat(captured)
end

--- Parse Kitty graphics APC sequences from captured output.
--- Returns a list of { params = "a=t,...", payload = "..." }
local function parse_kitty_sequences(data)
  local seqs = {}
  -- Match APC: ESC _ G <params> [; <payload>] ESC \
  -- Use non-greedy match and handle both with-payload and without-payload forms
  local pos = 1
  while pos <= #data do
    local s, e, content = data:find("\x1b_G(.-)\x1b\\", pos)
    if not s then break end
    local params, payload = content:match "^([^;]*);(.*)$"
    if not params then
      params = content
      payload = ""
    end
    table.insert(seqs, { params = params, payload = payload })
    pos = e + 1
  end
  return seqs
end

--- Parse params string "a=t,f=100,..." into a table { a="t", f="100", ... }
local function parse_params(params_str)
  local t = {}
  for k, v in params_str:gmatch "([%w_]+)=([^,]*)" do
    t[k] = v
  end
  return t
end

-- ============================================================================
-- Test fixtures
-- ============================================================================

local test_png = vim.fn.getcwd() .. "/tests/fixtures/test_4x4.png"

-- ============================================================================
-- calc_display_size tests
-- ============================================================================

test("calc_display_size: scales down when image exceeds max_cols", function()
  -- Mock cell size: 8x16 pixels per cell
  -- Image: 160x160 px → 20 cols x 10 rows
  -- max_cols = 10 → scale to 10 cols, 5 rows
  local cols, rows = image.calc_display_size(160, 160, 10, 20)
  assert_eq(cols, 10, "cols should be clamped to max_cols")
  assert_true(rows <= 20, "rows should not exceed max_rows")
end)

test("calc_display_size: scales down when image exceeds max_rows", function()
  local cols, rows = image.calc_display_size(80, 800, 40, 5)
  assert_true(rows <= 5, "rows should be clamped to max_rows")
  assert_true(cols <= 40, "cols should not exceed max_cols")
end)

test("calc_display_size: small image stays within bounds", function()
  local cols, rows = image.calc_display_size(8, 16, 40, 20)
  assert_true(cols <= 40, "cols within bounds")
  assert_true(rows <= 20, "rows within bounds")
end)

-- Aspect ratio preservation tests with mocked cell size
test("calc_display_size: square image stays square (cell 8x16)", function()
  image._test_cell_size = { cell_w = 8, cell_h = 16 }
  local cols, rows = image.calc_display_size(640, 640, 30, 15)
  -- 640/640 = 1.0; display should also be ~1.0
  local display_ratio = (cols * 8) / (rows * 16)
  assert_eq(display_ratio, 1.0, "square image should display as square, got " .. display_ratio)
  image._test_cell_size = nil
end)

test("calc_display_size: landscape 4:3 aspect ratio preserved (cell 9x18)", function()
  image._test_cell_size = { cell_w = 9, cell_h = 18 }
  local cols, rows = image.calc_display_size(640, 480, 30, 15)
  local display_ratio = (cols * 9) / (rows * 18)
  local target_ratio = 640 / 480
  local error_pct = math.abs(display_ratio - target_ratio) / target_ratio * 100
  assert_true(error_pct < 5, "4:3 aspect error should be <5%, got " .. string.format("%.1f%%", error_pct))
  assert_true(cols <= 30, "cols within max")
  assert_true(rows <= 15, "rows within max")
  image._test_cell_size = nil
end)

test("calc_display_size: 750x600 image in table column (cell 9x18)", function()
  image._test_cell_size = { cell_w = 9, cell_h = 18 }
  local cols, rows = image.calc_display_size(750, 600, 30, 15)
  local display_ratio = (cols * 9) / (rows * 18)
  local target_ratio = 750 / 600
  local error_pct = math.abs(display_ratio - target_ratio) / target_ratio * 100
  assert_true(error_pct < 5, "750x600 aspect error should be <5%, got " .. string.format("%.1f%%", error_pct))
  image._test_cell_size = nil
end)

test("calc_display_size: 16:9 widescreen aspect ratio (cell 9x18)", function()
  image._test_cell_size = { cell_w = 9, cell_h = 18 }
  local cols, rows = image.calc_display_size(1920, 1080, 30, 15)
  local display_ratio = (cols * 9) / (rows * 18)
  local target_ratio = 1920 / 1080
  local error_pct = math.abs(display_ratio - target_ratio) / target_ratio * 100
  assert_true(error_pct < 8, "16:9 aspect error should be <8%, got " .. string.format("%.1f%%", error_pct))
  image._test_cell_size = nil
end)

test("calc_display_size: tall portrait image constrained by max_rows", function()
  image._test_cell_size = { cell_w = 8, cell_h = 16 }
  local cols, rows = image.calc_display_size(400, 1200, 30, 15)
  assert_true(rows <= 15, "rows should not exceed max_rows")
  assert_true(cols <= 30, "cols should not exceed max_cols")
  assert_true(cols >= 1, "cols should be at least 1")
  image._test_cell_size = nil
end)

-- ============================================================================
-- transmit_image: escape sequence tests
-- ============================================================================

test("transmit_image: generates correct APC sequence for PNG", function()
  setup_capture()
  local id = image.transmit_image(test_png)
  assert_true(id ~= nil, "should return image ID")

  local seqs = parse_kitty_sequences(captured_output())
  assert_true(#seqs >= 1, "should produce at least one APC sequence")

  local p = parse_params(seqs[1].params)
  assert_eq(p.a, "t", "action should be 't' (transmit)")
  assert_eq(p.f, "100", "format should be 100 (PNG)")
  assert_eq(p.q, "2", "quiet mode should be 2")
  assert_true(p.i ~= nil, "should have image ID")
  assert_true(seqs[1].payload ~= "", "should have base64 payload (file path)")
  teardown()
end)

test("transmit_image: sequential IDs are monotonically increasing", function()
  setup_capture()
  local id1 = image.transmit_image(test_png)
  local id2 = image.transmit_image(test_png)
  assert_true(id1 ~= nil and id2 ~= nil, "both should succeed")
  assert_true(id2 > id1, "second ID should be greater than first")
  teardown()
end)

test("transmit_image: returns nil when kitty not supported", function()
  setup_capture()
  image._set_kitty_supported(false)
  local id = image.transmit_image(test_png)
  assert_nil(id, "should return nil when kitty not supported")
  assert_eq(#captured, 0, "should not write anything")
  teardown()
end)

test("transmit_image: payload is the base64 path of a temp copy, sent with t=t", function()
  setup_capture()
  local id = image.transmit_image(test_png)
  assert_true(id ~= nil, "should return image ID")

  local seqs = parse_kitty_sequences(captured_output())
  local decoded = vim.base64.decode(seqs[1].payload)
  -- Terminals reject t=f (plain file path), so the PNG is copied to a temp file
  -- with the name the terminal insists on, and sent with t=t.
  assert_match(decoded, "tty%-graphics%-protocol%.png$", "decoded payload should be the temp copy's path")
  assert_eq(vim.fn.readblob(decoded), vim.fn.readblob(test_png), "and the copy should hold the PNG")

  local p = parse_params(seqs[1].params)
  assert_eq(p.t, "t", "transfer mode should be 't' (temporary file)")
  teardown()
end)

test("transmit_image: always t=t, whatever the environment says the terminal is", function()
  local saved = { vim.env.TERM_PROGRAM, vim.env.GHOSTTY_RESOURCES_DIR }
  vim.env.TERM_PROGRAM, vim.env.GHOSTTY_RESOURCES_DIR = "ghostty", "/usr/share/ghostty"
  setup_capture()
  image.transmit_image(test_png)
  local p = parse_params(parse_kitty_sequences(captured_output())[1].params)
  assert_eq(p.t, "t", "no terminal gets t=f")
  vim.env.TERM_PROGRAM, vim.env.GHOSTTY_RESOURCES_DIR = saved[1], saved[2]
  teardown()
end)

--- Make the temp copy fail: the directory it would be made in cannot be created.
---@param fn fun()
local function with_failing_temp_copy(fn)
  local saved = vim.fn.tempname
  vim.fn.tempname = function()
    return "/proc/md-render-no-such-dir/0"
  end
  local ok, err = pcall(fn)
  vim.fn.tempname = saved
  if not ok then error(err, 0) end
end

test("transmit_image: nothing is sent, and nil returned, when the temp copy cannot be made", function()
  setup_capture()
  with_failing_temp_copy(function()
    assert_nil(image.transmit_image(test_png), "no id")
  end)
  assert_eq(#captured, 0, "and no t=f fallback")
  teardown()
end)

test("transmit_image_async: t=t, and nothing sent when the temp copy cannot be made", function()
  setup_capture()
  local got
  image.transmit_image_async(test_png, function(id, w, h)
    got = { id = id, w = w, h = h }
  end)
  vim.wait(1000, function()
    return got ~= nil
  end)
  assert_true(got and got.id ~= nil, "an id")
  assert_eq(parse_params(parse_kitty_sequences(captured_output())[1].params).t, "t", "sent with t=t")

  captured = {}
  got = nil
  with_failing_temp_copy(function()
    image.transmit_image_async(test_png, function(id)
      got = { id = id }
    end)
    vim.wait(1000, function()
      return got ~= nil
    end)
  end)
  assert_true(got ~= nil and got.id == nil, "no id")
  assert_eq(#captured, 0, "and nothing sent")
  teardown()
end)

test("the cursor-positioned entry points are gone", function()
  for _, name in ipairs { "put_image", "clear_placements", "begin_sync_update", "end_sync_update", "use_placeholders" } do
    assert_nil(image[name], "image." .. name)
  end
end)

test("nothing written moves or saves the cursor", function()
  setup_capture()
  image.transmit_image(test_png)
  image.create_virtual_placement(101, 1, 10, 4)
  image.delete_virtual_placement(101, 1)
  image.delete_image(101)
  image.delete_images { 102, 103 }
  image.delete_all()
  local out = captured_output()
  assert_true(not out:find "\x1b%[%d*;?%d*[Hsu]", "no CSI cursor position, save or restore")
  assert_true(not out:find("2026", 1, true), "no synchronized-update bracket")
  teardown()
end)

-- ============================================================================
-- delete: escape sequence tests
-- ============================================================================

test("delete_all: generates delete-all sequence", function()
  setup_capture()
  image.delete_all()

  local seqs = parse_kitty_sequences(captured_output())
  assert_eq(#seqs, 1, "should produce one sequence")

  local p = parse_params(seqs[1].params)
  assert_eq(p.a, "d", "action should be 'd' (delete)")
  assert_eq(p.d, "A", "delete target should be 'A' (all images)")
  teardown()
end)

test("delete_image: generates correct single-image delete", function()
  setup_capture()
  image.delete_image(77)

  local seqs = parse_kitty_sequences(captured_output())
  assert_eq(#seqs, 1, "should produce one sequence")

  local p = parse_params(seqs[1].params)
  assert_eq(p.a, "d", "action should be 'd'")
  assert_eq(p.d, "I", "delete target should be 'I' (specific image, and its data)")
  assert_eq(p.i, "77", "image ID should match")
  teardown()
end)

test("delete_images: generates multiple delete sequences", function()
  setup_capture()
  image.delete_images { 10, 20, 30 }

  local output = captured_output()
  local seqs = parse_kitty_sequences(output)
  assert_eq(#seqs, 3, "should produce three sequences")

  for idx, seq in ipairs(seqs) do
    local p = parse_params(seq.params)
    assert_eq(p.a, "d", "seq " .. idx .. ": action should be 'd'")
    assert_eq(p.d, "I", "seq " .. idx .. ": delete target should be 'I'")
  end

  -- Verify each ID is present
  local ids = {}
  for _, seq in ipairs(seqs) do
    ids[parse_params(seq.params).i] = true
  end
  assert_true(ids["10"], "should contain ID 10")
  assert_true(ids["20"], "should contain ID 20")
  assert_true(ids["30"], "should contain ID 30")
  teardown()
end)

test("delete_images: does nothing for empty list", function()
  setup_capture()
  image.delete_images {}
  assert_eq(#captured, 0, "should not write anything for empty list")
  teardown()
end)

-- ============================================================================
-- clear_all: session-level clear
-- ============================================================================

test("clear_all: generates delete-all and sets up autocmd", function()
  setup_capture()
  image.clear_all()

  local output = captured_output()
  assert_match(output, "a=d,d=A", "should contain delete-all sequence")
  teardown()
end)

-- ============================================================================
-- image_dimensions tests
-- ============================================================================

test("image_dimensions: reads PNG dimensions correctly", function()
  local w, h = image.image_dimensions(test_png)
  assert_eq(w, 4, "PNG width should be 4")
  assert_eq(h, 4, "PNG height should be 4")
end)

test("image_dimensions: returns nil for non-existent file", function()
  local w, h = image.image_dimensions "/nonexistent/path.png"
  assert_nil(w, "width should be nil for missing file")
  assert_nil(h, "height should be nil for missing file")
end)

-- ============================================================================
-- is_native_format tests
-- ============================================================================

test("is_native_format: PNG is native", function()
  assert_true(image.is_native_format(test_png), "PNG should be native format")
end)

-- ============================================================================
-- is_badge_url tests
-- ============================================================================

test("is_badge_url: detects shields.io", function()
  assert_true(image.is_badge_url "https://img.shields.io/badge/foo-bar", "shields.io should be badge")
end)

test("is_badge_url: normal URL is not badge", function()
  assert_true(not image.is_badge_url "https://example.com/photo.png", "normal URL should not be badge")
end)

-- ============================================================================
-- is_url tests
-- ============================================================================

test("is_url: detects http URL", function()
  assert_true(image.is_url "http://example.com/img.png", "http should be URL")
end)

test("is_url: detects https URL", function()
  assert_true(image.is_url "https://example.com/img.png", "https should be URL")
end)

test("is_url: rejects file path", function()
  assert_true(not image.is_url "/path/to/file.png", "file path should not be URL")
end)

-- ============================================================================
-- Batch mode tests
-- ============================================================================

test("begin_batch/flush_batch: batches writes into single output", function()
  setup_capture()

  image.begin_batch()
  image.delete_image(1)
  image.delete_image(2)
  image.delete_image(3)
  -- During batch, nothing should have been written yet
  assert_eq(#captured, 0, "should not write during batch")

  image.flush_batch()
  -- After flush, all writes should appear as a single write
  assert_eq(#captured, 1, "flush should produce single write")

  local seqs = parse_kitty_sequences(captured[1])
  assert_eq(#seqs, 3, "single write should contain all 3 delete sequences")
  teardown()
end)

test("nested batches: inner flush appends to outer batch", function()
  setup_capture()

  image.begin_batch()
  image.delete_image(1)

  image.begin_batch()
  image.delete_image(2)
  image.flush_batch()
  -- Still in outer batch, nothing written
  assert_eq(#captured, 0, "should not write during outer batch")

  image.delete_image(3)
  image.flush_batch()
  -- Now everything should be flushed
  assert_eq(#captured, 1, "should produce single write after outer flush")

  local seqs = parse_kitty_sequences(captured[1])
  assert_eq(#seqs, 3, "should contain all 3 sequences")
  teardown()
end)

-- ============================================================================
-- Platform sanity: get_cell_size / supports_kitty don't crash
-- ============================================================================

local ffi = require "ffi"

test("get_cell_size: returns nil or table without crashing (no override)", function()
  image._test_cell_size = nil
  local result = image.get_cell_size()
  -- In headless nvim stdout is not a TTY and there's no controlling terminal,
  -- so result is normally nil. In a real terminal it returns a {cell_w,cell_h}
  -- table. Both are valid; the contract is "must not crash".
  assert_true(
    result == nil or (type(result) == "table" and result.cell_w and result.cell_h),
    "get_cell_size should return nil or {cell_w, cell_h}"
  )
end)

test("supports_kitty: returns boolean without crashing", function()
  image._set_kitty_supported(nil) -- clear cache so detection runs
  local result = image.supports_kitty()
  assert_true(result == true or result == false, "supports_kitty should return a boolean")
  image._set_kitty_supported(nil)
end)

-- ============================================================================
-- Linux-specific FFI exercise
-- Verifies that the ioctl/winsize declarations parse on Linux ABI and that
-- a TIOCGWINSZ call against a non-TTY fd fails cleanly (no segfault).
-- ============================================================================

if ffi.os == "Linux" then
  -- Trigger declarations in image.lua by calling get_cell_size once.
  image._test_cell_size = nil
  pcall(image.get_cell_size)
  -- Open/close are also needed for this test; declare locally if not present.
  pcall(ffi.cdef, "int open(const char *path, int flags); int close(int fd);")

  test("Linux: winsize struct size is 8 bytes", function()
    assert_eq(ffi.sizeof "winsize", 8, "winsize should be 8 bytes (4 unsigned shorts)")
  end)

  test("Linux: ioctl(TIOCGWINSZ) on non-TTY fd fails cleanly", function()
    local TIOCGWINSZ_LINUX = 0x5413
    local fd = ffi.C.open("/dev/null", 0) -- O_RDONLY
    assert_true(fd >= 0, "open /dev/null should succeed")
    local sz = ffi.new "winsize"
    local rc = ffi.C.ioctl(fd, TIOCGWINSZ_LINUX, sz)
    -- /dev/null is not a TTY, so ioctl must fail (rc != 0). The contract is
    -- "must not segfault"; a clean failure is the success case.
    assert_true(rc ~= 0, "ioctl TIOCGWINSZ on /dev/null should return nonzero")
    ffi.C.close(fd)
  end)
end

-- ============================================================================
-- ensure_png cache tests
-- ============================================================================

local function has_convert_tool()
  return vim.fn.executable "sips" == 1 or vim.fn.executable "ffmpeg" == 1 or vim.fn.executable "magick" == 1
end

--- Convert the PNG fixture to a temporary JPEG so we have a non-native source.
--- Returns nil if no conversion tool is available.
local function make_test_jpeg()
  local out = vim.fn.tempname() .. ".jpg"
  if vim.fn.executable "sips" == 1 then
    vim.system({ "sips", "-s", "format", "jpeg", test_png, "--out", out }, { text = true }):wait()
  elseif vim.fn.executable "ffmpeg" == 1 then
    vim.system({ "ffmpeg", "-y", "-i", test_png, out }, { text = true }):wait()
  elseif vim.fn.executable "magick" == 1 then
    vim.system({ "magick", test_png, out }, { text = true }):wait()
  else
    return nil
  end
  if vim.fn.filereadable(out) ~= 1 then return nil end
  return out
end

if has_convert_tool() then
  test("ensure_png: caches converted JPEG to disk", function()
    local jpeg = make_test_jpeg()
    if not jpeg then return end
    local cache_dir = vim.fn.stdpath "cache" .. "/render-markdown-images/converted"
    -- Clean cache for this hash so the count is meaningful
    vim.fn.mkdir(cache_dir, "p")
    local hash = vim.fn.sha256(jpeg):sub(1, 16)
    for _, p in ipairs(vim.fn.glob(cache_dir .. "/" .. hash .. "_*", false, true)) do
      os.remove(p)
    end

    local png1, is_temp1 = image.ensure_png(jpeg)
    assert_true(png1 ~= nil, "first conversion should succeed")
    assert_true(is_temp1 == false, "cached output should not be flagged temporary")
    assert_true(vim.fn.filereadable(png1) == 1, "cached png should exist on disk")
    assert_true(
      png1:find("/render-markdown-images/converted/" .. hash .. "_", 1, true) ~= nil,
      "path should be in converted cache dir"
    )

    local png2, is_temp2 = image.ensure_png(jpeg)
    assert_eq(png2, png1, "second call should return identical cached path")
    assert_true(is_temp2 == false, "second call should also report non-temp")

    os.remove(jpeg)
    os.remove(png1)
  end)

  test("transmit_image_async: returns converted dims even from cache", function()
    local jpeg = make_test_jpeg()
    if not jpeg then return end
    -- Pre-populate the cache by running ensure_png once
    local cached = image.ensure_png(jpeg)
    if not cached then return end
    local cached_w, cached_h = image.image_dimensions(cached)
    if not cached_w then return end

    setup_capture()
    local cb_id, cb_w, cb_h
    image.transmit_image_async(jpeg, function(id, w, h)
      cb_id, cb_w, cb_h = id, w, h
    end)
    assert_true(cb_id ~= nil, "should return image id")
    assert_eq(cb_w, cached_w, "should return cached PNG width, not source JPEG width")
    assert_eq(cb_h, cached_h, "should return cached PNG height, not source JPEG height")
    teardown()

    os.remove(jpeg)
    os.remove(cached)
  end)

  test("ensure_png: mtime change invalidates cache", function()
    local jpeg = make_test_jpeg()
    if not jpeg then return end
    local cache_dir = vim.fn.stdpath "cache" .. "/render-markdown-images/converted"
    vim.fn.mkdir(cache_dir, "p")
    local hash = vim.fn.sha256(jpeg):sub(1, 16)
    for _, p in ipairs(vim.fn.glob(cache_dir .. "/" .. hash .. "_*", false, true)) do
      os.remove(p)
    end

    local png1 = image.ensure_png(jpeg)
    assert_true(png1 ~= nil, "first conversion should succeed")

    -- Bump mtime by 2s so getftime sees a different value
    local new_mtime = vim.fn.getftime(jpeg) + 2
    uv.fs_utime(jpeg, new_mtime, new_mtime)

    local png2 = image.ensure_png(jpeg)
    assert_true(png2 ~= nil, "second conversion should succeed")
    assert_true(png2 ~= png1, "different mtime should yield a different cache entry")

    os.remove(jpeg)
    os.remove(png1)
    os.remove(png2)
  end)
end

-- ============================================================================
-- One process per file, however many times it is asked for
-- ============================================================================

--- Stand in for `vim.system`, recording each spawn and handing back the
--- completion callback so the test decides when the work finishes.
---@return { spawns: integer, finish: fun(code: integer) }
local function stub_vim_system()
  local rec = { spawns = 0 }
  local pending = {}
  local real = vim.system
  vim.system = function(_, _, on_exit)
    rec.spawns = rec.spawns + 1
    table.insert(pending, on_exit)
    return { pid = 0 }
  end
  rec.finish = function(code)
    local queued = pending
    pending = {}
    for _, on_exit in ipairs(queued) do
      on_exit { code = code, stdout = "", stderr = "" }
    end
    vim.wait(100, function()
      return false
    end, 10)
  end
  rec.restore = function()
    vim.system = real
  end
  return rec
end

test("download_async: asking for the same URL twice runs one curl", function()
  local sys = stub_vim_system()
  local url = "https://example.invalid/rmi-test-dedupe.png"
  local answers = {}

  image.download_async(url, function(path)
    table.insert(answers, path or false)
  end)
  image.download_async(url, function(path)
    table.insert(answers, path or false)
  end)
  assert_eq(sys.spawns, 1, "the second request joins the first instead of spawning another curl")
  assert_eq(#answers, 0, "and nothing has answered yet")

  -- Fail the download: the file never appears, so both callers get nil, which
  -- is what proves the second one was queued rather than dropped.
  sys.finish(1)
  assert_eq(#answers, 2, "both callers are answered when the one download finishes")
  assert_eq(answers, { false, false }, "both get the same result")

  -- The key is released, so a later attempt is allowed to try again.
  image.download_async(url, function() end)
  assert_eq(sys.spawns, 2, "a request after the first finished starts fresh work")
  sys.finish(1)
  sys.restore()
end)

-- ============================================================================
-- set_download_fn: the two answers a custom downloader gives
-- ============================================================================

--- Wait for `answers` to reach `n`, pumping the event loop.
---@param answers table
---@param n integer
local function wait_for(answers, n)
  vim.wait(2000, function()
    return #answers >= n
  end, 5)
end

test("set_download_fn: declining hands the URL back to curl", function()
  local sys = stub_vim_system()
  local asked = {}
  image.set_download_fn(function(url)
    table.insert(asked, url)
    return false
  end)

  local url = "https://example.invalid/rmi-test-declined.png"
  local answers = {}
  image.download_async(url, function(path)
    table.insert(answers, path or false)
  end)

  -- Both of the custom function's answers are deferred to the main loop, so
  -- curl only starts on the next tick.
  vim.wait(2000, function()
    return sys.spawns > 0
  end, 5)
  assert_eq(asked, { url }, "the custom function was offered the URL")
  assert_eq(sys.spawns, 1, "and declining fell through to curl")

  sys.finish(1)
  wait_for(answers, 1)
  assert_eq(answers, { false }, "the failed curl answers the caller")

  image.set_download_fn(nil)
  sys.restore()
end)

test("set_download_fn: taking the job keeps curl out of it", function()
  local sys = stub_vim_system()
  -- Call back at once, in the same tick as the `true` return. Nothing in the
  -- documented contract forbids it, and it is the ordering that separates the
  -- two runtimes: 0.12 resumes the task from inside the callback, so a task
  -- that read "did it take the job?" straight after awaiting would read it
  -- before the answer was assigned and start a redundant curl.
  local downloaded
  image.set_download_fn(function(_, output_path, callback)
    downloaded = output_path
    vim.fn.writefile(vim.fn.readfile(test_png, "b"), output_path, "b")
    callback(true)
    return true
  end)

  -- A fresh URL every run: the download cache lives on disk and outlives the
  -- process, and a hit there would answer before the custom function is even
  -- offered the job, quietly making this test prove nothing.
  local url = ("https://example.invalid/rmi-test-custom-%d.png"):format(vim.uv.hrtime())
  local answers = {}
  image.download_async(url, function(path)
    table.insert(answers, path or false)
  end)
  wait_for(answers, 1)

  assert_eq(sys.spawns, 0, "no curl was spawned")
  assert_eq(#answers, 1, "the caller is answered exactly once")
  assert_eq(answers[1], downloaded, "and gets the file the custom function wrote")

  if downloaded then os.remove(downloaded) end
  image.set_download_fn(nil)
  sys.restore()
end)

test("set_download_fn: reporting failure answers nil without falling back", function()
  local sys = stub_vim_system()
  image.set_download_fn(function(_, _, callback)
    vim.schedule(function()
      callback(false)
    end)
    return true
  end)

  local answers = {}
  image.download_async("https://example.invalid/rmi-test-custom-fail.png", function(path)
    table.insert(answers, path or false)
  end)
  wait_for(answers, 1)

  assert_eq(sys.spawns, 0, "taking the job and failing is not a reason to try curl")
  assert_eq(answers, { false }, "the caller is told the download failed")

  image.set_download_fn(nil)
  sys.restore()
end)

-- ============================================================================
-- Formats this plugin does not display: GIF and video
-- ============================================================================

test("is_unsupported_format: GIF and video extensions", function()
  for _, name in ipairs { "a.gif", "a.GIF", "a.mp4", "a.webm", "a.mov", "a.avi", "a.mkv", "a.m4v", "dir/sub/clip.MP4" } do
    assert_true(image.is_unsupported_format(name), name .. " is not displayed")
  end
end)

test("is_unsupported_format: URLs, with or without a query or fragment", function()
  assert_true(image.is_unsupported_format "https://example.com/cat.gif", "plain URL")
  assert_true(image.is_unsupported_format "https://example.com/cat.gif?raw=true", "with a query")
  assert_true(image.is_unsupported_format "https://example.com/clip.mp4#t=5", "with a fragment")
  assert_true(image.is_unsupported_format "https://example.com/v/clip.webm?a=1&b=2#x", "with both")
end)

test("is_unsupported_format: images, and names that merely contain the word", function()
  for _, name in ipairs { "a.png", "a.jpg", "a.jpeg", "a.webp", "a.svg", "https://example.com/200.jpg" } do
    assert_true(not image.is_unsupported_format(name), name .. " is left alone")
  end
  -- No extension, e.g. GitHub's user-attachments URLs: can't tell, so not skipped.
  assert_true(
    not image.is_unsupported_format "https://github.com/user-attachments/assets/abcd-1234",
    "extensionless URL"
  )
  assert_true(not image.is_unsupported_format "mp4", "a bare word is not an extension")
  assert_true(not image.is_unsupported_format "my.gif.png", "only the last extension counts")
  assert_true(not image.is_unsupported_format "https://example.com/gif/cat.png", "a directory called gif")
end)

test("image_dimensions: GIF and video are not images", function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local function write(path, bytes)
    local f = assert(io.open(path, "wb"))
    f:write(bytes)
    f:close()
  end
  local gif = dir .. "/a.gif"
  -- A valid GIF header: "GIF89a", 1x1.
  write(gif, "GIF89a\1\0\1\0\0\0\0;")
  assert_nil(image.image_dimensions(gif), "a GIF has no dimensions")
  local mp4 = dir .. "/a.mp4"
  write(mp4, "\0\0\0\24ftypmp42\0\0\0\0mp42isom")
  assert_nil(image.image_dimensions(mp4), "nor does an MP4")
  vim.fn.delete(dir, "rf")
end)

test("the animation and video entry points are gone", function()
  for _, name in ipairs {
    "is_animated_gif",
    "is_video_file",
    "is_video_content",
    "video_dimensions",
    "video_dimensions_async",
    "get_video_cached",
    "download_video_async",
    "transmit_animated",
    "transmit_animated_async",
    "is_transmitted",
    "_build_frame_extract_cmd",
  } do
    assert_nil(image[name], "image." .. name .. " no longer exists")
  end
end)

-- ============================================================================
-- Virtual placements (Kitty Unicode placeholders)
-- ============================================================================

test("create_virtual_placement: exact bytes outside tmux", function()
  setup_capture()
  image.create_virtual_placement(101, 7, 20, 5)
  assert_eq(captured, { "\x1b_Ga=p,U=1,i=101,p=7,c=20,r=5,q=2\x1b\\" }, "virtual placement APC, unwrapped")
  teardown()
end)

test("create_virtual_placement: wrapped in the passthrough envelope inside tmux", function()
  setup_capture()
  image._set_in_tmux(true)
  image.create_virtual_placement(101, 7, 20, 5)
  assert_eq(
    captured,
    { "\x1bPtmux;\x1b\x1b_Ga=p,U=1,i=101,p=7,c=20,r=5,q=2\x1b\x1b\\\x1b\\" },
    "every ESC in the payload doubled, inside \\ePtmux;...\\e\\"
  )
  teardown()
end)

test("create_virtual_placement: clamps cols and rows to the diacritics table", function()
  setup_capture()
  image.create_virtual_placement(1, 2, 1000, 298)
  image.create_virtual_placement(1, 2, 297, 0)
  local first = parse_params(parse_kitty_sequences(captured[1])[1].params)
  local second = parse_params(parse_kitty_sequences(captured[2])[1].params)
  assert_eq({ first.c, first.r }, { "297", "297" }, "above 297 is clamped down")
  assert_eq({ second.c, second.r }, { "297", "1" }, "below 1 is clamped up, 297 is kept")
  teardown()
end)

test("create_virtual_placement: does nothing when kitty not supported", function()
  setup_capture()
  image._set_kitty_supported(false)
  image.create_virtual_placement(101, 7, 20, 5)
  assert_eq(#captured, 0, "should not write anything")
  teardown()
end)

test("delete_virtual_placement: exact bytes outside tmux", function()
  setup_capture()
  image.delete_virtual_placement(101, 7)
  assert_eq(captured, { "\x1b_Ga=d,d=i,i=101,p=7,q=2\x1b\\" }, "lowercase d=i keeps the image data")
  teardown()
end)

test("delete_virtual_placement: wrapped in the passthrough envelope inside tmux", function()
  setup_capture()
  image._set_in_tmux(true)
  image.delete_virtual_placement(101, 7)
  assert_eq(
    captured,
    { "\x1bPtmux;\x1b\x1b_Ga=d,d=i,i=101,p=7,q=2\x1b\x1b\\\x1b\\" },
    "every ESC in the payload doubled, inside \\ePtmux;...\\e\\"
  )
  teardown()
end)

test("delete_virtual_placement: does nothing when kitty not supported", function()
  setup_capture()
  image._set_kitty_supported(false)
  image.delete_virtual_placement(101, 7)
  assert_eq(#captured, 0, "should not write anything")
  teardown()
end)

-- ============================================================================
-- Protocol probe: how this plugin finds out whether images work
--
-- The terminal is asked, with a Kitty graphics query followed by DA1; it is
-- never identified by name. `nvim_ui_send` is captured and the terminal's
-- answers are TermResponse autocommands fired from a scheduled callback, the
-- way Neovim fires them when the TUI relays a reply.
-- ============================================================================

local tty = require "vim.tty"
local OK_REPLY = "\x1b_Gi=31;OK\x1b\\"
local DA1_REPLY = "\x1b[?62;4;22c"
local PROBE_QUERY = "\x1b_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\"

--- Run `fn(h)` against a fresh probe, as if Neovim had a UI (or not), inside
--- tmux (or not), and restore everything after.
---@param opts { tmux?: boolean, termguicolors?: boolean, enabled?: "auto"|boolean, replies?: string[], no_ui?: boolean, timeout?: integer, no_tty_request?: boolean }
---@param fn fun(h: table)
local function with_probe(opts, fn)
  local saved = {
    ui_send = vim.api.nvim_ui_send,
    list_uis = vim.api.nvim_list_uis,
    termguicolors = vim.o.termguicolors,
    enabled = cfg.get().enabled,
    request = tty.request,
  }
  local h = { sent = {} }
  vim.api.nvim_ui_send = function(data)
    table.insert(h.sent, data)
    -- The terminal answers after the write, from the event loop.
    local replies = opts.replies or {}
    vim.schedule(function()
      for _, reply in ipairs(replies) do
        vim.api.nvim_exec_autocmds("TermResponse", { data = { sequence = reply } })
      end
    end)
  end
  vim.api.nvim_list_uis = function()
    return opts.no_ui and {} or { {} }
  end
  vim.o.termguicolors = opts.termguicolors ~= false
  if opts.no_tty_request then tty.request = nil end

  image.reset_cache()
  image._set_in_tmux(opts.tmux or false)
  image._set_probe_timeout(opts.timeout or 100)
  set_config { enabled = opts.enabled == nil and "auto" or opts.enabled }

  function h.queries()
    return #h.sent
  end

  local ok, err = pcall(fn, h)

  vim.api.nvim_ui_send = saved.ui_send
  vim.api.nvim_list_uis = saved.list_uis
  vim.o.termguicolors = saved.termguicolors
  if opts.no_tty_request then tty.request = saved.request end
  set_config { enabled = saved.enabled }
  image.reset_cache()
  if not ok then error(err, 0) end
end

test("probe: an answer to the graphics query turns images on, and is asked as query then DA1", function()
  with_probe({ replies = { OK_REPLY, DA1_REPLY } }, function(h)
    assert_true(image.supports_kitty(), "the terminal answered OK")
    assert_eq(image.probe_result(), "ok", "result")
    assert_eq(h.sent, { PROBE_QUERY .. "\x1b[c" }, "one write: the query, then DA1")
  end)
end)

test("probe: DA1 before any graphics answer means no protocol, outside tmux", function()
  with_probe({ replies = { DA1_REPLY } }, function(h)
    assert_true(not image.supports_kitty(), "images are off")
    assert_eq(image.probe_result(), "da1_first", "result")
    assert_true(not image.supports_kitty(), "and stay off")
    assert_eq(h.queries(), 1, "the answer is kept: no second question")
  end)
end)

test("probe: inside tmux DA1 is tmux's own and is ignored; the graphics answer decides", function()
  with_probe({ tmux = true, replies = { DA1_REPLY, OK_REPLY } }, function(h)
    assert_true(image.supports_kitty(), "the OK after the DA1 counts")
    assert_eq(image.probe_result(), "ok", "result")
    assert_eq(h.queries(), 1, "asked once")
  end)
end)

test("probe: inside tmux the query is wrapped for passthrough, and DA1 is not asked", function()
  with_probe({ tmux = true, replies = { OK_REPLY } }, function(h)
    image.supports_kitty()
    assert_eq(
      h.sent,
      { "\x1bPtmux;\x1b\x1b_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\x1b\\\x1b\\" },
      "every ESC doubled, inside \\ePtmux;...\\e\\, and nothing else"
    )
  end)
end)

test("probe: silence outside tmux is no reply, after the timeout", function()
  with_probe({ timeout = 150 }, function()
    local t0 = vim.uv.hrtime()
    assert_true(not image.supports_kitty(), "images are off")
    local ms = (vim.uv.hrtime() - t0) / 1e6
    assert_eq(image.probe_result(), "no_reply", "result")
    assert_true(ms >= 100 and ms < 1000, "it waited for the timeout, no longer (" .. math.floor(ms) .. " ms)")
  end)
end)

test("probe: silence inside tmux is off after the timeout, and is not asked again", function()
  with_probe({ tmux = true, timeout = 100 }, function(h)
    assert_true(not image.supports_kitty(), "images are off")
    assert_eq(image.probe_result(), "no_reply", "result")
    local t0 = vim.uv.hrtime()
    assert_true(not image.supports_kitty(), "still off")
    assert_true((vim.uv.hrtime() - t0) / 1e6 < 50, "the second answer is immediate")
    assert_eq(h.queries(), 1, "asked once")
  end)
end)

test("probe: a positive answer is cached for the session", function()
  with_probe({ replies = { OK_REPLY } }, function(h)
    assert_true(image.supports_kitty(), "first")
    assert_true(image.supports_kitty(), "second")
    assert_true(image.supports_kitty(), "third")
    assert_eq(h.queries(), 1, "asked once")
  end)
end)

test("probe: an answer about another image, or an error, is not an answer", function()
  for _, reply in ipairs { "\x1b_Gi=7;OK\x1b\\", "\x1b_Gi=31;ENOENT:no such file\x1b\\", "\x1b_Gi=310;OK\x1b\\" } do
    with_probe({ replies = { reply }, timeout = 80 }, function()
      assert_true(not image.supports_kitty(), vim.inspect(reply) .. " does not turn images on")
      assert_eq(image.probe_result(), "no_reply", "and the probe goes on waiting")
    end)
  end
end)

test("probe: an answer with more parameters is still the answer", function()
  with_probe({ replies = { "\x1b_Gi=31,p=1;OK\x1b\\" } }, function()
    assert_true(image.supports_kitty(), "i=31 among others")
  end)
end)

test("probe: enabled = true asks nothing and is on", function()
  with_probe({ enabled = true }, function(h)
    assert_true(image.supports_kitty(), "on")
    assert_eq(h.sent, {}, "no bytes sent")
    assert_eq(image.probe_result(), "not_asked", "result")
  end)
end)

test("probe: enabled = false asks nothing and is off, whatever the terminal says", function()
  with_probe({ enabled = false, replies = { OK_REPLY } }, function(h)
    assert_true(not image.supports_kitty(), "off")
    assert_eq(h.sent, {}, "no bytes sent")
  end)
end)

test("probe: 'termguicolors' off is off, and turning it on later works without asking again", function()
  with_probe({ termguicolors = false, replies = { OK_REPLY } }, function(h)
    assert_true(not image.supports_kitty(), "off without 24-bit colour")
    assert_eq(image.probe_result(), "ok", "though the terminal does speak the protocol")
    vim.o.termguicolors = true
    assert_true(image.supports_kitty(), "on once 'termguicolors' is on")
    assert_eq(h.queries(), 1, "the terminal was asked once")
  end)
  with_probe({ termguicolors = false, enabled = true }, function()
    assert_true(not image.supports_kitty(), "enabled = true does not override it")
    vim.o.termguicolors = true
    assert_true(image.supports_kitty(), "and it can be turned on later")
  end)
end)

test("probe: with no UI attached nothing is asked and nothing is kept", function()
  with_probe({ no_ui = true, replies = { OK_REPLY } }, function(h)
    assert_true(not image.supports_kitty(), "off")
    assert_eq(h.sent, {}, "no bytes sent")
    assert_eq(image.probe_result(), "not_asked", "result")
    vim.api.nvim_list_uis = function()
      return { {} }
    end
    assert_true(image.supports_kitty(), "a UI that attaches later is asked")
  end)
end)

test("probe: a second caller during the wait gets the same answer and asks nothing", function()
  with_probe({ replies = { OK_REPLY } }, function(h)
    local other
    local send = vim.api.nvim_ui_send
    vim.api.nvim_ui_send = function(data)
      -- Queued ahead of the terminal's answer, and run by the probe's own wait.
      vim.schedule(function()
        other = image.supports_kitty()
      end)
      send(data)
    end
    assert_true(image.supports_kitty(), "first caller")
    vim.wait(100, function()
      return other ~= nil
    end)
    assert_eq(other, true, "second caller")
    assert_eq(h.queries(), 1, "asked once")
  end)
end)

test("probe: an invalid `enabled` is an error; every valid one is accepted", function()
  local saved = cfg.get().enabled
  for _, bad in ipairs { "yes", "on", 1, {} } do
    local ok, err = pcall(set_config, { enabled = bad })
    assert_true(not ok, vim.inspect(bad) .. " is refused")
    assert_match(tostring(err), "enabled", "and the error names the option")
    assert_eq(cfg.get().enabled, saved, "which leaves the setting alone")
  end
  for _, good in ipairs { "auto", true, false } do
    local ok = pcall(set_config, { enabled = good })
    assert_true(ok, vim.inspect(good) .. " is accepted")
    assert_eq(cfg.get().enabled, good, "and stored")
  end
  set_config { enabled = saved }
end)

test("probe: image.setup() after a config change decides again, without asking the terminal again", function()
  with_probe({ replies = { OK_REPLY } }, function(h)
    assert_true(image.supports_kitty(), "on")
    set_config { enabled = false }
    assert_true(not image.supports_kitty(), "off as soon as it is disabled")
    set_config { enabled = "auto" }
    assert_true(image.supports_kitty(), "on again")
    assert_eq(h.queries(), 1, "the terminal's answer was kept")
  end)
end)

test("probe: reset_cache forgets the answer and the test overrides", function()
  with_probe({ replies = { OK_REPLY } }, function(h)
    image.supports_kitty()
    assert_eq(image.probe_result(), "ok", "answered")
    image.reset_cache()
    assert_eq(image.probe_result(), "not_asked", "forgotten")
    image._set_in_tmux(true)
    image.reset_cache()
    assert_eq(image.in_tmux(), vim.env.TMUX ~= nil and vim.env.TMUX ~= "", "in_tmux override cleared: back to $TMUX")
    image._set_in_tmux(false)
    image.supports_kitty()
    assert_eq(h.queries(), 2, "and the terminal is asked again")
  end)
end)

-- ----------------------------------------------------------------------------
-- The request: `vim.tty.request` where Neovim has it, a local copy where not
-- ----------------------------------------------------------------------------

local function termresponse_autocmds()
  return #vim.api.nvim_get_autocmds { event = "TermResponse" }
end

test("probe, shim (Neovim without vim.tty.request): answer, and the listener is gone after", function()
  with_probe({ no_tty_request = true, replies = { OK_REPLY } }, function()
    local before = termresponse_autocmds()
    assert_true(image.supports_kitty(), "on")
    assert_eq(termresponse_autocmds(), before, "the TermResponse autocommand was removed")
  end)
end)

test("probe, shim: DA1 first, and the listener is gone after", function()
  with_probe({ no_tty_request = true, replies = { DA1_REPLY } }, function()
    local before = termresponse_autocmds()
    assert_true(not image.supports_kitty(), "off")
    assert_eq(image.probe_result(), "da1_first", "result")
    assert_eq(termresponse_autocmds(), before, "the TermResponse autocommand was removed")
  end)
end)

test("probe, shim: silence times out, and the listener is gone after", function()
  with_probe({ no_tty_request = true, timeout = 80 }, function()
    local before = termresponse_autocmds()
    assert_true(not image.supports_kitty(), "off")
    assert_eq(image.probe_result(), "no_reply", "result")
    -- The timer's cleanup is scheduled; give it its turn.
    vim.wait(50, function()
      return termresponse_autocmds() == before
    end)
    assert_eq(termresponse_autocmds(), before, "the TermResponse autocommand was removed")
  end)
end)

test("probe, vim.tty.request (stubbed): used when present, with the timeout and the same contract", function()
  local saved = tty.request
  local calls = {}
  tty.request = function(payload, opts, on_response)
    table.insert(
      calls,
      { payload = payload, timeout = opts.timeout, has_on_timeout = type(opts.on_timeout) == "function" }
    )
    vim.schedule(function()
      -- A reply that is not ours first: it must not stop the listener.
      calls.first_stops = on_response "\x1b[?997;1n" == true
      calls.second_stops = on_response(OK_REPLY) == true
    end)
    return 1
  end
  -- The stub sends nothing itself; DA1 is what a terminal outside tmux sends back.
  local ok, err = pcall(with_probe, { timeout = 120 }, function(h)
    assert_true(image.supports_kitty(), "on")
    assert_eq(#calls, 1, "one request")
    assert_eq(calls[1].payload, PROBE_QUERY .. "\x1b[c", "the query and DA1 as the payload")
    assert_eq(calls[1].timeout, 120, "with the probe timeout")
    assert_true(calls[1].has_on_timeout, "and a timeout handler")
    assert_eq(h.sent, {}, "the stub did the sending: the module wrote nothing itself")
    assert_eq(calls.first_stops, false, "a reply that is not the answer does not stop the listener")
    assert_eq(calls.second_stops, true, "the answer does")
  end)
  tty.request = saved
  if not ok then error(err, 0) end
end)

test("probe, vim.tty.request (stubbed): DA1 first is read as no protocol", function()
  local saved = tty.request
  tty.request = function(_, _, on_response)
    vim.schedule(function()
      on_response(DA1_REPLY)
    end)
    return 1
  end
  local ok, err = pcall(with_probe, {}, function()
    assert_true(not image.supports_kitty(), "DA1 first: off")
    assert_eq(image.probe_result(), "da1_first", "result")
  end)
  tty.request = saved
  if not ok then error(err, 0) end
end)

print(string.format("\n%d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then os.exit(1) end
