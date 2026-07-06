package main

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestRewriteHostInBody(t *testing.T) {
	const local = "mobile.ddev.site"
	const tunnel = "xyz.trycloudflare.com"

	cases := []struct {
		name string
		in   string
		want string
	}{
		{
			name: "https link",
			in:   `<a href="https://mobile.ddev.site/about">About</a>`,
			want: `<a href="https://xyz.trycloudflare.com/about">About</a>`,
		},
		{
			name: "http link upgraded to https",
			in:   `<img src="http://mobile.ddev.site/wp-content/uploads/x.png">`,
			want: `<img src="https://xyz.trycloudflare.com/wp-content/uploads/x.png">`,
		},
		{
			name: "protocol-relative link",
			in:   `<script src="//mobile.ddev.site/wp-includes/js/x.js"></script>`,
			want: `<script src="//xyz.trycloudflare.com/wp-includes/js/x.js"></script>`,
		},
		{
			name: "json-escaped url",
			in:   `{"url":"https:\/\/mobile.ddev.site\/wp-json\/"}`,
			want: `{"url":"https:\/\/xyz.trycloudflare.com\/wp-json\/"}`,
		},
		{
			name: "bare host in srcset",
			in:   `srcset="http://mobile.ddev.site/a.jpg 1x, http://mobile.ddev.site/b.jpg 2x"`,
			want: `srcset="https://xyz.trycloudflare.com/a.jpg 1x, https://xyz.trycloudflare.com/b.jpg 2x"`,
		},
		{
			name: "no match leaves body untouched",
			in:   `<p>nothing to see here</p>`,
			want: `<p>nothing to see here</p>`,
		},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := rewriteHostInBody([]byte(c.in), local, tunnel)
			require.Equal(t, c.want, string(got))
		})
	}
}

func TestRewriteHostInBody_SameHostIsNoop(t *testing.T) {
	const host = "mobile.ddev.site"
	body := []byte(`<a href="https://mobile.ddev.site/">home</a>`)
	require.Equal(t, body, rewriteHostInBody(body, host, host))
}

func TestRewriteLocationHeader(t *testing.T) {
	got := rewriteLocationHeader("http://mobile.ddev.site/wp-admin/", "mobile.ddev.site", "xyz.trycloudflare.com")
	require.Equal(t, "https://xyz.trycloudflare.com/wp-admin/", got)
}

func TestIsRewritableContentType(t *testing.T) {
	rewritable := []string{
		"text/html; charset=UTF-8",
		"application/json",
		"application/javascript",
		"application/rss+xml; charset=UTF-8",
		"application/vnd.api+json",
		"text/css",
	}
	for _, ct := range rewritable {
		require.True(t, isRewritableContentType(ct), "expected %q to be rewritable", ct)
	}

	notRewritable := []string{
		"image/png",
		"image/jpeg",
		"application/pdf",
		"font/woff2",
		"",
		"application/octet-stream",
	}
	for _, ct := range notRewritable {
		require.False(t, isRewritableContentType(ct), "expected %q to not be rewritable", ct)
	}
}

func TestModifyResponse_RewritesBodyAndContentLength(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "http://mobile.ddev.site/", nil)
	req.Header.Set("X-Forwarded-Host", "xyz.trycloudflare.com")

	body := `<a href="https://mobile.ddev.site/about">About</a>`
	resp := &http.Response{
		Request:    req,
		Header:     http.Header{"Content-Type": []string{"text/html; charset=UTF-8"}},
		Body:       http.NoBody,
		StatusCode: 200,
	}
	resp.Body = io.NopCloser(strings.NewReader(body))

	err := modifyResponse("mobile.ddev.site")(resp)
	require.NoError(t, err)

	newBody, err := io.ReadAll(resp.Body)
	require.NoError(t, err)
	require.Equal(t, `<a href="https://xyz.trycloudflare.com/about">About</a>`, string(newBody))
	require.Equal(t, strconv.Itoa(len(newBody)), resp.Header.Get("Content-Length"))
}

func TestModifyResponse_SkipsBinaryContentType(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "http://mobile.ddev.site/logo.png", nil)
	req.Header.Set("X-Forwarded-Host", "xyz.trycloudflare.com")

	body := []byte{0x89, 0x50, 0x4E, 0x47} // PNG magic bytes
	resp := &http.Response{
		Request: req,
		Header:  http.Header{"Content-Type": []string{"image/png"}},
	}
	resp.Body = io.NopCloser(strings.NewReader(string(body)))

	err := modifyResponse("mobile.ddev.site")(resp)
	require.NoError(t, err)

	got, err := io.ReadAll(resp.Body)
	require.NoError(t, err)
	require.Equal(t, body, got)
}

func TestModifyResponse_SkipsAlreadyCompressedResponse(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "http://mobile.ddev.site/", nil)
	req.Header.Set("X-Forwarded-Host", "xyz.trycloudflare.com")

	body := "gzip-bytes-would-go-here-mobile.ddev.site"
	resp := &http.Response{
		Request: req,
		Header: http.Header{
			"Content-Type":     []string{"text/html"},
			"Content-Encoding": []string{"gzip"},
		},
	}
	resp.Body = io.NopCloser(strings.NewReader(body))

	err := modifyResponse("mobile.ddev.site")(resp)
	require.NoError(t, err)

	got, err := io.ReadAll(resp.Body)
	require.NoError(t, err)
	require.Equal(t, body, string(got))
}
