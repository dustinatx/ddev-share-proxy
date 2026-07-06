# ddev-share-proxy

Proofs of concept for making `ddev share` fully browsable for CMSes that
bake a single base URL into stored config (WordPress, Magento 2, ...).

Two working variants, both verified end-to-end over live tunnels:

1. **Router-based** (`share-providers/cloudflared-router.sh`): routes the
   tunnel through `ddev-router` itself, using Traefik rewrite plugins — no
   extra binary, no extra container.
2. **Standalone Go proxy** (`share-providers/cloudflared-rewrite.sh` +
   the Go code in this repo): a small stdlib-only reverse proxy between the
   tunnel and the web container.

> **Disclaimer:** I'm not an experienced developer — this was vibe-coded
> with Claude. It's been tested thoroughly end-to-end (see Status below),
> but the code itself hasn't been reviewed by anyone with real Go or
> security experience. Please don't treat this as review-ready; it needs
> that kind of review before it should be taken seriously as a
> contribution.

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

## Variant 1: rewriting through ddev-router (Traefik)

```
cloudflared -> ddev-router (Traefik rewrite middlewares) -> web container
```

This is the "use the router, no other code" approach. It has two pieces:

**One-time static config** (`traefik/static_config.share-rewrite.yaml`,
copied to `~/.ddev/traefik/`): registers two plugins from the Traefik
catalog — [`packruler/rewrite-body`](https://github.com/packruler/rewrite-body)
for response bodies and
[`XciD/traefik-plugin-rewrite-headers`](https://github.com/XciD/traefik-plugin-rewrite-headers)
for the `Location` header. This uses DDEV's existing, documented
`static_config.*.yaml` merge mechanism. Plugins are static config in
Traefik, so this needs one router restart (`ddev poweroff` + `ddev start`).

**Per-share dynamic config** (pushed by the provider script): once the
tunnel URL is known, the script generates a Traefik dynamic-config file —
a router rule matching the tunnel hostname on the HTTPS entrypoint, a
service pointing at the project's web container, a `customRequestHeaders`
middleware restoring the project's local `Host` header upstream, and the
two rewrite middlewares — and `docker cp`s it into
`/mnt/ddev-global-cache/traefik/config/`. The router's file provider has
`watch: true`, so the route goes live in about a second with **no router
restart**, and is removed when the share ends.

cloudflared targets the router's HTTPS entrypoint (`--no-tls-verify`, since
the router serves the project's local cert), which keeps
`X-Forwarded-Proto: https` correct without any header games — otherwise
CMSes that force HTTPS redirect-loop.

Notes from getting it working:

- `rewrite-body` gates on the *request's* `Accept` header against its
  `monitoring.types` list (substring match, no wildcard support). Plain
  `curl` and JS `fetch()` send `Accept: */*` and got no rewriting at all.
  Fix: include the literal string `*/*` in `monitoring.types` — it
  satisfies the request-side gate for any browser/fetch/curl request, while
  the response-side gate still filters on real `Content-Type` values, so
  binary responses stay untouched.
- `rewrite-body` handles gzip itself (decompresses, rewrites,
  recompresses), verified byte-identical to an uncompressed fetch.
- Plugins are Yaegi-interpreted **source**, version-pinned and fetched from
  `plugins.traefik.io` at router startup — a much smaller trust gap than
  the dynamically-compiled Caddy binary the earlier prototype used, though
  still a runtime third-party fetch (see "If bundled into DDEV core" below
  for how that gap could be closed).

## Variant 2: standalone Go proxy

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
so it works for any CMS with this problem, not just WordPress (verified
against WordPress and TYPO3 so far — see Limitations).

This variant was built first, before the router-based one, on the theory
that a single stdlib-only binary per share session was simpler than
getting community plugins into the router. Both concerns it was avoiding
turned out manageable (see Variant 1), so it now mainly serves as the
zero-third-party-code alternative.

An earlier prototype used cloudflared → Caddy (with the third-party
`replace-response` module, dynamically fetched from Caddy's build API at
runtime) → web container. This Go version replaces Caddy to remove that
runtime dependency on an unverified, dynamically-compiled third-party
binary — everything here is stdlib only.

## Status: proof of concept

**Variant 1 (router-based)** verified end-to-end against the same
WordPress project over a live `trycloudflare.com` tunnel:

- Homepage, `/wp-json/` (still valid JSON afterward), and `/feed/` all came
  back with zero leaked local-host references.
- A `301` redirect's `Location` header was rewritten to the tunnel host.
- Browser-style gzip requests came back gzip-encoded with content
  byte-identical to an uncompressed fetch, zero leaks.
- A static CSS asset passed through byte-identical to a direct local fetch.
- `wp_options.siteurl` / `home` confirmed untouched; normal local routing
  (`https://project.ddev.site`) unaffected while the share route was live.

Variant 1 also verified end-to-end against the same TYPO3 (v14, base
distribution) project used for Variant 2's TYPO3 test, over a live
`trycloudflare.com` tunnel:

- Homepage `<link rel="canonical">` and the TYPO3 backend login page
  (`/typo3/`) both came back with zero leaked local-host references.
- A browser-style gzip request came back gzip-encoded, byte-identical to an
  uncompressed fetch once decompressed.
- A static CSS asset passed through byte-identical to a direct local fetch.
- The site's base URL (`config/sites/main/config.yaml`, set to
  `https://project.ddev.site/`) confirmed untouched before, during, and
  after; normal local routing unaffected while the share route was live.
- Reproduced the documented provider-cleanup limitation below: killing
  `ddev share` with `SIGTERM` stopped cloudflared but left the pushed route
  file in the router, requiring manual removal.

**Variant 2 (Go proxy)** verified end-to-end against a real WordPress
project over a live `trycloudflare.com` tunnel:

- Homepage, `/wp-json/` (JSON-escaped URLs), and `/feed/` (XML) all came
  back with zero leaked local-host references. `/wp-json/` and `/feed/`
  are exactly the class of page that stayed broken under the
  `wp search-replace` workaround (only the homepage ever worked there).
- A static CSS asset loaded byte-correct with an accurate `Content-Length`.
- `wp_options.siteurl` / `home` confirmed untouched before, during, and
  after — no database writes happen at any point.

Variant 2 also verified end-to-end against a fresh TYPO3 (v14, base
distribution) project over a live `trycloudflare.com` tunnel:

- Homepage `<link rel="canonical">` and the TYPO3 backend login page
  (`/typo3/`) both came back with zero leaked local-host references.
- The site's base URL (`typo3conf` site configuration, set to
  `https://project.ddev.site/`) confirmed untouched before, during, and
  after.
