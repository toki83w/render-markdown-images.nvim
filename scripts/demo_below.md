# Images and diagrams

Start with `RMI_MODE=replace` to hide the sources: the picture takes their place, and the source comes
back while the cursor is on it. Otherwise each picture is drawn under its source.

A picture on its own line, drawn under it:

![A blue gradient](../tests/fixtures/demo_160x120.png)

Text before ![inline](../tests/fixtures/demo_160x120.png) and after: the image goes under the line.

Two on one line: ![one](../tests/fixtures/demo_160x120.png) ![two](../tests/fixtures/demo_160x120.png)

- A list item
  - Nested, and the picture follows its text: ![nested](../tests/fixtures/demo_160x120.png)

> A quote with a picture ![quoted](../tests/fixtures/demo_160x120.png)

| Column | Picture |
| ------ | ------- |
| a      | ![cell](../tests/fixtures/demo_160x120.png) |
| b      | text    |

A file that does not exist draws nothing: ![missing](nothing-here.png)

## Remote images

Downloaded with curl the first time (10 s and 20 MB at most), then served from the cache: close Neovim and
open this again, and it is there at once. Badges, GIFs and videos are not fetched.

![A cat](https://http.cat/200.jpg)

Among text ![cat](https://http.cat/404.jpg) it goes below, as a local one does.

![A badge, skipped](https://img.shields.io/badge/build-passing-green.svg)

## Obsidian

A note inside a vault finds `![[name.png]]` embeds by name, wherever they are in the vault. See
`tests/fixtures/vault/notes/note.md` (`nvim -u scripts/demo_below.lua tests/fixtures/vault/notes/note.md`).

## Diagrams

A Mermaid fence is drawn under its source (needs `mmdr`, `mmdc` or `npx`):

```mermaid
graph LR
    A[Edit] --> B[Render] --> C[Look]
    C --> A
```

A PlantUML fence too (needs `plantuml`, or `java` with `$PLANTUML_JAR`):

```plantuml
@startuml
Alice -> Bob: Hello
Bob --> Alice: Hi
@enduml
```

Without the tools nothing is drawn and the reason goes to
`:lua print(require("render-markdown-images.log").path())`.

The end.
