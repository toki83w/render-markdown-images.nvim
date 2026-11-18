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
