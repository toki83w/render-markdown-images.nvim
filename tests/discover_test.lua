-- discover: images in inline markdown and diagram fences in block markdown.
-- Run: nvim --headless -u NONE --noplugin -l tests/discover_test.lua

package.path = vim.fn.getcwd() .. "/?.lua;" .. package.path
local h = require "tests.harness"

-- The queries are found on the runtimepath, like any plugin's.
vim.opt.rtp:prepend(h.root)
local discover = require "render-markdown-images.discover"

---@class DiscoverFixture
---@field buf integer
---@field images render-markdown-images.ImageItem[]
---@field fences render-markdown-images.FenceItem[]
---@field parser vim.treesitter.LanguageTree

--- Put `lines` in a markdown buffer and run both discoveries over every tree.
---@param lines string[]
---@param opts? render-markdown-images.DiscoverOpts
---@return DiscoverFixture
local function find(lines, opts)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "markdown"
  vim.treesitter.start(buf, "markdown")
  local parser = vim.treesitter.get_parser(buf, "markdown")
  parser:parse(true)
  local out = { buf = buf, images = {}, fences = {}, parser = parser }
  parser:for_each_tree(function(tree, language_tree)
    if language_tree:lang() == "markdown_inline" then
      vim.list_extend(out.images, discover.inline(buf, tree:root(), opts))
    elseif language_tree:lang() == "markdown" then
      vim.list_extend(out.fences, discover.fences(buf, tree:root(), opts))
    end
  end)
  table.sort(out.images, function(a, b)
    if a.row ~= b.row then return a.row < b.row end
    return a.col < b.col
  end)
  return out
end

---@param fixture DiscoverFixture
---@return string[]
local function srcs(fixture)
  return vim.tbl_map(function(i)
    return i.src
  end, fixture.images)
end

-- ============================================================================
-- Images
-- ============================================================================

h.test("a lone image: whole item", function()
  local f = find { "![alt](pic.png)" }
  h.assert_eq(f.images, {
    {
      kind = "image",
      src = "pic.png",
      embed = false,
      row = 0,
      col = 0,
      end_row = 0,
      end_col = 15,
      alone_on_line = true,
      in_table = false,
      indent = 0,
    },
  }, "one image, alone, at the left margin")
end)