- No proxy code changes were needed to support TYPO3 — same binary, same
  provider script, different CMS, different templating engine (Fluid) and
  different config storage (YAML site config vs. WordPress's `wp_options`
  table).

Both variants also verified end-to-end against a fresh Drupal 11 project
over a live `trycloudflare.com` tunnel:

- Homepage, a node page (`<link rel="canonical">` and `<link
  rel="shortlink">`), and `/rss.xml` all came back with zero leaked
  local-host references.
- Browser-style gzip requests came back gzip-encoded, byte-identical to an
  uncompressed fetch once decompressed.
- A static aggregated CSS asset passed through byte-identical to a direct
  local fetch.
- `$base_url` / the current request's `getSchemeAndHttpHost()` confirmed
  untouched before, during, and after; normal local routing unaffected
  while the share route was live. Drupal doesn't persist a base URL in the
  database at all (unlike WordPress's `siteurl`/`home` or TYPO3's
  `config.yaml`), so there isn't even a `wp search-replace`-style workaround
  to compare against for Drupal today — either variant is a strict
  improvement over the status quo.
- Found and fixed a real gap: the JSON:API module (`/jsonapi/...`) responds
  with `application/vnd.api+json`, which was missing from both variants'
  rewritable-content-type allowlists (`monitoring.types` in the Traefik
  config for Variant 1, `isRewritableContentType` in `rewrite.go` for
  Variant 2). WordPress's `wp-json` uses plain `application/json`, so this
  never surfaced in the WP/TYPO3 testing above. Fixed in both places;
  re-verified zero leaks in JSON:API responses afterward.

### Limitations

- **Content saved *through* the tunnel persists tunnel URLs to the
  database.** Nothing reverse-rewrites the request body, because request
  bodies can be arbitrary multipart/binary data (file uploads) and blind
  string-replacement there risks corrupting them. Treat this as
  view/test-only, not an editing surface — same boundary the
  `wp search-replace` workaround has today.
