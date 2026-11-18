; The nodes of the block tree whose text is inline markdown: what the markdown injection query hands to
; the markdown_inline parser (`queries/markdown/injections.scm` in Neovim).
;
; render-markdown-images.nvim looks for images in these, parsing their text itself rather than asking for the
; injected trees. Those can be stale (see lua/render-markdown-images/handlers.lua), these cannot: the block
; tree is a single tree.
[
  (inline)
  (pipe_table_cell)
] @inline
