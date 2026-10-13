package gateway

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func limitedRequest(t *testing.T, h http.HandlerFunc, xff string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, "/v1/ops", nil)
	req.RemoteAddr = "127.0.0.1:5555"
	if xff != "" {
		req.Header.Set("X-Forwarded-For", xff)
	}
	rec := httptest.NewRecorder()
	h(rec, req)
	return rec
}

func TestRateLimitAllowsTheBurstThenRefusesWithRetryAfter(t *testing.T) {
	l := newIPLimiter(6, 3)
	frozen := time.Date(2026, 10, 13, 0, 0, 0, 0, time.UTC)
	l.now = func() time.Time { return frozen }
	h := l.wrap(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusOK) })

	for i := 0; i < 3; i++ {
		if rec := limitedRequest(t, h, "203.0.113.7"); rec.Code != http.StatusOK {
			t.Fatalf("request %d within burst: got %d", i+1, rec.Code)
		}
	}
	rec := limitedRequest(t, h, "203.0.113.7")
	if rec.Code != http.StatusTooManyRequests {
		t.Fatalf("request past burst: got %d, want 429", rec.Code)
	}
	if rec.Header().Get("Retry-After") != "10" { // 6/min refills one every 10s
		t.Errorf("Retry-After = %q, want 10", rec.Header().Get("Retry-After"))
	}

	if rec := limitedRequest(t, h, "198.51.100.9"); rec.Code != http.StatusOK {
		t.Errorf("a different IP shares no bucket: got %d", rec.Code)
	}

	frozen = frozen.Add(10 * time.Second)
	if rec := limitedRequest(t, h, "203.0.113.7"); rec.Code != http.StatusOK {
		t.Errorf("after one refill interval: got %d, want 200", rec.Code)
	}
}

// A client can put anything it likes in front of nginx's appended entry;
// only the last one is the peer nginx actually saw.
func TestRateLimitIgnoresSpoofedForwardedForEntries(t *testing.T) {
	l := newIPLimiter(6, 1)
	l.now = func() time.Time { return time.Date(2026, 10, 13, 0, 0, 0, 0, time.UTC) }
	h := l.wrap(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusOK) })

	if rec := limitedRequest(t, h, "1.1.1.1, 203.0.113.7"); rec.Code != http.StatusOK {
		t.Fatalf("first: got %d", rec.Code)
	}
	if rec := limitedRequest(t, h, "2.2.2.2, 203.0.113.7"); rec.Code != http.StatusTooManyRequests {
		t.Fatalf("rotating the spoofed prefix must not buy a fresh bucket: got %d", rec.Code)
	}
}
