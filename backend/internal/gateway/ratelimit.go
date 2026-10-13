package gateway

import (
	"math"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"golang.org/x/time/rate"
)

// ipLimiter is a token bucket per client IP, applied only to endpoints that
// cost real money: every sponsored operation spends the paymaster's deposit
// on gas, and every assistant question spends API credit. Reads stay
// unlimited — they cost a Postgres query, not a deposit.
type ipLimiter struct {
	every rate.Limit
	burst int

	mu        sync.Mutex
	visitors  map[string]*visitor
	lastSweep time.Time
	now       func() time.Time
}

type visitor struct {
	lim  *rate.Limiter
	seen time.Time
}

// staleAfter is how long an idle IP keeps its bucket. Long enough that
// waiting it out is never faster than the refill itself.
const staleAfter = 10 * time.Minute

func newIPLimiter(perMinute float64, burst int) *ipLimiter {
	return &ipLimiter{
		every:    rate.Limit(perMinute / 60),
		burst:    burst,
		visitors: make(map[string]*visitor),
		now:      time.Now,
	}
}

// reserve reports whether key may proceed now and, if not, how long until
// it could.
func (l *ipLimiter) reserve(key string) (bool, time.Duration) {
	now := l.now()
	l.mu.Lock()
	defer l.mu.Unlock()

	if now.Sub(l.lastSweep) > time.Minute {
		for k, v := range l.visitors {
			if now.Sub(v.seen) > staleAfter {
				delete(l.visitors, k)
			}
		}
		l.lastSweep = now
	}

	v, ok := l.visitors[key]
	if !ok {
		v = &visitor{lim: rate.NewLimiter(l.every, l.burst)}
		l.visitors[key] = v
	}
	v.seen = now

	r := v.lim.ReserveN(now, 1)
	if delay := r.DelayFrom(now); delay > 0 {
		r.CancelAt(now)
		return false, delay
	}
	return true, 0
}

func (l *ipLimiter) wrap(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if ok, wait := l.reserve(clientIP(r)); !ok {
			w.Header().Set("Retry-After", strconv.Itoa(int(math.Ceil(wait.Seconds()))))
			writeJSON(w, http.StatusTooManyRequests, errorBody{
				Error:   "rate_limited",
				Message: "too many requests — wait a few seconds and try again",
			})
			return
		}
		next(w, r)
	}
}

// clientIP is the address the host nginx saw. The gateway binds only
// 127.0.0.1 (docker-compose.prod.yml), so RemoteAddr is always nginx itself;
// nginx's $proxy_add_x_forwarded_for appends the real peer as the LAST
// X-Forwarded-For entry. Earlier entries are whatever the client claimed and
// must not be trusted, or one client could rotate them to get a fresh bucket
// per request.
func clientIP(r *http.Request) string {
	if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
		parts := strings.Split(xff, ",")
		if ip := strings.TrimSpace(parts[len(parts)-1]); ip != "" {
			return ip
		}
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}
