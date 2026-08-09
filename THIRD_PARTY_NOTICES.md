# Third-party notices

This file records third-party software and assets incorporated into or
referenced by this repository, with the attribution required by their
licenses.

## ZenMemory (memory engine)

The `ZenMemory` Swift engine vendored under `Sources/ZenMemory` is an
independent Swift implementation of an agent memory subsystem (memory graph,
typed edges, lexical (BM25) and optional semantic retrieval, cascade retrieval,
confidence lifecycle, and embedding-model compatibility). It is:

- License: MIT (`Copyright (c) 2026 ZenMemory contributors`)

The memory graph design and retrieval behavior derive from the documented data
model and behavior of the following upstream project, whose MIT attribution is
retained:

- Design and behavior: `1jehuang/jcode` (MIT)
- Repository: https://github.com/1jehuang/jcode

The Swift implementation was written for the `ZenMemory` package around that
documented design rather than mechanically translating upstream source
line-for-line. Before redistributing a derivative work, keep the upstream
attribution required by its MIT license and review the upstream repository's
current LICENSE file.
