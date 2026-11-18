# Third-party notices

rumo is released under the MIT License (see `LICENSE`). It includes and adapts the third-party
material listed below.

## mattpocock/skills (MIT)

The skills under `skills/discipline/` are ported from
[mattpocock/skills](https://github.com/mattpocock/skills) version 1.2.3, with the upstream mechanism
kept intact. They are edited only to fix references to commands that rumo renamed or retired.

| Skill | Directory |
|---|---|
| codebase-design | `skills/discipline/codebase-design/` |
| diagnosing-bugs | `skills/discipline/diagnosing-bugs/` |
| domain-modeling | `skills/discipline/domain-modeling/` |
| grilling | `skills/discipline/grilling/` |
| prototype | `skills/discipline/prototype/` |
| research | `skills/discipline/research/` |
| resolving-merge-conflicts | `skills/discipline/resolving-merge-conflicts/` |
| tdd | `skills/discipline/tdd/` |
| wizard | `skills/discipline/wizard/` |
| writing-for-agents | `skills/discipline/writing-for-agents/` |

Upstream license, reproduced as required:

```
MIT License

Copyright (c) 2026 Matt Pocock

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

## shadcn's "improve" advisor (historical inspiration)

The retired `/rumo audit` mode (removed in 0.8.x) grew out of the "improve" advisor skill from the
[shadcn](https://github.com/shadcn-ui) ecosystem. No code from it ships in the current tree; it is
credited here because it shaped early versions of rumo.
