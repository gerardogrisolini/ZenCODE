# Web tools

The `web-tools` optional feature gives the agent two read-only tools for the
public web, on macOS and Linux:

- `web.search` searches DuckDuckGo and returns titles, URLs, and snippets.
- `web.fetch` downloads one HTTP or HTTPS URL and returns its content as
  Markdown, plain text, or HTML, after a short header describing the fetch.

They reach public destinations only (see [Security](#security)), keep no cookies
or cache between calls, and need no account or API key.

## Install and enable

```bash
zen --install-features web-tools
```

This copies the package into `~/.zencode/features/web-tools/`, builds it, and
enables it ([Optional Feature Packages](zen.md#optional-feature-packages)).
Select `web-tools` for a profile with `/tools`; its key in `agents.json` is
`feature:web-tools`. The recommended Developer and Builder profiles include it.

| | macOS | Linux |
| --- | --- | --- |
| HTML pages (`render: auto`) | Rendered in a silent offscreen WebKit view; JavaScript runs | One HTTP request; no JavaScript |
| `render: rendered` | WebKit | Raw fetch, with a `note:` line saying so |
| PDF | Text is extracted | Not extracted; header only |

Search, Markdown conversion, and the network policy are the same on both.

## web.search

| Input | Default | Meaning |
| --- | --- | --- |
| `query` | required | Search text. Quotes and operators such as `site:` go to the engine as written. |
| `limit` | 5 | Maximum number of results, clamped to 1-30. |
| `domains` | none | Domains to restrict results to, such as `["swift.org", "github.com"]`. |
| `timeRange` | all time | `day`, `week`, `month`, or `year`. |
| `region` | `wt-wt` | DuckDuckGo region code, two letters, a hyphen, two letters: `us-en`, `it-it`, `de-de`. `wt-wt` is worldwide. |

A blank `timeRange` or `region` counts as omitted; any other invalid value fails
with an error listing what is accepted. `domains` entries are reduced to their
lowercase host (`https://Swift.org/blog` becomes `swift.org`). ZenCODE adds
`site:a.com`, or `(site:a.com OR site:b.com)` for several, to the query, then
keeps only results on those hosts or their subdomains. An entry with spaces,
quotes, or parentheses gets no `site:` term but still filters.

### Output

```text
Query: swift testing site:swift.org
Results: 2 (engine: DuckDuckGo, range: week, region: it-it, pages: 1)

1. Title of the first result
   URL: https://www.swift.org/first
   Snippet: Text shown under the result, up to 400 characters.
```

`Query:` is the text sent to the engine, `site:` terms included. `Results:`
gives the count and, in parentheses, the engine that served the last page
(`DuckDuckGo` or `DuckDuckGo Lite`), your `range` and `region` when set, and the
number of result pages loaded. A `Note:` line follows when later pages could not
be loaded. Results keep the engine order; duplicate URLs and sponsored results
are dropped, and a result without a snippet has no `Snippet:` line. With no
results the output ends with `No public web results found.` and suggestions:
broaden the query, remove the domain filter, or widen or remove `timeRange`.

### Pages, fallback, and the bot check

The first page is one request. While fewer than `limit` results are collected
and DuckDuckGo offers a next page, the tool requests it, up to 3 pages in total,
so a search can return fewer results than `limit` and a large `limit` costs extra
requests. The first page is always attempted; a further page is started only
while the search has run for less than 45 seconds, otherwise the results so far
are returned with a `Note:` line. Requests send browser-like `User-Agent` and
`Accept` headers and time out after 20 seconds. HTTP 429, 5xx, and network errors are tried up to 3 times;
a numeric `Retry-After` is honoured for up to 10 seconds.

DuckDuckGo may answer an automated-looking client with a bot check (HTTP 202 or
a challenge page) instead of results:

- On the `html.duckduckgo.com` endpoint, the tool restarts the search from its
  first page on `lite.duckduckgo.com`, which then serves the remaining pages;
  results already collected are kept and duplicates are dropped.
- If Lite also asks for a bot check and nothing was collected, the call fails
  with `DuckDuckGo requested a bot check (rate limit)…`. Wait about a minute,
  then search again with fewer terms, a specific domain, or a smaller `limit`.
- After some pages, you get those results and a `Note:` line such as
  `DuckDuckGo requested a bot check, so only 2 result page(s) were loaded.`
  Another failure on a later page gives
  `Loading more results failed after N page(s): …`.

## web.fetch

| Input | Default | Meaning |
| --- | --- | --- |
| `url` | required | HTTP or HTTPS URL of a public page or file. |
| `maxBytes` | 120000 | Budget for the returned content, clamped to 1024-1000000 UTF-8 bytes. Header lines and the `## Links` section do not count. |
| `timeoutSeconds` | 20 | Time limit for loading (and rendering), clamped to 1-120. |
| `format` | `markdown` | `markdown`, `text` (no markup), or `html` (as received, or after JavaScript when rendered, where elements hidden by CSS carry a `hidden` attribute added by the renderer). JSON, text, and PDF text are text in every format. |
| `offset` | 0 | UTF-8 byte offset into the converted content, for reading long content in several calls. Must be below `length`. |
| `includeLinks` | `true` | Append a `## Links` section. `false` also renders anchors as plain text. |
| `mainContentOnly` | `true` | Convert only the main content. Ignored when `selector` is set. |
| `selector` | none | CSS selector; only the matching elements are converted. |
| `render` | `auto` | `auto`, `raw`, or `rendered`; see [Rendered and raw](#rendered-and-raw). |

`format` and `render` are case-insensitive. Other values, a negative `offset`,
and an unsupported `selector` fail with an error before any request is made.

### Output

The result is header lines, a blank line, then the content:

| Line | Meaning |
| --- | --- |
| `note:` | Zero or more notices: a fallback, a cut download, an ignored option, blocked frames. |
| `url:`, `status:` | Final URL after redirects; HTTP status when known. |
| `title:` | Page title (for a PDF, its metadata title). |
| `engine:` | `WebKit (rendered, JavaScript executed)` or `URLSession (raw fetch)`. |
| `content-type:` | The server's header; `text/html (rendered)` for a WebKit page; `… (sniffed as …)` when the type was missing or generic. |
| `scope:` | HTML only: `main (main)`, `main (role=main)`, `main (article)`, `full page`, or `selector …`. |
| `bytes:`, `pages:` | PDF and binary files: size; for a PDF, pages extracted, such as `3 of 12`. |
| `length:` | Total length of the converted content in UTF-8 bytes. |
| `range:` | `start-end` bytes returned; only when `offset` is above 0 or the content was cut. |
| `description:` | The page's `<meta name="description">` or `og:description`. |

Content that does not fit in `maxBytes` ends with
`<truncated: 98406 bytes omitted; call again with offset=120000 to continue>`.
Pass that `offset` to read the next part. Every call fetches and converts the
page again, so a page that changes between calls can shift the parts. An offset
inside a multi-byte character moves back to its start; one at or past `length`
fails with `offset N is past the end of the content`. For a PDF the hint says
`at least N bytes omitted` and `length` ends with
`(partial: extraction stopped early)`, because extraction stops once the
requested window is covered.

The `## Links` section appears on the first call only (`offset` 0) and not with
`includeLinks: false` or `format: html`. It lists up to 80 unique `http` and
`https` links from the converted content as `- [text](url)`, text cut to 160
characters. Same-page anchors and links with under 3 characters of text are left
out.

### Content types

The server's `Content-Type` decides. A missing or generic one
(`application/octet-stream`) is sniffed from the body: `%PDF-` is a PDF, a
leading `<` is HTML, valid UTF-8 is text, anything else is binary.

| Content | Result |
| --- | --- |
| HTML | Converted to Markdown or text; see [How HTML is converted](#how-html-is-converted). |
| JSON | As is; single-line JSON under 256 KiB is re-indented with two spaces, keeping key order. |
| Text (`text/*`, `+xml`, JavaScript, undeclared UTF-8) | As is. |
| PDF | macOS: text of the first 200 pages with `--- page N ---` separators, plus `bytes` and `pages`. Encrypted or unreadable PDFs give a short message, and scanned pages are not read (no OCR). Linux: a message that extraction is unavailable. |
| Images, audio, video, fonts, other binary | The header with `content-type` and `bytes`, then `This content type is not text; nothing was extracted.` |

`selector` does not apply outside HTML; a note says so. On both paths an HTTP
4xx or 5xx fails with `The web request failed with HTTP status N.`, followed by
up to 2048 bytes of the response text when the body is HTML, JSON, or text. An
HTML document longer than 8 MiB is converted up to that limit and a `note:` line
says that the remainder was ignored.

### Rendered and raw

`auto` renders HTML in WebKit where available (macOS) and fetches raw elsewhere.
`raw` makes one request without JavaScript; it is faster and works everywhere.
`rendered` always uses WebKit and falls back to raw, with a `note:` line, where
WebKit is unavailable.

Rendering uses a fresh non-persistent WebKit view, so no cookies, storage, or
cache survive the call. `timeoutSeconds` bounds the whole render: about 60% for
loading, then up to 6 seconds for the page to settle. JSON, PDF, and other
non-HTML documents are never rendered; on macOS with `auto` the URL is requested
through WebKit first and, when the response is not HTML, again through the raw
path (which keeps at least 5 seconds of budget, so the call can exceed
`timeoutSeconds` by up to 5 seconds), so use `render: raw` for URLs you know are
not HTML. If the WebKit content blocker (see [Security](#security)) cannot be
installed, the page is fetched raw and a `note:` line says why.

The raw path sends one request with browser-like headers, no cookies, and no
retries, and reads at most 8 MiB; a longer body is cut and a `note:` line says
so. Text is decoded from the `Content-Type` or `<meta>` charset, else UTF-8.

### How HTML is converted

A Swift converter on both platforms produces the Markdown or text:

- **Main content.** With `mainContentOnly`, the converter looks for `<main>`,
  then `[role=main]`, then `<article>`. In each group it takes the element with
  the most visible text and accepts it only if that is at least 200 characters
  and 20% of the page's. If no group qualifies it converts the whole `<body>`
  (`scope: full page`).
- **Removed.** `nav`, `footer`, `aside`, and the roles `navigation`, `menu`,
  `menubar`, `complementary`, `contentinfo`, `dialog`, and `alert`; a `header`
  only inside main content and only when it holds a `nav`; on a full page every
  `header` and `banner`. Scripts, styles, `iframe`, `svg`, form controls, and
  hidden elements are always dropped: those with `hidden`, `aria-hidden="true"`,
  or an inline `display:none` or `visibility:hidden`, and, in a WebKit render,
  any element hidden by CSS.
- **`mainContentOnly: false`** converts the whole body and keeps those landmarks.
  **`selector`** converts only the matches, in document order, and removes
  nothing inside them. Supported: tag, `*`, `#id`, `.class`, `[attr]`,
  `[attr=v]`, `^=`, `$=`, `*=`, `~=`, `|=`, descendant and `>` combinators, and
  comma-separated groups, such as `h1, h2` or `article .content`. Anything else
  fails with `Invalid or unsupported CSS selector`; no match fails with
  `CSS selector matched no elements`.
- **Tables.** A table with a caption, header cells, `thead`, `tfoot`, a `summary`,
  or a `grid` or `table` role, or a filled grid of at least two rows and two
  columns, becomes a Markdown table. Any other table is layout: its rows become
  paragraphs.
- **Images** with `alt` or `title` text are kept, as `![alt](url)` (`[image: alt]`
  in `text` format); others are dropped.
- **Links.** `http`, `https`, and `ftp` links become `[text](url)`, resolved
  against the page URL or its `<base>`. `mailto:`, `javascript:`, and same-page
  links stay plain text.

## Limits

| Limit | Value |
| --- | --- |
| `web.search` | 30 results, 3 pages, 2,000,000 bytes per page, 20 seconds per request |
| `web.fetch` download, raw path | 8 MiB; rendered HTML is cut at 8,388,608 characters |
| Redirects | 10 hops, then `Web tools stopped following redirects after 10 hops.` |
| `web.fetch` extras | 80 links, 200 PDF pages |

## Security

Both tools refuse private destinations, so a page (or a prompt hidden in one)
cannot point the agent at an internal address. The error for a refused host
starts `Web access to the restricted host '…' is disabled.`

- Only `http` and `https`, and no URL with embedded credentials.
- A host is rejected when it is `localhost`, ends in `.localhost` or `.local`, or
  is a loopback, private (`10/8`, `172.16/12`, `192.168/16`), link-local
  (`169.254/16`, which covers cloud metadata endpoints), shared-address
  (`100.64/10`), multicast, or reserved address, in IPv4 or IPv6 (including
  IPv4-mapped, 6to4, and NAT64 forms). Octal, hex, decimal, and short IPv4 forms
  such as `127.1` count as the address they denote; an unparsable one is
  rejected.
- Before every request the host name is resolved and each address must be
  public, so a name that resolves to a private address is refused (DNS
  rebinding). The check cannot pin the connection, so it narrows that attack
  rather than closing it.
- Every redirect hop is checked again. A refused hop fails with
  `Web tools blocked a redirect to '…'` and the reason.
- In WebKit, navigations in the main frame and every subframe pass the same
  check, and a content blocker refuses subresource loads (scripts, images, XHR)
  to non-public hosts. Refused frames are counted in a `note:`. The blocker
  matches literal addresses only; a public name that resolves to a private
  address is not caught for subresources.

`ZENCODE_WEBTOOLS_ALLOW_PRIVATE_NETWORK` set to `1`, `true`, `yes`, or `on`
disables the address checks. `zen` passes it to the feature when it starts, and
the model cannot set it through a tool argument:

```bash
ZENCODE_WEBTOOLS_ALLOW_PRIVATE_NETWORK=1 zen
```

Then `web.fetch`, its redirects, frames, and rendered subresources can reach
loopback, internal services, and metadata endpoints, and the WebKit content
blocker is not installed. The scheme and credential rules still apply, and a
name that is not itself a loopback name is still refused when it resolves to a
loopback address. A fetched page can steer the agent toward internal URLs, so
use the variable only on a network you trust and leave it unset otherwise.

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| `DuckDuckGo requested a bot check (rate limit)…` | Too many searches too fast. Wait about a minute, then use fewer terms, a specific domain, or a smaller `limit`. |
| Fewer results than `limit` | DuckDuckGo had fewer matches in 3 pages, or `domains` removed some. Remove the domain filter or widen `timeRange`. |
| `HTTP status 403` (or 401, 429) from `web.fetch` | The site blocks automated clients or needs a login; the tool sends no cookies. On macOS try `render: rendered`; otherwise use another source. |
| Empty content, or only "enable JavaScript" | The page builds its content with JavaScript. Use `render: rendered` (macOS); on Linux look for another URL for the same data, such as an API or a raw file. |
| Navigation or footers in the output, or too little | Try `mainContentOnly: false` for the whole body, or `selector` for one section. `format: html` shows the markup the tool sees. |
| `CSS selector matched no elements` | The selector does not match the HTML the tool received; a raw fetch has no JavaScript-built elements. Try `render: rendered` or `format: html`. |
| `offset N is past the end of the content` | `offset` must be below `length`. The page may have changed; start again at 0. |
| `Timed out loading the page after Ns` or `Timed out rendering the page after Ns` | Raise `timeoutSeconds` (up to 120), or use `render: raw`. |
