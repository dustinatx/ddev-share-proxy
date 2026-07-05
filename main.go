// ddev-share-proxy sits between a share tunnel (cloudflared, ngrok, ...) and
// a DDEV project's web container. It rewrites the project's local *.ddev.site
// hostname to whatever hostname the tunnel is being accessed through, in
// response bodies and Location headers, so CMSes that bake a single base URL
// into stored config (WordPress, Magento, ...) are fully browsable through
// the tunnel without touching the database.
//
// Traffic flow: tunnel -> ddev-share-proxy (this) -> DDEV web container.
package main

import (
	"bytes"
	"flag"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
)

func main() {
	var (
		upstream = flag.String("upstream", "", "Upstream URL to proxy to, e.g. http://127.0.0.1:32843 (required)")
		host     = flag.String("host", "", "Local project hostname baked into the app, e.g. myproject.ddev.site (required)")
		listen   = flag.String("listen", "127.0.0.1:0", "Address to listen on")
		verbose  = flag.Bool("verbose", false, "Log each proxied request to stderr")
	)
	flag.Parse()

	if *upstream == "" || *host == "" {
		flag.Usage()
		os.Exit(2)
	}

	upstreamURL, err := url.Parse(*upstream)
	if err != nil {
		log.Fatalf("invalid --upstream %q: %v", *upstream, err)
	}

	proxy := &httputil.ReverseProxy{
		Director: func(req *http.Request) {
			// The tunnel host arrives as req.Host; stash it in a header so
			// ModifyResponse (which only sees the outbound request) can
			// still read it after Host is overwritten below.
			req.Header.Set("X-Forwarded-Host", req.Host)
			req.Header.Set("X-Forwarded-Proto", "https")
			// Ask the origin not to compress; rewriting compressed bytes
			// would corrupt them.
			req.Header.Set("Accept-Encoding", "identity")

			req.URL.Scheme = upstreamURL.Scheme
			req.URL.Host = upstreamURL.Host
			req.Host = *host

			if *verbose {
				log.Printf("%s %s -> %s%s (Host: %s)", req.Method, req.Header.Get("X-Forwarded-Host"), upstreamURL.Host, req.URL.Path, *host)
			}
		},
		ModifyResponse: modifyResponse(*host),
		ErrorLog:       log.New(os.Stderr, "ddev-share-proxy: ", log.LstdFlags),
	}

	listener, err := net.Listen("tcp", *listen)
	if err != nil {
		log.Fatalf("failed to listen on %s: %v", *listen, err)
	}

	log.Printf("ddev-share-proxy listening on %s, proxying to %s (host: %s)", listener.Addr(), *upstream, *host)

	server := &http.Server{Handler: proxy}
	if err := server.Serve(listener); err != nil && err != http.ErrServerClosed {
		log.Fatalf("server error: %v", err)
	}
}

func readAndCloseBody(resp *http.Response) ([]byte, error) {
	defer resp.Body.Close()
	return io.ReadAll(resp.Body)
}

func setResponseBody(resp *http.Response, body []byte) {
	resp.Body = io.NopCloser(bytes.NewReader(body))
}
