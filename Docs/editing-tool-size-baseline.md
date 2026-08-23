# Editing tool size baseline

Byte counts use compact UTF-8 JSON. They are provider-independent; provider token counts remain part of the model-driven release smoke test.

| Metric | Before | After |
| --- | ---: | ---: |
| `local.editFile` schema | 318 | 137 |
| `local.multiEdit` schema | 368 | 224 |
| `local.replace` schema | 253 | 137 |
| Combined schemas | 939 | 498 |
| Representative `editFile` arguments | 84 | 72 |
| Five `editFile` argument objects | 430 | 370 |
| One five-item `multiEdit` argument object | 338 | 278 |

The combined schema reduction is 46.96%. Contract tests enforce the canonical property sets, nested requirements, maximum schema sizes, output budgets, and the five-call comparison.

## Model-driven smoke metrics

For each release smoke scenario, record input tokens, output tokens, tool calls, rounds, retries, and follow-up `readFile` calls. Exercise:

1. one exact edit;
2. insertion through an anchor;
3. deletion;
4. ambiguous match followed by a focused read and retry;
5. CRLF input;
6. five ordered atomic edits;
7. failure of edit 3 with unchanged file;
8. routing a large change to `applyPatch`;
9. no follow-up read when post-edit context is sufficient.

Provider token and round measurements are intentionally not asserted in unit tests because they depend on the selected model and provider. Byte-level regressions are deterministic and run in the normal test suite.
