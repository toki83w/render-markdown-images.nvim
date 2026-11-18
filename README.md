# render-markdown-images.nvim

Images and diagrams in the markdown source buffer, drawn through
[render-markdown.nvim](https://github.com/MeanderingProgrammer/render-markdown.nvim)'s custom handlers.

render-markdown.nvim decorates markdown in place but draws no pictures. This plugin adds them: `![alt](pic.png)`,
`![[pic.png|300]]`, and Mermaid and PlantUML fences, shown as real images in terminals that implement the
[Kitty graphics protocol](https://sw.kovidgoyal.net/kitty/graphics-protocol/) with Unicode placeholders. The
images are made of ordinary text cells, so scrolling, wrapping, splits and tmux panes are Neovim's business.

- Local PNG, JPEG and WebP; remote images (downloaded with curl, cached); Obsidian vault names and embeds.
- Mermaid (`mmdr`, `mmdc` or `npx`) and PlantUML (`plantuml`, `java -jar $PLANTUML_JAR`, or a server you name).
- Two modes, for images and diagrams separately: `below` (the picture under its source) and `replace` (the picture
  in the place of its source; the source comes back while the cursor is on it).
- Sized to the window: the text width less the indent, never larger than the file, never taller than the window.
- Nothing is waited for: downloads and renderings happen in the background, and the buffer is drawn again when
  one is ready. Only what is in view is asked for.

## Requirements

- Neovim 0.12 or newer (`vim.api.nvim_ui_send`). `replace` mode needs 0.11's `conceal_lines`, which 0.12 has.
- [render-markdown.nvim](https://github.com/MeanderingProgrammer/render-markdown.nvim). `replace` mode needs
  one that draws a mark's `replace` (v8.14.0 or newer); with an older one, images go below their source.
- A terminal that implements the Kitty graphics protocol **with Unicode placeholders** .
- `'termguicolors'` on and `'ambiwidth'` `single`. The image id travels in a 24-bit colour, and the placeholder
  character is ambiguous-width.
- In tmux (3.3 or newer): `set -g allow-passthrough on`, and `RGB` and `usstyle` in `terminal-features` for your
  terminal. See [tmux](#tmux).
- Optional tools, each for one kind of source:

  | For           | Tool                                                             |
  |---------------|------------------------------------------------------------------|
  | remote images | `curl`                                                           |
  | JPEG and WebP | `ffmpeg` or `magick` (`sips` on macOS)                           |
  | Mermaid       | `mmdr`, `mmdc` (mermaid-cli), or `npx`                           |
  | PlantUML      | `plantuml`, or `java` with `$PLANTUML_JAR`, or `plantuml_server` |

`:checkhealth render-markdown-images` reports every one of these and says what to change.

## Installation

The plugin has no commands and nothing to enable: it is a set of handlers, registered with render-markdown.nvim.

lazy.nvim:

```lua
{
  "MeanderingProgrammer/render-markdown.nvim",
  dependencies = { "you/render-markdown-images.nvim" },
  opts = function()
    return {
      custom_handlers = require("render-markdown-images").handlers(),
    }
  end,
}
```

`require("render-markdown-images").setup({ ... })` is only needed to change [options](#options); `handlers()` works
without it. To turn the plugin off, leave `custom_handlers` out.

If you already have custom handlers, merge: `handlers()` returns a table with one entry, `markdown`. It has
`extends = true`, so render-markdown.nvim's own markdown rendering goes on as before.

## Options

```lua
require("render-markdown-images").setup({
  images = { mode = "below" },   -- "below" | "replace"
  diagrams = {
    mode = "below",              -- "below" | "replace"
    mermaid = true,              -- false: leave ```mermaid fences as code
    plantuml = true,             -- false: leave ```plantuml fences as code
  },
  plantuml_server = nil,         -- e.g. "https://www.plantuml.com/plantuml"; see Privacy
})
```

Unknown options are an error, so a typo does not go unnoticed. `setup()` starts from the defaults every time.

| Option              | Default   |                                                              |
|---------------------|-----------|--------------------------------------------------------------|
| `images.mode`       | `"below"` | what to do with the source of an image, see [Modes](#modes)  |
| `diagrams.mode`     | `"below"` | the same for Mermaid and PlantUML fences                     |
| `diagrams.mermaid`  | `true`    | `false`: no Mermaid work at all                              |
| `diagrams.plantuml` | `true`    | `false`: no PlantUML work at all                             |
| `plantuml_server`   | `nil`     | render PlantUML on this server when no local renderer worked |

### Modes

- **`below`**: the picture is drawn in the lines under its source, which stays visible. A picture on a line of its
  own goes under that line; one in the middle of text goes under the line it is on; images that share a line stack
  left to right. A diagram goes under its closing fence (or under the last line of its source when
  render-markdown.nvim conceals the fence line, which is its default, as Neovim would not draw anything under a
  concealed line).
- **`replace`**: the source is hidden and the picture takes its place. An image alone on its line at the left
  margin, and a diagram fence, are hidden whole; an image among text, or in a list item or a quote, loses only its
  `![...](...)`, so the bullet or the quote marker stays. When the cursor is on the source (render-markdown.nvim's
  `anti_conceal`, with its `above` and `below`), the source comes back and the picture goes. A source whose picture
  is not ready, or failed, is never hidden.

In both modes an image in a table cell goes below the table: a hole in the table would break it.

Where the source is the last thing in the buffer there is nothing to draw above, so in `replace` mode the source is
concealed and the picture goes under the line before it; that one stays while you edit the source, above it.

## What is drawn

| Source                                                                                    |                                                                                   |
|-------------------------------------------------------------------------------------------|-----------------------------------------------------------------------------------|
| `![alt](path/to/pic.png)`, `![alt](<a path with spaces.png>)`, `%20` escapes              | relative to the note, `~/...` and absolute paths too                              |
| `![alt](https://example.org/pic.png)`                                                     | downloaded with curl, at most 10 s and 20 MB, http(s) only, redirects included    |
| `![[pic.png]]`, `![[pic.png\|300]]`, `![alt](pic.png)` in a note inside an Obsidian vault | found by name in the vault: its attachments folder, its root, then anywhere in it |
| ```` ```mermaid ````, ```` ```plantuml ````, ```` ```puml ````                            | rendered when the fence is closed and not empty; any case                         |

PNG is sent as it is; JPEG and WebP are converted to PNG (at most 2000 px) and the result is cached. Badges
(`img.shields.io`, ...), GIFs, videos and other schemes (`data:`, `mailto:`, ...) are left alone.

Size: the width of the window's text area (less the number column, sign column and so on) less the indent of the
list or quote the image is in, at most the height of the window, at most 297 cells, and never larger than the
image's pixels at your terminal's cell size.

Failures are quiet. An image that cannot be found, downloaded or rendered just stays as its source, and a line goes
to the log (`stdpath("state")/render-markdown-images.log`), once per cause. A failed entry is tried again when
it is asked for more than 30 s later; a download is attempted four times before that.

Caches are in `stdpath("cache")/render-markdown-images/`: `images` (downloads), `converted`, `mermaid`, `plantuml`.
Mermaid diagrams are drawn in the editor's colours, and made again when `:colorscheme` or `'background'` change them.

## tmux

Graphics sequences have to pass through tmux to the terminal:

```tmux
set -g allow-passthrough on
# the terminal's name as tmux knows it: `tmux display -p '#{client_termname}'`
set -as terminal-features ',foot*:RGB'
set -as terminal-features ',foot*:usstyle'
```

`RGB` carries the image id (a colour), `usstyle` the placement id (an underline colour). With the tmux and
terminal of the author, the terminal does not answer the graphics query through tmux (and Neovim never asks at run
time), yet images are drawn: `:checkhealth` says so and does not call it a failure.

## Troubleshooting

Start with `:checkhealth render-markdown-images`.

- **Nothing is drawn, the source stays**: the image was not found (the path is relative to the note), is a format
  that is skipped, or failed: see the log. Is it in view? Only the paragraphs render-markdown.nvim has in view are
  asked for. Is `custom_handlers` registered? The health check looks.
- **The source is hidden and blank rows are left (`replace`)**: the terminal does not draw the placeholders. In tmux:
  `allow-passthrough`, `RGB`, `usstyle`. Is `'termguicolors'` on?
- **Garbled characters where an image should be**: `'ambiwidth'` is not `single`, or the terminal has no Unicode
  placeholder support.
- **Images twice**: snacks.nvim draws them in documents too; set `image = { doc = { enabled = false } }` there.
- **A paragraph is missing its render-markdown.nvim decoration now and then**: seen with render-markdown.nvim alone on
  Neovim 0.12.3: after partial treesitter parses, Neovim can hand a plugin the wrong tree for a paragraph. This plugin
  does not use those trees, so its images are not affected.

## Limitations

- Marks belong to the buffer: with one buffer in two windows of different widths, the picture is drawn at the size
  of the window rendered last.
- A picture is as tall as its rows: it is capped at the height of the window, and the virtual lines of `below` mode
  go as soon as the line they hang from scrolls past the top of the window.
- An image file that changes on disk is not drawn again until the session ends (the path is its key).
- Reference-style images (`![alt][ref]`) and animations are not drawn.
- Remote images are fetched when a document with them is in view; see [Privacy](#privacy-and-security).
- Windows is not a target.

## Privacy and security

- **Remote images are downloaded when you open or scroll to a document that links them.** The server learns that you
  opened it, as it would from a browser. Badges, GIFs and videos are skipped; others are fetched whatever the link
  claims to be, and discarded if they are not an image. `set_download_fn` can take over, e.g. to refuse hosts.
- **PlantUML**: the source of a diagram only leaves your machine when you set `plantuml_server`, and then only when no
  local renderer produced the picture. Mermaid is always rendered locally.
- Files are handed to the terminal as temporary copies named `tty-graphics-protocol`, in your temp directory,
  which the terminal deletes after reading. Only this plugin's own image ids are deleted on exit.

## Lua API

```lua
local rmi = require("render-markdown-images")

rmi.setup(opts)          -- see Options; raises on a bad option and keeps the previous one
rmi.handlers()           -- the table for render-markdown.nvim's `custom_handlers`
rmi.set_download_fn(fn)  -- take over downloads: fn(url, output_path, callback) -> boolean
```

`set_download_fn`: `fn` is called before curl for each URL. To take the job it returns `true` and, when done, calls
`callback(true)` after writing the image to `output_path` (or `callback(false)`); returning `false` leaves the URL
to curl. Pass `nil` to remove it.

## Development

```sh
make check          # stylua --check, then every tests/*_test.lua headless
make test           # only the tests
make format
```

The tests need a render-markdown.nvim checkout for the integration tests: `$RENDER_MARKDOWN_PATH`,
`~/software/neovim_plugins/render-markdown.nvim` or lazy.nvim's data directory (`RMI_REQUIRE_RENDER_MARKDOWN=1`
makes a missing one a failure instead of a skip). `scripts/` has demos:

```sh
nvim -u scripts/demo_below.lua scripts/demo_below.md                       # images and diagrams under their source
RMI_MODE=replace nvim -u scripts/demo_below.lua scripts/demo_below.md      # in place of it; :RmiDiagnose says what is going on
nvim -u scripts/demo_below.lua tests/fixtures/vault/notes/note.md          # an Obsidian vault
```

## Credits and licences

MIT, see `LICENSE`. This plugin stands on others' work; the notices are in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md):

- **md-render.nvim** (MIT): the image core, `image.lua`, `placeholder.lua`, `async.lua`, `tty.lua`,
  `obsidian.lua`, the vendoring script, a good part of the tests and one demo image, taken from the
  `toki83w/md-render.nvim` fork of `delphinus/md-render.nvim`.
- **Neovim's `vim.async`** (Apache-2.0), vendored in `lua/render-markdown-images/vendor/`, from the Neovim repository,
  which took it from lewis6991/async.nvim (MIT).
- **snacks.nvim** (Apache-2.0): the form of the image query for wikilink embeds, and the idea of moving
  virtual lines off a concealed line.
- **render-markdown.nvim** (MIT): the handler API, and its `replace` mechanism, which is how `replace` mode works.
