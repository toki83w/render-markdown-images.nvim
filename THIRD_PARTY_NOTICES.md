# Third-party notices

render-markdown-images.nvim is MIT-licensed (see `LICENSE`). It contains code and data from the projects below,
used under their licences.

## md-render.nvim — MIT

Taken from the `toki83w/md-render.nvim` fork of [`delphinus/md-render.nvim`](https://github.com/delphinus/md-render.nvim):

- `lua/render-markdown-images/image.lua`, `placeholder.lua`, `async.lua`, `tty.lua`, `obsidian.lua`
  (renamed, with the preview-only parts removed and the configuration, probe and image-id handling changed),
- `scripts/vendor-async.sh` and `lua/render-markdown-images/vendor/README.md` (retargeted),
- a good part of the tests (`tests/image_test.lua`, `placeholder_test.lua`, `tty_test.lua`, `async_test.lua`,
  `plantuml_test.lua`, `plantuml_kitty_test.lua`, the ported parts of others) and the fixtures
  `tests/fixtures/test_4x4.png` and `tests/fixtures/demo_160x120.png` (`assets/demo/test.png` there).

The licence of md-render.nvim:

```
MIT License

Copyright (c) 2026 delphinus

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Neovim's `vim.async` — Apache-2.0

`lua/render-markdown-images/vendor/async.lua` and `vendor/async/` are Neovim's `runtime/lua/vim/async.lua` and
`async/` (revision in `vendor/async/REVISION`), with only the `require` paths rewritten. Neovim took them from
[lewis6991/async.nvim](https://github.com/lewis6991/async.nvim) (MIT). The Apache-2.0 licence of Neovim is in
`lua/render-markdown-images/vendor/LICENSE-neovim.txt`. How to re-sync is in `vendor/README.md`.

## snacks.nvim — Apache-2.0

[folke/snacks.nvim](https://github.com/folke/snacks.nvim) is not a dependency and no file of it is included. Two of its
ideas are used, and acknowledged here: the form of the treesitter query that finds images and wikilink embeds
(`queries/markdown_inline/images.scm`, which `queries/markdown_inline/rmi_images.scm` follows), and not attaching
virtual lines to a concealed row (`lua/snacks/image/placement.lua`). snacks.nvim is Apache-2.0 licensed:
<https://www.apache.org/licenses/LICENSE-2.0>.

## render-markdown.nvim — MIT

[MeanderingProgrammer/render-markdown.nvim](https://github.com/MeanderingProgrammer/render-markdown.nvim) is the
plugin this one extends. Nothing of it is included; its custom handler API and its `replace` mark are used.
