-- PlantUML → Kitty graphics escape sequence tests
--
-- Verifies the two-phase handoff for a rendered PlantUML diagram:
--   1. transmit_image (a=t) stores the PNG under an image ID
--   2. create_virtual_placement (a=p,U=1) sizes that same ID in cells; the
--      placeholder cells then show it (see placeholder_test.lua)
-- This is the part that can't be checked without a graphics-capable terminal
-- otherwise, so it is asserted at the escape-sequence level instead.
--
-- Run: nvim --headless -u NONE --noplugin -l tests/plantuml_kitty_test.lua

package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path

-- Keep the plugin's cache directories out of the user's real cache.
vim.env.XDG_CACHE_HOME = vim.fn.tempname()

local image = require "render-markdown-images.image"

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

local function test(name, fn)
  local ok, err = pcall(fn)
  if not ok then
    fail_count = fail_count + 1
    print("ERROR in " .. name .. ": " .. tostring(err))
  end
end

-- ============================================================================
-- Capture helpers (mirrors tests/image_test.lua)
-- ============================================================================

local captured = {}
local _orig_ui_send = nil

local function setup_capture()
  captured = {}
  _orig_ui_send = vim.api.nvim_ui_send
  vim.api.nvim_ui_send = function(data)
    table.insert(captured, data)
  end
  image.reset_cache()
  -- Inside tmux every graphics sequence is wrapped for passthrough, which these
  -- assertions are not about.
  image._set_in_tmux(false)
  image._reset_image_id()
end

local function teardown()
  if _orig_ui_send then
    vim.api.nvim_ui_send = _orig_ui_send
    _orig_ui_send = nil
  end
  image.reset_cache()
end

local function captured_output()
  return table.concat(captured)
end

--- Parse Kitty APC sequences: ESC _ G <params> [; <payload>] ESC \
local function parse_kitty_sequences(data)
  local seqs = {}
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

local function parse_params(params_str)
  local t = {}
  for k, v in params_str:gmatch "([%w_]+)=([^,]*)" do
    t[k] = v
  end
  return t
end

--- Find the first sequence whose action matches.
local function find_action(seqs, action)
  for _, seq in ipairs(seqs) do
    local p = parse_params(seq.params)
    if p.a == action then return p, seq end
  end
  return nil
end

-- ============================================================================
-- Fixture: render a PlantUML diagram once, reuse across tests.
--
-- Requires a local plantuml binary or network access to the remote server.
-- When neither is available the rendering tests are skipped rather than
-- failed, matching how the rest of the suite treats absent external tools.
-- ============================================================================

local diagram_source = "@startuml\nAlice -> Bob: kitty protocol test\n@enduml"

local function render_fixture()
  local done, result = false, nil
  image.render_plantuml_async(diagram_source, function(path)
    result = path
    done = true
  end)
  vim.wait(30000, function()
    return done
  end, 100)
  return result
end

local plantuml_png = render_fixture()

if not plantuml_png then
  print "SKIP: no local PlantUML renderer and no reachable remote server"
  print "\n0 passed, 0 failed (skipped)"
  return
end

-- ============================================================================
-- transmit (a=t): the rendered PNG is stored under an image ID
-- ============================================================================

test("transmit: rendered PlantUML PNG produces an a=t sequence", function()
  setup_capture()

  local id = image.transmit_image(plantuml_png)
  assert_true(id ~= nil, "transmit_image should return an image ID")

  local seqs = parse_kitty_sequences(captured_output())
  local p = find_action(seqs, "t")
  assert_true(p ~= nil, "should emit an a=t (transmit) sequence")
  if p then
    assert_eq(p.i, tostring(id), "transmit image ID matches the returned ID")
    assert_eq(p.f, "100", "f=100 marks the payload as PNG")
    assert_eq(p.q, "2", "q=2 suppresses terminal responses")
  end

  teardown()
end)

test("transmit: payload is the base64-encoded PNG path", function()
  setup_capture()

  local id = image.transmit_image(plantuml_png)
  local seqs = parse_kitty_sequences(captured_output())
  local _, seq = find_action(seqs, "t")
  assert_true(seq ~= nil and seq.payload ~= "", "a=t sequence carries a payload")
  if seq and seq.payload ~= "" then
    -- Terminals reject t=f, so the PNG is copied to a temp file the terminal
    -- reads once (t=t) and the payload is that copy's path.
    local decoded = vim.base64.decode(seq.payload)
    assert_eq(parse_params(seq.params).t, "t", "sent through the temporary-file medium")
    assert_true(decoded:find("tty-graphics-protocol", 1, true) ~= nil, "payload is the temp copy's path")
    assert_true(vim.fn.filereadable(decoded) == 1, "decoded path is readable")
    assert_eq(vim.fn.readblob(decoded), vim.fn.readblob(plantuml_png), "and holds the rendered PNG")
  end
  assert_true(id ~= nil, "image ID returned")

  teardown()
end)

