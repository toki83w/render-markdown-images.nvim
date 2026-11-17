--- Find what to draw: images in inline markdown and diagram fences in block markdown.
---
--- Both functions turn a treesitter root into a list of plain items. They read the
--- buffer and the tree and nothing else: no files are touched, no work is started and
--- nothing is cached, so the same input always gives the same items. The queries live
--- in `queries/markdown_inline/rmi_images.scm` and `queries/markdown/rmi_diagrams.scm`.
---
--- All rows and columns are 0-based and refer to the buffer. Columns are byte offsets;
--- `end_col` is exclusive.

---@class render-markdown-images.ImageItem
---@field kind "image"
---@field src string source with `<...>` (destinations) or `|...` (embeds) removed, otherwise as written
---@field embed boolean written as an Obsidian/wiki embed, `![[name|size]]`
---@field row integer first row of the `![...]` syntax
---@field col integer its first byte
---@field end_row integer last row of the syntax
---@field end_col integer byte after its last character, on `end_row`
---@field alone_on_line boolean nothing but whitespace shares its lines with it (list and quote markers aside)
---@field in_table boolean inside a pipe table
---@field table_end_row? integer last row of that table; only set when `in_table`
---@field indent integer display columns left of the block's content, from list and blockquote nesting

---@class render-markdown-images.FenceItem
---@field kind "mermaid"|"plantuml"
---@field lang string the language as written after the fence: `Mermaid`, `puml`, ...
---@field source string the diagram, with the fence's list and quote prefix removed from every line
---@field start_row integer row of the opening fence
---@field end_row integer row of the closing fence
---@field indent integer display columns left of the opening fence

---@class render-markdown-images.DiscoverOpts
---@field range? { [1]: integer, [2]: integer } only items touching these rows, both inclusive

---@class render-markdown-images.Discover
local M = {}

--- Block types that hold inline content. The first one above a position is the block
--- the position belongs to; everything left of it on its first line is container syntax.
local LEAF_BLOCKS = {
  paragraph = true,
  atx_heading = true,
  setext_heading = true,
  pipe_table = true,
}

local FENCE_KINDS = { mermaid = "mermaid", plantuml = "plantuml", puml = "plantuml" }