- WebSocket payloads are not rewritten.
- Variant 1 only: responses to requests with no `Accept` header at all are
  not rewritten (the `rewrite-body` plugin's request-side gate needs one;
  browsers, `fetch()`, and curl always send it, so in practice this mostly
  affects headless API clients).
- Variant 1 only: if DDEV kills the provider script without SIGINT/SIGTERM
  reaching it, the pushed route file can linger in the router until the
  next share (the script removes stale files on startup, and a route for a
  dead tunnel hostname is unreachable anyway).
- Variant 1 and Variant 2 have both now been tested against WordPress,
  TYPO3, and Drupal 11. All over cloudflared only.
- Magento 2 — the other CMS DDEV's own docs call out for this exact
  problem — is still untested; it requires a Magento Marketplace account
  and Composer auth keys to install at all, which blocked testing it here.
- Tunnel-agnostic in principle (ngrok forwards the public Host header by
  default, same as cloudflared), but only cloudflared has actually been
  tested live.
- No automated integration test yet — the results above were driven
  manually against a real project and a real tunnel.
- Not yet wired up as a bundled DDEV share provider — both variants are
  currently project-level `.ddev/share-providers/` scripts.

## Usage

### Variant 1: router-based

One-time setup (plugins are Traefik static config):

```bash
cp traefik/static_config.share-rewrite.yaml ~/.ddev/traefik/
ddev poweroff && ddev start
```

Then copy `share-providers/cloudflared-router.sh` into your project's
`.ddev/share-providers/` and:

```bash
ddev share --provider=cloudflared-router
```

### Variant 2: standalone Go proxy

```bash
go build -o ~/.ddev/bin/ddev-share-proxy .
```

Copy `share-providers/cloudflared-rewrite.sh` into your project's
`.ddev/share-providers/`, then:

```bash
ddev share --provider=cloudflared-rewrite
```

## If bundled into DDEV core

Both variants currently carry costs that come from being standalone
scripts rather than from the approach itself. If maintainers wanted to
bundle this, the pieces would likely shift as follows (a sketch for
discussion, not a design):

**Variant 1:**

- The plugin registration would move into DDEV's default router static
  config, so the one-time setup step (copy a file, `ddev poweroff` +
  `ddev start`) disappears for users — the router restart happens
  naturally with the DDEV upgrade that ships it. Registering a plugin
  only loads its code; it does nothing until a route references it, so
  this shouldn't affect non-sharing users.
- The plugin source could be vendored into the router image and loaded
  as Traefik [local plugins](https://plugins.traefik.io/install),
  removing the runtime fetch from `plugins.traefik.io` entirely — no
  third-party code fetched at router startup, and the vendored source
  is reviewable and pinned in-tree.
- The provider script's dynamic-config push (`docker cp` into the
  router's watched directory) would become Go code inside `ddev`
  itself, which also fixes the stale-route-file limitation above: ddev
  would own the route's lifecycle instead of a bash `EXIT` trap hoping
  a signal reaches it.

**Variant 2:** the proxy code would work as-is; the main open question
is packaging (companion binary vs. hidden subcommand — see below),
which means building and shipping a binary per platform either way.

Net effect on the comparison: bundled, Variant 1 becomes zero-setup
with no new binary to ship. As standalone scripts the friction runs the
other way — Variant 2 works today with nothing but `go build`, while
Variant 1 needs the static-config step and a router restart.

## Design questions for discussion

- Which variant? Router-based keeps everything inside `ddev-router` with
  no new binary, at the cost of two third-party Yaegi plugins and (as a
  standalone script) a required router restart when first enabled; both
  costs shrink if bundled (see above). The Go proxy is stdlib-only and
  router-independent (works with `router: none` projects) but is a new
  binary to build, ship, and maintain.
- Should this be a distinctly-named provider or a flag on the existing
  built-in providers?
- If the Go-proxy variant: standalone companion binary (mirroring
  `cmd/ddev-hostname`) vs. a hidden subcommand embedded in the `ddev`
  binary itself?
- `ddev-get` addon first, or straight to a bundled provider in core, given
  both variants reuse the existing share-provider extension point and need
  no core changes?
