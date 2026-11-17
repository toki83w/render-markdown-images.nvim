# Images below their lines

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

The end.
