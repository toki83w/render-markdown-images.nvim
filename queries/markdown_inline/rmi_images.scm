; Images in inline markdown, for render-markdown-images.nvim.
;
; The pattern follows snacks.nvim's `queries/markdown_inline/images.scm`
; (Apache-2.0): the source is the link destination of `![alt](src)`, or, for an
; Obsidian/wiki embed `![[name|size]]`, the text of the shortcut link inside the
; description. Stripping `<...>` and `|...` is done in lua/render-markdown-images/discover.lua,
; where it can be tested, instead of with `#gsub!` here.
;
; An image whose description holds a bracketed span as well as a destination,
; such as `![see [1]](a.png)`, matches both alternatives; discover.lua keeps one
; item per `@image` node and prefers the destination.
(image
  [
    (link_destination) @image.dest
    (image_description
      (shortcut_link
        (link_text) @image.embed))
  ]) @image