h.test("an image in the middle of text is not alone", function()
  local f = find { "before ![alt](pic.png) after" }
  h.assert_eq(#f.images, 1, "one image")
  h.assert_eq(f.images[1].alone_on_line, false, "text on both sides")
  h.assert_eq({ f.images[1].col, f.images[1].end_col }, { 7, 22 }, "range covers `![alt](pic.png)` only")
  h.assert_eq(find({ "text ![a](a.png)" }).images[1].alone_on_line, false, "text before")
  h.assert_eq(find({ "![a](a.png) text" }).images[1].alone_on_line, false, "text after")
  h.assert_eq(find({ "  ![a](a.png)  " }).images[1].alone_on_line, true, "whitespace around does not count")
end)

h.test("several images on a line, in order, none alone", function()
  local f = find { "![a](a.png) and ![b](b.png) ![[c.png]]" }
  h.assert_eq(srcs(f), { "a.png", "b.png", "c.png" }, "all three, left to right")
  h.assert_eq(
    vim.tbl_map(function(i)
      return i.alone_on_line
    end, f.images),
    { false, false, false },
    "none of them alone"
  )
  h.assert_eq(
    vim.tbl_map(function(i)
      return i.col
    end, f.images),
    { 0, 16, 28 },
    "start columns"
  )
  h.assert_eq(
    vim.tbl_map(function(i)
      return i.embed
    end, f.images),
    { false, false, true },
    "only the last is an embed"
  )
end)

h.test("images on separate lines of one paragraph", function()
  local f = find { "![a](a.png)", "![b](b.png)", "text ![c](c.png)" }
  h.assert_eq(srcs(f), { "a.png", "b.png", "c.png" }, "all found")
  h.assert_eq(
    vim.tbl_map(function(i)
      return i.alone_on_line
    end, f.images),
    { true, true, false },
    "alone is judged per line, not per paragraph"
  )
  h.assert_eq(
    vim.tbl_map(function(i)
      return i.row
    end, f.images),
    { 0, 1, 2 },
    "rows"
  )
end)

h.test("an Obsidian embed with a size: the size is not part of the name", function()
  local f = find { "![[embed.png|300]]" }
  h.assert_eq(#f.images, 1, "one image")
  h.assert_eq(f.images[1].src, "embed.png", "name only")
  h.assert_eq(f.images[1].embed, true, "an embed")
  h.assert_eq(f.images[1].alone_on_line, true, "alone")
  h.assert_eq({ f.images[1].col, f.images[1].end_col }, { 0, 18 }, "the whole `![[...]]`")
  h.assert_eq(srcs(find { "![[embed.png]]" }), { "embed.png" }, "without a size")
  h.assert_eq(srcs(find { "![[sub dir/My Picture.png|alt text|300]]" }), { "sub dir/My Picture.png" }, "alt and size")
  h.assert_eq(srcs(find { "![[ spaced.png | 300 ]]" }), { "spaced.png" }, "padding is trimmed")
end)

h.test("an angle-bracketed destination with spaces", function()
  local f = find { "![](<path with spaces.png>)" }
  h.assert_eq(srcs(f), { "path with spaces.png" }, "brackets removed, spaces kept")
  h.assert_eq(f.images[1].embed, false, "not an embed")
  h.assert_eq(f.images[1].alone_on_line, true, "alone")
end)

h.test("a title does not become part of the source", function()
  h.assert_eq(srcs(find { '![alt](pic.png "A title")' }), { "pic.png" }, "double quoted title")
  h.assert_eq(srcs(find { "![alt](<a b.png> 'T')" }), { "a b.png" }, "bracketed, single quoted title")
end)

h.test("a bar in a standard destination is kept; only embeds lose theirs", function()
  h.assert_eq(srcs(find { "![a](https://example.test/x.png?a=1|2)" }), { "https://example.test/x.png?a=1|2" }, "url")
end)

h.test("URLs are returned as written", function()
  h.assert_eq(
    srcs(find { "![a](https://example.test/a%20b.png?x=1#f)", "![b](a%20b.png)" }),
    { "https://example.test/a%20b.png?x=1#f", "a%20b.png" },
    "no decoding here"
  )
end)

h.test("a description that holds brackets does not make a second item", function()
  local f = find { "![see [1] here](bracketed.png)" }
  h.assert_eq(srcs(f), { "bracketed.png" }, "one item, from the destination")
  h.assert_eq(f.images[1].embed, false, "not an embed")
end)

h.test("images with no source are skipped", function()
  h.assert_eq(find({ "![]()", "![[ ]]", "![alt](<>)" }).images, {}, "nothing to show")
end)

h.test("links and plain brackets are not images", function()
  h.assert_eq(find({ "[text](link.png) [[wiki]] [ref]: x" }).images, {}, "no `!`, no image")
end)

h.test("an image inside a link is found", function()
  local f = find { "[![badge](badge.png)](https://example.test)" }
  h.assert_eq(srcs(f), { "badge.png" }, "the inner image only")
  h.assert_eq(f.images[1].alone_on_line, false, "the link syntax shares its line")
end)

h.test("a multi-line image reports where it ends", function()
  local f = find { "![a long", "description](pic.png)" }
  h.assert_eq(#f.images, 1, "one image")
  local i = f.images[1]
  h.assert_eq({ i.row, i.col, i.end_row, i.end_col }, { 0, 0, 1, 21 }, "range across two rows")
  h.assert_eq(i.alone_on_line, true, "alone: nothing else on either row")
end)

h.test("a heading's image is not alone, and is not indented", function()
  local f = find { "# Title ![h](h.png)", "", "## ![h2](h.png)" }
  h.assert_eq(
    vim.tbl_map(function(i)
      return i.alone_on_line
    end, f.images),
    { false, false },
    "the `#` marker shares the line"
  )
  h.assert_eq(
    vim.tbl_map(function(i)
      return i.indent
    end, f.images),
    { 0, 0 },
    "no container, no indent"
  )
end)

-- ---------------------------------------------------------------------------
-- Containers: lists, quotes, tables
-- ---------------------------------------------------------------------------

h.test("an image in a list item: indent is the content column", function()
  local f = find { "- ![a](a.png)", "", "1. ![b](b.png)", "", "10. ![c](c.png)" }
  h.assert_eq(
    vim.tbl_map(function(i)
      return i.indent
    end, f.images),
    { 2, 3, 4 },
    "marker and space: `- `, `1. `, `10. `"
  )
  h.assert_eq(
    vim.tbl_map(function(i)
      return i.alone_on_line
    end, f.images),
    { true, true, true },
    "the list marker does not count as text on the line"
  )
end)

h.test("a nested list adds up", function()
  local f = find { "- one", "  - two", "    - ![deep](deep.png)", "", "* text ![x](x.png)" }
  h.assert_eq(
    vim.tbl_map(function(i)
      return i.indent
    end, f.images),
    { 6, 2 },
    "indent by nesting"
  )
  h.assert_eq(
    vim.tbl_map(function(i)
      return i.alone_on_line
    end, f.images),
    { true, false },
    "alone only without other text"
  )
end)

h.test("an image on a later line of a list item's paragraph", function()
  local f = find { "- first line", "  ![b](b.png)", "  more text" }
  h.assert_eq(#f.images, 1, "one image")
  h.assert_eq(f.images[1].indent, 2, "same indent as the item's text")
  h.assert_eq(f.images[1].alone_on_line, true, "alone on its line")
end)

h.test("an image in a blockquote", function()
  local f = find { "> ![q](q.png)", "", "> text ![r](r.png)", "", "> > ![n](n.png)" }
  h.assert_eq(
    vim.tbl_map(function(i)
      return i.indent
    end, f.images),
    { 2, 2, 4 },
    "`> ` and `> > `"
  )
  h.assert_eq(
    vim.tbl_map(function(i)
      return i.alone_on_line
    end, f.images),
    { true, false, true },
    "quote markers do not count as text"
  )
end)

h.test("an image on a later line of a blockquote", function()
  local f = find { "> first", "> ![q](q.png)" }
  h.assert_eq(#f.images, 1, "one image")
  h.assert_eq(f.images[1].indent, 2, "indent of the quote content")
  h.assert_eq(f.images[1].alone_on_line, true, "alone")
end)

h.test("an image in a quote inside a list", function()
  local f = find { "- item", "", "  > ![q](q.png)" }
  h.assert_eq(f.images[1].indent, 4, "list indent plus quote marker")
  h.assert_eq(f.images[1].alone_on_line, true, "alone")
end)

h.test("up to three spaces of indentation count as indent", function()
  local f = find { "   ![a](a.png)", "", "  text ![b](b.png)", "", "  # head ![c](c.png)" }
  h.assert_eq(
    vim.tbl_map(function(i)
      return i.indent
    end, f.images),
    { 3, 2, 2 },
    "the spaces before the block's text"
  )
  h.assert_eq(f.images[1].alone_on_line, true, "and they are not text")
end)

h.test("images in a pipe table are marked, and never alone", function()
  local f = find {
    "| a | b |",
    "| - | - |",
    "| ![c](c.png) | x |",
    "| y | ![d](d.png) |",
  }
  h.assert_eq(srcs(f), { "c.png", "d.png" }, "both cells")
  h.assert_eq(
    vim.tbl_map(function(i)
      return i.in_table
    end, f.images),
    { true, true },
    "in_table"
  )
  h.assert_eq(
    vim.tbl_map(function(i)
      return i.alone_on_line
    end, f.images),
    { false, false },
    "the pipes share the line"
  )
  h.assert_eq(f.images[1].indent, 0, "table at the margin")
  h.assert_eq(find({ "![x](x.png)" }).images[1].in_table, false, "ordinary images are not")
end)

h.test("an image in a table knows where the table ends", function()
  local f = find { "intro", "", "| a | b |", "| - | - |", "| ![c](c.png) | x |", "| y | z |", "", "after ![d](d.png)" }
  h.assert_eq(f.images[1].table_end_row, 5, "the last row of the table, not the row after it")
  h.assert_eq(f.images[2].table_end_row, nil, "an image outside tables has none")
  local at_end = find { "| a |", "| - |", "| ![c](c.png) |" }
  h.assert_eq(at_end.images[1].table_end_row, 2, "a table that ends the document")
end)

h.test("a table inside a list item has the list's indent", function()
  local f = find { "- item", "", "  | a |", "  | - |", "  | ![c](c.png) |" }
  h.assert_eq(f.images[1].in_table, true, "in a table")
  h.assert_eq(f.images[1].indent, 2, "indented with the item")
end)

h.test("images inside code are not images", function()
  local f = find { "```", "![a](a.png)", "```", "", "`![b](b.png)`", "", "    ![c](c.png)" }
  h.assert_eq(f.images, {}, "fenced, inline and indented code")
end)

-- ============================================================================
-- Fences
-- ============================================================================

h.test("a mermaid fence", function()
  local f = find { "text", "", "```mermaid", "graph TD", "  A --> B", "```", "", "more" }
  h.assert_eq(f.fences, {
    { kind = "mermaid", lang = "mermaid", source = "graph TD\n  A --> B", start_row = 2, end_row = 5, indent = 0 },
  }, "kind, source with inner indentation kept, opening and closing rows")
end)

h.test("a plantuml fence, and `puml` as its short name", function()
  local f =
    find { "```plantuml", "@startuml", "A -> B", "@enduml", "```", "", "```puml", "@startuml", "@enduml", "```" }
  h.assert_eq(
    vim.tbl_map(function(i)
      return i.kind
    end, f.fences),
    { "plantuml", "plantuml" },
    "both are plantuml"
  )
  h.assert_eq(f.fences[1].source, "@startuml\nA -> B\n@enduml", "source")
  h.assert_eq({ f.fences[2].start_row, f.fences[2].end_row }, { 6, 9 }, "rows of the second")
end)

h.test("the language is case-insensitive", function()
  local f = find { "```Mermaid", "graph", "```", "", "```PLANTUML", "@startuml", "```", "", "```PlantUml", "x", "```" }
  h.assert_eq(
    vim.tbl_map(function(i)
      return i.kind
    end, f.fences),
    { "mermaid", "plantuml", "plantuml" },
    "mixed case"
  )
end)

h.test("the language is returned as written", function()
  local f = find { "```Mermaid", "graph", "```", "", "```puml", "@startuml", "```" }
  h.assert_eq(
    vim.tbl_map(function(i)
      return i.lang
    end, f.fences),
    { "Mermaid", "puml" },
    "as typed"
  )
end)

h.test("tilde fences work", function()
  h.assert_eq(
    vim.tbl_map(function(i)
      return i.kind
    end, find({ "~~~mermaid", "graph", "~~~" }).fences),
    { "mermaid" },
    "~~~"
  )
end)

h.test("other languages are ignored", function()
  local f = find {
    "```lua",
    "print(1)",
    "```",
    "",
    "```python",
    "x = 1",
    "```",
    "",
    "```mermaidx",
    "graph",
    "```",
    "",
    "```",
    "no language",
    "```",
    "",
    "```not-mermaid",
    "graph",
    "```",
  }
  h.assert_eq(f.fences, {}, "none are diagrams")
end)

h.test("an unclosed fence is ignored", function()
  h.assert_eq(find({ "```mermaid", "graph TD", "  A --> B" }).fences, {}, "ends with the document")
  h.assert_eq(find({ "text", "", "```plantuml", "@startuml" }).fences, {}, "plantuml too")
  local f = find { "```mermaid", "graph TD", "", "text after" }
  h.assert_eq(f.fences, {}, "text after an unclosed fence belongs to it")
end)

h.test("a fence closed inside its container is closed, one cut off by it is not", function()
  h.assert_eq(#find({ "> ```mermaid", "> graph", "> ```" }).fences, 1, "closed in the quote")
  h.assert_eq(find({ "> ```mermaid", "> graph", "", "```" }).fences, {}, "the quote ended before the closing fence")
end)

h.test("an empty fence is ignored", function()
  h.assert_eq(find({ "```mermaid", "```" }).fences, {}, "no content line")
  h.assert_eq(find({ "```mermaid", "", "   ", "```" }).fences, {}, "blank content")
end)

h.test("only the diagram fences are returned, in document order", function()
  local f = find {
    "```plantuml",
    "@startuml",
    "```",
    "",
    "```lua",
    "x",
    "```",
    "",
    "```mermaid",
    "graph",
    "```",
  }
  h.assert_eq(
    vim.tbl_map(function(i)
      return { i.kind, i.start_row }
    end, f.fences),
    { { "plantuml", 0 }, { "mermaid", 8 } },
    "two, in order"
  )
end)

h.test("a fence in a list item: indent, and the list's prefix is removed from the source", function()
  local f = find { "- item", "  ```mermaid", "  graph TD", "    A --> B", "  ```", "", "after" }
  h.assert_eq(f.fences, {
    { kind = "mermaid", lang = "mermaid", source = "graph TD\n  A --> B", start_row = 1, end_row = 4, indent = 2 },
  }, "indent 2, content outdented by 2, deeper indentation kept")
end)

h.test("a fence on the marker's own line", function()
  local f = find { "- ```mermaid", "  graph TD", "  ```" }
  h.assert_eq(#f.fences, 1, "found")
  h.assert_eq(f.fences[1].indent, 2, "after `- `")
  h.assert_eq(f.fences[1].source, "graph TD", "content aligned with the fence")
end)

h.test("a fence in a nested list", function()
  local f =
    find { "1. one", "   - two", "     ```plantuml", "     @startuml", "     A -> B", "     @enduml", "     ```" }
  h.assert_eq(f.fences[1].indent, 5, "indent")
  h.assert_eq(f.fences[1].source, "@startuml\nA -> B\n@enduml", "source")
  h.assert_eq({ f.fences[1].start_row, f.fences[1].end_row }, { 2, 6 }, "rows")
end)

h.test("a fence in a blockquote: markers are removed from the source", function()
  local f = find { "> ```mermaid", "> graph TD", ">   A --> B", "> ```" }
  h.assert_eq(f.fences, {
    { kind = "mermaid", lang = "mermaid", source = "graph TD\n  A --> B", start_row = 0, end_row = 3, indent = 2 },
  }, "quote prefix removed, inner indentation kept")
end)

h.test("a fence in a nested blockquote", function()
  local f = find { "> > ```PlantUML", "> > @startuml", "> > A -> B", "> > @enduml", "> > ```" }
  h.assert_eq(f.fences[1].kind, "plantuml", "kind")
  h.assert_eq(f.fences[1].indent, 4, "indent")
  h.assert_eq(f.fences[1].source, "@startuml\nA -> B\n@enduml", "source")
end)

h.test("a fence in a list inside a blockquote", function()
  local f = find { "> - item", ">   ```mermaid", ">   graph TD", ">   ```" }
  h.assert_eq(f.fences[1].indent, 4, "`> ` plus the list indent")
  h.assert_eq(f.fences[1].source, "graph TD", "both prefixes removed")
end)

h.test("a fence indented by up to three spaces", function()
  local f = find { "   ```mermaid", "   graph TD", "   ```" }
  h.assert_eq(f.fences[1].indent, 3, "indent")
  h.assert_eq(f.fences[1].source, "graph TD", "content outdented the same")
end)

h.test("a blank line inside a fence is kept", function()
  local f = find { "```mermaid", "graph TD", "", "  A --> B", "```" }
  h.assert_eq(f.fences[1].source, "graph TD\n\n  A --> B", "blank line between")
end)

h.test("a longer fence can hold a shorter one", function()
  local f = find { "````mermaid", "graph TD", "```", "A", "````" }
  h.assert_eq(#f.fences, 1, "one fence")
  h.assert_eq(f.fences[1].source, "graph TD\n```\nA", "the inner fence is content")
  h.assert_eq({ f.fences[1].start_row, f.fences[1].end_row }, { 0, 4 }, "closed by the long fence")
end)

-- ============================================================================
-- Ranges
-- ============================================================================

h.test("range limits both discoveries to the rows given", function()
  local lines = {
    "![a](a.png)", -- 0
    "",
    "```mermaid", -- 2
    "graph",
    "```", -- 4
    "",
    "![b](b.png)", -- 6
    "",
    "```plantuml", -- 8
    "@startuml",
    "```", -- 10
  }
  h.assert_eq(srcs(find(lines, { range = { 0, 1 } })), { "a.png" }, "first image only")
  h.assert_eq(srcs(find(lines, { range = { 5, 7 } })), { "b.png" }, "second image only")
  h.assert_eq(
    vim.tbl_map(function(i)
      return i.kind
    end, find(lines, { range = { 2, 4 } }).fences),
    { "mermaid" },
    "first fence only"
  )
  h.assert_eq(
    vim.tbl_map(function(i)
      return i.kind
    end, find(lines, { range = { 3, 3 } }).fences),
    { "mermaid" },
    "a range inside a fence still finds it"
  )
  h.assert_eq(find(lines, { range = { 6, 7 } }).fences, {}, "no fence in the rows")
  h.assert_eq(#find(lines).images, 2, "no range: everything")
  h.assert_eq(#find(lines).fences, 2, "no range: everything")
end)

-- ============================================================================
-- clean_src
-- ============================================================================

h.test("clean_src", function()
  h.assert_eq(discover.clean_src("pic.png", false), "pic.png", "plain")
  h.assert_eq(discover.clean_src("  pic.png ", false), "pic.png", "trimmed")
  h.assert_eq(discover.clean_src("<a b.png>", false), "a b.png", "brackets")
  h.assert_eq(discover.clean_src("<a b.png", false), "<a b.png", "an unmatched bracket stays")
  h.assert_eq(discover.clean_src("<>", false), "", "empty brackets")
  h.assert_eq(discover.clean_src("a|b.png", false), "a|b.png", "a destination keeps its bars")
  h.assert_eq(discover.clean_src("pic.png|300", true), "pic.png", "embed size")
  h.assert_eq(discover.clean_src("pic.png|alt|300", true), "pic.png", "embed alt and size")
  h.assert_eq(discover.clean_src("<pic.png>", true), "<pic.png>", "an embed keeps angle brackets")
  h.assert_eq(discover.clean_src("|300", true), "", "only options")
end)

-- ============================================================================
-- Fixtures
-- ============================================================================

--- Run discovery over a fixture file.
---@param name string
---@return DiscoverFixture
local function find_file(name)
  return find(vim.fn.readfile(h.root .. "/tests/fixtures/" .. name))
end

h.test("showcase.md: two table images and the Mermaid diagram", function()
  local f = find_file "showcase.md"
  h.assert_eq(
    srcs(f),
    { "https://cdn.pixabay.com/photo/2011/12/13/14/31/earth-11015_640.jpg", "https://http.cat/200.jpg" },
    "the two remote images"
  )
  h.assert_eq(
    vim.tbl_map(function(i)
      return i.in_table
    end, f.images),
    { true, true },
    "both in the table"
  )
  h.assert_eq(#f.fences, 1, "one diagram fence; the python and lua fences are not")
  h.assert_eq(f.fences[1].kind, "mermaid", "mermaid")
  h.assert_eq(f.fences[1].source:match "^[^\n]*", "graph LR", "first source line")
  h.assert_eq(f.fences[1].source:match "[^\n]*$", "    style F fill:#fff3e0,color:#e65100", "last source line")
  local lines = vim.api.nvim_buf_get_lines(f.buf, 0, -1, false)
  h.assert_eq(lines[f.fences[1].start_row + 1], "```mermaid", "start_row is the opening fence")
  h.assert_eq(lines[f.fences[1].end_row + 1], "```", "end_row is the closing fence")
  h.assert_eq(
    f.fences[1].end_row - f.fences[1].start_row - 1,
    #vim.split(f.fences[1].source, "\n"),
    "one row per source line"
  )
end)

h.test("wikilinks.md", function()
  local f = find_file "wikilinks.md"
  h.assert_eq(srcs(f), {
    "embed.png",
    "embed.png",
    "sub folder/My Picture.png",
    "one.png",
    "two.png",
    "Some note#Heading",
    "standard.png",
    "wiki.png",
    "path with spaces.png",
    "bracketed.png",
  }, "every usable image, in order; `![[ ]]` and `![]()` are skipped")
  h.assert_eq(
    vim.tbl_map(function(i)
      return i.embed
    end, f.images),
    { true, true, true, true, true, true, false, true, false, false },
    "which are embeds"
  )
  h.assert_eq(
    vim.tbl_map(function(i)
      return i.alone_on_line
    end, f.images),
    { true, true, false, false, false, false, false, false, true, true },
    "which stand alone"
  )
  h.assert_eq(#f.fences, 0, "no fences")
end)

h.finish "discover_test"
