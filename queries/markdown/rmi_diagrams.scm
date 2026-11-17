; Diagram fences in block markdown, for render-markdown-images.nvim.
;
; Only a fence that is closed matches: it needs two delimiters. A fence still
; being typed (no closing line) would otherwise render a half-written diagram on
; every keystroke. The language is compared case-insensitively; `puml` is the
; usual short name of `plantuml`.
(fenced_code_block
  (fenced_code_block_delimiter) @diagram.open
  (info_string
    (language) @diagram.lang)
  (code_fence_content)? @diagram.content
  (fenced_code_block_delimiter) @diagram.close
  (#match? @diagram.lang "\\v\\c^(mermaid|plantuml|puml)$")) @diagram
