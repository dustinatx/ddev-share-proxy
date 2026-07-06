package main

import (
	"bytes"
	"mime"
	"net/http"
	"strconv"
)

// rewritableContentTypes are the response types safe to run a string
// replacement over. Everything else (images, fonts, video, ...) passes
// through untouched to avoid corrupting binary data.
func isRewritableContentType(contentType string) bool {
	mediaType, _, err := mime.ParseMediaType(contentType)
	if err != nil {
		// Content-Type header is empty or malformed; treat as opaque/binary
		// rather than risk rewriting something we can't identify.
		return false
	}

	switch {
	case mediaType == "application/json",
		mediaType == "application/javascript",
		mediaType == "application/xml",
		mediaType == "application/rss+xml",
		mediaType == "application/atom+xml",
		mediaType == "application/manifest+json",
		mediaType == "application/vnd.api+json":
		return true
	}

	if len(mediaType) >= 5 && mediaType[:5] == "text/" {
		return true
	}

	return false
}

// rewriteHostInBody swaps every occurrence of localHost for tunnelHost, then
// upgrades any resulting "http://tunnelHost" reference to "https://" since
// the tunnel is always TLS-terminated even though the origin speaks plain
// HTTP. Covers http://, https://, and protocol-relative //host references,
// plus JSON-escaped variants (https:\/\/host) in one pass.
func rewriteHostInBody(body []byte, localHost, tunnelHost string) []byte {
	if localHost == tunnelHost {
		return body
	}

	out := bytes.ReplaceAll(body, []byte(localHost), []byte(tunnelHost))
	out = bytes.ReplaceAll(out, []byte("http://"+tunnelHost), []byte("https://"+tunnelHost))
	out = bytes.ReplaceAll(out, []byte("http:\\/\\/"+tunnelHost), []byte("https:\\/\\/"+tunnelHost))

	return out
}

// rewriteLocationHeader applies the same host swap to a redirect's Location
// header, which is a plain string rather than a body.
func rewriteLocationHeader(location, localHost, tunnelHost string) string {
	if location == "" || localHost == tunnelHost {
		return location
	}

	out := bytes.ReplaceAll([]byte(location), []byte(localHost), []byte(tunnelHost))
	out = bytes.ReplaceAll(out, []byte("http://"+tunnelHost), []byte("https://"+tunnelHost))

	return string(out)
}

// modifyResponse rewrites the response body and Location header in place so
// a browser hitting the tunnel host never sees the local *.ddev.site host in
// links, assets, or redirects. Binary and already-compressed responses are
// left untouched.
func modifyResponse(localHost string) func(*http.Response) error {
	return func(resp *http.Response) error {
		tunnelHost := resp.Request.Header.Get("X-Forwarded-Host")
		if tunnelHost == "" || tunnelHost == localHost {
			return nil
		}

		if loc := resp.Header.Get("Location"); loc != "" {
			resp.Header.Set("Location", rewriteLocationHeader(loc, localHost, tunnelHost))
		}

		// Only an upstream that ignored our Accept-Encoding: identity request
		// would set this; bail rather than risk mangling compressed bytes.
		if ce := resp.Header.Get("Content-Encoding"); ce != "" && ce != "identity" {
			return nil
		}

		if !isRewritableContentType(resp.Header.Get("Content-Type")) {
			return nil
		}

		body, err := readAndCloseBody(resp)
		if err != nil {
			return err
		}

		newBody := rewriteHostInBody(body, localHost, tunnelHost)
		setResponseBody(resp, newBody)
		resp.Header.Set("Content-Length", strconv.Itoa(len(newBody)))

		return nil
	}
}
