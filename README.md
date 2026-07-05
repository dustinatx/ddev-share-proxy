# ddev-share-proxy

A small Go reverse proxy that makes `ddev share` fully browsable for CMSes
that bake a single base URL into stored config (WordPress, Magento 2, ...).
Proof of concept for a possible DDEV share provider.

## The problem

`ddev share` tunnels traffic straight to the project's web container,
bypassing `ddev-router`/Traefik entirely. That's fine for static sites, but
WordPress (and similar CMSes) generate absolute URLs from `siteurl`/`home`
in the database, which still point at `https://project.ddev.site`. The
result: the tunneled homepage loads, but REST API responses, RSS feeds, and
any link built from those options point back at the local hostname instead
of the tunnel.

DDEV's documented workaround is to temporarily rewrite the database
(`wp search-replace`) before sharing and restore it after — it works, but
it's a real database mutation with a backup/restore dance around every
share session, and it's WordPress-specific.

## This approach

Insert a small rewriting proxy between the tunnel and the web container:

```
tunnel (cloudflared/ngrok) -> ddev-share-proxy -> DDEV web container
```

`ddev-share-proxy` forwards requests upstream with the project's normal
local Host header (so the app behaves exactly as it does for local
traffic — same trusted-host checks, same `is_ssl()`, same caches), then on
the way back:

- Rewrites the local hostname to the tunnel hostname in the response body
  (covers `http://`, `https://`, protocol-relative `//`, and JSON-escaped
  `https:\/\/` references), for text/HTML/JSON/XML/JS responses only —
  binary responses (images, fonts, etc.) pass through untouched.
- Rewrites the `Location` header on redirects the same way.
- Forces `Accept-Encoding: identity` upstream so there's no compressed body
  to accidentally corrupt.

No database changes. No CMS-specific code — this operates purely on HTTP,
so it should work for any CMS with this problem, not just WordPress
(not yet verified against anything but WordPress — see Limitations).

This was explored as an alternative to Traefik middleware: `ddev share`
traffic doesn't currently touch Traefik at all, and getting body-rewriting
into Traefik would mean a community plugin (Yaegi-interpreted, global
router config affecting every project) plus a second plugin for `Location`
headers. Scoping the rewrite to a single Go binary per share session avoids
both of those, at the cost of not being a "the router did it" story.

An earlier prototype used cloudflared → Caddy (with the third-party
`replace-response` module, dynamically fetched from Caddy's build API at
runtime) → web container. This Go version replaces Caddy to remove that
runtime dependency on an unverified, dynamically-compiled third-party
binary — everything here is stdlib only.

## Status: proof of concept

Verified end-to-end against a real WordPress project over a live
`trycloudflare.com` tunnel:

- Homepage, `/wp-json/` (JSON-escaped URLs), and `/feed/` (XML) all came
  back with zero leaked local-host references. `/wp-json/` and `/feed/`
  are exactly the class of page that stayed broken under the
  `wp search-replace` workaround (only the homepage ever worked there).
- A static CSS asset loaded byte-correct with an accurate `Content-Length`.
- `wp_options.siteurl` / `home` confirmed untouched before, during, and
  after — no database writes happen at any point.

### Limitations

- **Content saved *through* the tunnel persists tunnel URLs to the
  database.** Nothing reverse-rewrites the request body, because request
  bodies can be arbitrary multipart/binary data (file uploads) and blind
  string-replacement there risks corrupting them. Treat this as
  view/test-only, not an editing surface — same boundary the
  `wp search-replace` workaround has today.
- WebSocket payloads are not rewritten.
- Only tested live against WordPress + cloudflared so far. The mechanism
  should be CMS-agnostic (pure HTTP layer) and tunnel-agnostic (ngrok
  forwards the public Host header by default, same as cloudflared), but
  neither claim has been verified yet.
- No automated integration test yet — the results above were driven
  manually against a real project and a real tunnel.
- Not yet wired up as a bundled DDEV share provider — currently a
  standalone binary + a project-level `.ddev/share-providers/` script.

## Usage

```bash
go build -o ~/.ddev/bin/ddev-share-proxy .
```

Copy `share-providers/cloudflared-rewrite.sh` into your project's
`.ddev/share-providers/`, then:

```bash
ddev share --provider=cloudflared-rewrite
```

## Design questions for discussion

- Should this be a distinctly-named provider (`cloudflared-rewrite`) or a
  flag on the existing built-in providers?
- Standalone companion binary (mirroring `cmd/ddev-hostname`) vs. a hidden
  subcommand embedded in the `ddev` binary itself?
- `ddev-get` addon first, or straight to a bundled provider in core, given
  this reuses the existing share-provider extension point and needs no
  other core changes?