-- ============================================================================
-- place (a=p,U=1): the transmitted image is sized by ID, not re-sent
-- ============================================================================

test("place: a virtual placement references the transmitted ID with the cell size", function()
  setup_capture()

  local id = image.transmit_image(plantuml_png)

  captured = {} -- isolate the placement from the transmit
  image.create_virtual_placement(id, 7, 20, 10)

  local seqs = parse_kitty_sequences(captured_output())
  local p = find_action(seqs, "p")
  assert_true(p ~= nil, "should emit an a=p (place) sequence")
  if p then
    assert_eq(p.U, "1", "U=1 makes the placement virtual: the placeholder cells show it")
    assert_eq(p.i, tostring(id), "placement references the transmitted image ID")
    assert_eq(p.p, "7", "p= is the placement id the cells' underline colour carries")
    assert_eq(p.c, "20", "c= matches requested display columns")
    assert_eq(p.r, "10", "r= matches requested display rows")
    assert_eq(p.q, "2", "q=2 suppresses terminal responses")
  end

  teardown()
end)

test("place: payload is empty (image data is not re-sent)", function()
  setup_capture()

  local id = image.transmit_image(plantuml_png)

  captured = {}
  image.create_virtual_placement(id, 1, 12, 6)

  local seqs = parse_kitty_sequences(captured_output())
  local _, seq = find_action(seqs, "p")
  assert_true(seq ~= nil, "a=p sequence present")
  if seq then assert_eq(seq.payload, "", "placement carries no payload — data was already transmitted") end

  teardown()
end)

test("place: the cursor is not touched", function()
  setup_capture()

  local id = image.transmit_image(plantuml_png)

  captured = {}
  image.create_virtual_placement(id, 1, 15, 8)
  local output = captured_output()

  assert_true(output:find "\x1b%[%d*;?%d*[Hsu]" == nil, "no CSI cursor save, restore or position")

  teardown()
end)

-- ============================================================================
-- Full handoff: transmit then place, in order, sharing one ID
-- ============================================================================

test("handoff: a=t precedes a=p and both use the same image ID", function()
  setup_capture()

  local id = image.transmit_image(plantuml_png)
  image.create_virtual_placement(id, 1, 18, 9)

  local seqs = parse_kitty_sequences(captured_output())
  local t_index, p_index
  for i, seq in ipairs(seqs) do
    local params = parse_params(seq.params)
    if params.a == "t" and not t_index then t_index = i end
    if params.a == "p" and not p_index then p_index = i end
  end

  assert_true(t_index ~= nil, "a=t sequence emitted")
  assert_true(p_index ~= nil, "a=p sequence emitted")
  if t_index and p_index then
    assert_true(t_index < p_index, "transmit is emitted before placement")
    local tp = parse_params(seqs[t_index].params)
    local pp = parse_params(seqs[p_index].params)
    assert_eq(pp.i, tp.i, "placement reuses the transmitted image ID")
    assert_eq(pp.i, tostring(id), "both match the ID returned by transmit_image")
  end

  teardown()
end)

test("handoff: one transmit supports placements at several sizes", function()
  setup_capture()

  local id = image.transmit_image(plantuml_png)

  captured = {}
  image.create_virtual_placement(id, 1, 10, 5)
  image.create_virtual_placement(id, 2, 20, 10)

  local seqs = parse_kitty_sequences(captured_output())
  local places = {}
  for _, seq in ipairs(seqs) do
    local p = parse_params(seq.params)
    if p.a == "p" then
      table.insert(places, p.p .. ":" .. p.c .. "x" .. p.r)
      assert_eq(p.i, tostring(id), "each placement reuses the same image ID")
      assert_eq(seq.payload, "", "no re-transmission of image data")
    end
  end
  assert_eq(places, { "1:10x5", "2:20x10" }, "both placements emitted, told apart by placement id")

  teardown()
end)

-- ============================================================================
-- Summary
-- ============================================================================

print(string.format("\n%d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then os.exit(1) end
