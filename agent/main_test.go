package main

import (
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestSnapshotAccessAndFreshness(t *testing.T) {
	c := config{Token: strings.Repeat("a", 64), Interval: 10}
	s := &snapshotCache{}
	h := handler(c, s)
	request := func(method, path, token string, want int) {
		t.Helper()
		r := httptest.NewRequest(method, path, nil)
		if token != "" {
			r.Header.Set("Authorization", "Bearer "+token)
		}
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		if w.Code != want {
			t.Fatalf("%s %s got %d, want %d", method, path, w.Code, want)
		}
		if w.Header().Get("Cache-Control") != "no-store" {
			t.Fatal("metrics responses must not be cached")
		}
	}
	request("GET", "/api/v1/snapshot", "", 401)
	request("GET", "/api/v1/snapshot", strings.Repeat("b", 64), 401)
	request("GET", "/api/v1/snapshot", c.Token, 503)
	s.set([]byte(`{"schemaVersion":1}`))
	request("GET", "/api/v1/snapshot", c.Token, 200)
	request("POST", "/api/v1/snapshot", c.Token, 405)
	request("GET", "/elsewhere", c.Token, 404)
	s.sampled = time.Now().Add(-61 * time.Second)
	request("GET", "/api/v1/snapshot", c.Token, 503)
	s.set([]byte(`{"schemaVersion":1}`))
	s.set(nil) // A failed sample must immediately invalidate earlier success.
	request("GET", "/api/v1/snapshot", c.Token, 503)
}

func TestRemoteHTTPRequiresExplicitOptIn(t *testing.T) {
	c := config{Bind: "127.0.0.1", Port: 9276, Token: strings.Repeat("a", 64), Interval: 10}
	if err := c.validate(); err != nil {
		t.Fatal(err)
	}
	c.Bind = "0.0.0.0"
	if c.validate() == nil {
		t.Fatal("remote plaintext was accepted without opt-in")
	}
	c.TLSCert = "server.crt"
	c.TLSKey = "server.key"
	if err := c.validate(); err != nil {
		t.Fatal(err)
	}
	c.Token = "short"
	if c.validate() == nil {
		t.Fatal("short token accepted")
	}
}