---@param node userdata|userdata[]
---@return TSNode
local function single(node)
  if type(node) == "table" then return node[#node] end
  return node
end

--- Captures of one match, by name, one node each.
---@param query vim.treesitter.Query
---@param match table<integer, TSNode|TSNode[]>
---@return table<string, TSNode>
local function captures(query, match)
  local out = {}
  for id, node in pairs(match) do
    out[query.captures[id]] = single(node)
  end
  return out
end

---@param range? { [1]: integer, [2]: integer }
---@return integer? first, integer? stop exclusive
local function match_rows(range)
  if not range then return nil, nil end
  return range[1], range[2] + 1
end

--- Buffer lines, read once each.
---@param buf integer
---@return fun(row: integer): string
local function line_reader(buf)
  local cache = {}
  return function(row)
    local line = cache[row]
    if line == nil then
      line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
      cache[row] = line
    end
    return line
  end
end

--- What an image source says, once the syntax around it is gone.
---
--- A destination may be wrapped in `<...>` so that it can hold spaces. An embed may carry
--- options after a bar (`![[pic.png|300]]`, `![[pic.png|alt|300]]`), which are not part
--- of the name. Nothing else is touched: `%20` and other escapes are left for whoever
--- resolves the path.
---@param text string
---@param embed boolean
---@return string
function M.clean_src(text, embed)
  text = vim.trim(text)
  if embed then
    text = vim.trim((text:gsub("|.*$", "")))
  else
    local inner = text:match "^<(.*)>$"
    if inner then text = vim.trim(inner) end
  end
  return text
end

--- The innermost block holding inline content at a position, found in the markdown tree.
---@param buf integer
---@param row integer
---@param col integer
---@return TSNode?
local function leaf_block(buf, row, col)
  local ok, node = pcall(vim.treesitter.get_node, { bufnr = buf, pos = { row, col }, lang = "markdown" })
  if not ok then return nil end
  while node and not LEAF_BLOCKS[node:type()] do
    node = node:parent()
  end
  return node
end

--- Where the text of a block begins on a line. A block's node starts where its container's
--- content does, and the up to three spaces a block may be indented by are inside the node.
---@param line string
---@param col integer where the node starts
---@return integer
local function content_col(line, col)
  return col + #line:sub(col + 1):match "^[ \t]*"
end

---@param line string
---@param col integer
---@return integer
local function display_width(line, col)
  return vim.fn.strdisplaywidth(line:sub(1, col))
end

--- Images in an inline markdown tree.
---@param buf integer
---@param root TSNode root of a `markdown_inline` tree
---@param opts? render-markdown-images.DiscoverOpts
---@return render-markdown-images.ImageItem[]
function M.inline(buf, root, opts)
  local query = vim.treesitter.query.get("markdown_inline", "rmi_images")
  if not query then return {} end
  local line = line_reader(buf)
  local first, stop = match_rows(opts and opts.range)

  ---@type table<integer, { image: TSNode, dest?: TSNode, embed?: TSNode }>
  local found = {}
  local order = {} ---@type integer[]
  for _, match in query:iter_matches(root, buf, first, stop) do
    local c = captures(query, match)
    local id = c.image:id()
    if not found[id] then
      found[id] = { image = c.image }
      order[#order + 1] = id
    end
    found[id].dest = found[id].dest or c["image.dest"]
    found[id].embed = found[id].embed or c["image.embed"]
  end

  local items = {} ---@type render-markdown-images.ImageItem[]
  for _, id in ipairs(order) do
    local f = found[id]
    local is_embed = f.dest == nil
    local text = vim.treesitter.get_node_text(f.dest or f.embed, buf)
    local src = M.clean_src(text, is_embed)
    if src ~= "" then
      local row, col, end_row, end_col = f.image:range()
      local block = leaf_block(buf, row, col)
      local block_row, block_col = 0, 0
      if block then
        block_row, block_col = block:range()
      end

      local before = line(row):sub(1, col)
      if block and row == block_row then
        before = before:sub(block_col + 1)
      elseif block then
        -- Later lines of a block repeat the container's prefix: indentation and quote markers.
        before = (before:gsub("^[%s>]*", ""))
      end
      local after = line(end_row):sub(end_col + 1)

      local in_table = block ~= nil and block:type() == "pipe_table"
      local table_end_row ---@type integer?
      if in_table then
        local _, _, block_end_row, block_end_col = block:range()
        -- A node that ends at the start of a line ends on the line before.
        table_end_row = (block_end_col == 0 and block_end_row > block_row) and block_end_row - 1 or block_end_row
      end

      items[#items + 1] = {
        kind = "image",
        src = src,
        embed = is_embed,
        row = row,
        col = col,
        end_row = end_row,
        end_col = end_col,
        alone_on_line = before:match "^%s*$" ~= nil and after:match "^%s*$" ~= nil,
        in_table = in_table,
        table_end_row = in_table and table_end_row or nil,
        indent = block and display_width(line(block_row), content_col(line(block_row), block_col)) or 0,
      }
    end
  end

  table.sort(items, function(a, b)
    if a.row ~= b.row then return a.row < b.row end
    return a.col < b.col
  end)
  return items
end

--- Remove the container prefix a fence's content lines carry.
---
--- A fence in a list item or a quote is not at the start of its lines: each content line
--- repeats the container's syntax, quote markers (`> `) first and then indentation up to
--- where the fence's own text begins. The prefix on the opening line says how much.
---@param prefix string the opening line, up to the opening fence
---@param text string a content line
---@return string
local function strip_container(prefix, text)
  local quotes = select(2, prefix:gsub(">", ""))
  for _ = 1, quotes do
    local rest = text:match "^%s*>%s?(.*)$"
    if not rest then break end
    text = rest
  end
  -- Whatever follows the last quote marker is list indentation (marker text becomes spaces).
  local after_quotes = prefix:match "^.*>%s?(.*)$" or prefix
  local width = vim.fn.strdisplaywidth(after_quotes)
  local spaces = text:match "^( *)"
  return text:sub(math.min(#spaces, width) + 1)
end

--- Diagram fences in a block markdown tree.
---@param buf integer
---@param root TSNode root of a `markdown` tree
---@param opts? render-markdown-images.DiscoverOpts
---@return render-markdown-images.FenceItem[]
function M.fences(buf, root, opts)
  local query = vim.treesitter.query.get("markdown", "rmi_diagrams")
  if not query then return {} end
  local line = line_reader(buf)
  local first, stop = match_rows(opts and opts.range)

  local items = {} ---@type render-markdown-images.FenceItem[]
  for _, match in query:iter_matches(root, buf, first, stop) do
    local c = captures(query, match)
    local kind = FENCE_KINDS[vim.treesitter.get_node_text(c["diagram.lang"], buf):lower()]
    if kind then
      local start_row, start_col = c["diagram.open"]:range()
      local end_row = c["diagram.close"]:range()
      local fence_col = content_col(line(start_row), start_col)
      local prefix = line(start_row):sub(1, fence_col)

      local lines = {} ---@type string[]
      for row = start_row + 1, end_row - 1 do
        lines[#lines + 1] = strip_container(prefix, line(row))
      end
      local source = table.concat(lines, "\n")

      if source:match "%S" then
        items[#items + 1] = {
          kind = kind,
          lang = vim.treesitter.get_node_text(c["diagram.lang"], buf),
          source = source,
          start_row = start_row,
          end_row = end_row,
          indent = display_width(line(start_row), fence_col),
        }
      end
    end
  end

  table.sort(items, function(a, b)
    return a.start_row < b.start_row
  end)
  return items
end

return M
