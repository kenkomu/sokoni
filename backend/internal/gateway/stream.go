// Live fan-out for candles/trades over WebSocket, at GET /v1/stream.
//
// The gateway has no chain read subscription of its own (ADR 5: one
// indexer) -- Hub.Run polls Postgres on an interval and broadcasts only when
// a poll notices a new row, so it stays a pure Postgres reader like every
// other part of the gateway.
//
// Wire protocol is fixed by the existing (until now unused) Flutter client,
// mobile/lib/data/ws/market_stream.dart: a client sends
// {"op":"sub","ch":[...]}; every server message carries an integer "seq"
// so the client can detect a gap (it does not auto-resubscribe on one --
// gap recovery is a REST re-fetch, done by the mobile controller). Channel
// names are this file's own contract with that client, not fixed anywhere
// else: "candles:<symbol>:<intervalSeconds>" and "trades:<symbol>", e.g.
// "candles:MON-AUSD:60".
package gateway

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"log/slog"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/coder/websocket"
)

// wsMessage is every message the server sends, whether a poll-detected
// update or the one-time snapshot pushed right after a subscribe.
type wsMessage struct {
	Seq  int64  `json:"seq"`
	Ch   string `json:"ch"`
	Type string `json:"type"` // "candle" | "trade"
	Data any    `json:"data"`
}

type subscriber struct {
	send chan []byte
}

func newSubscriber() *subscriber { return &subscriber{send: make(chan []byte, 32)} }

// Hub owns every live WS connection's channel subscriptions and the polling
// loop that feeds them. One process-wide instance; nil is a valid value
// (see NewHandler's doc) meaning no DATABASE_URL was configured.
type Hub struct {
	markets MarketData
	log     *slog.Logger

	mu   sync.RWMutex
	subs map[string]map[*subscriber]struct{} // channel -> subscribers
	seen map[string]string                   // channel -> last-broadcast row key

	seq atomic.Int64
}

func NewHub(markets MarketData, log *slog.Logger) *Hub {
	if log == nil {
		log = slog.Default()
	}
	return &Hub{
		markets: markets,
		log:     log,
		subs:    map[string]map[*subscriber]struct{}{},
		seen:    map[string]string{},
	}
}

// Run polls every currently-subscribed channel on each tick and broadcasts
// only what actually changed since the last tick. Blocks until ctx is done.
func (h *Hub) Run(ctx context.Context, pollInterval time.Duration) {
	t := time.NewTicker(pollInterval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			h.poll(ctx)
		}
	}
}

func (h *Hub) poll(ctx context.Context) {
	h.mu.RLock()
	channels := make([]string, 0, len(h.subs))
	for ch, subs := range h.subs {
		if len(subs) > 0 {
			channels = append(channels, ch)
		}
	}
	h.mu.RUnlock()

	// One query per subscribed symbol per tick -- trivial at today's market
	// count (two). If markets grow into the dozens this wants batching into
	// one query with `distinct on (market)` rather than N round trips.
	for _, ch := range channels {
		kind, symbol, interval, ok := parseChannel(ch)
		if !ok {
			continue
		}
		data, key, ok := h.fetch(ctx, kind, symbol, interval)
		if !ok {
			continue
		}

		h.mu.Lock()
		changed := h.seen[ch] != key
		if changed {
			h.seen[ch] = key
		}
		h.mu.Unlock()
		if changed {
			h.broadcast(ch, kind, data)
		}
	}
}

// Subscribe registers sub for every channel and immediately pushes each
// channel's current row, so a fresh connection is not blank until the next
// poll tick. The snapshot's key is recorded into h.seen exactly like a poll
// would -- caught live in a manual smoke test: leaving h.seen untouched here
// meant the very next poll tick saw "no seen entry yet" for a channel that
// in fact had not changed, and rebroadcast the same row a second time (with
// a new, valid-looking seq) to every subscriber, not just the new one.
func (h *Hub) Subscribe(ctx context.Context, sub *subscriber, channels []string) {
	h.mu.Lock()
	for _, ch := range channels {
		if h.subs[ch] == nil {
			h.subs[ch] = map[*subscriber]struct{}{}
		}
		h.subs[ch][sub] = struct{}{}
	}
	h.mu.Unlock()

	for _, ch := range channels {
		kind, symbol, interval, ok := parseChannel(ch)
		if !ok {
			continue
		}
		data, key, ok := h.fetch(ctx, kind, symbol, interval)
		if !ok {
			continue
		}
		h.mu.Lock()
		h.seen[ch] = key
		h.mu.Unlock()
		h.sendTo(sub, ch, kind, data)
	}
}

func (h *Hub) unsubscribeAll(sub *subscriber) {
	h.mu.Lock()
	defer h.mu.Unlock()
	for ch, subs := range h.subs {
		if _, ok := subs[sub]; ok {
			delete(subs, sub)
			if len(subs) == 0 {
				delete(h.subs, ch)
			}
		}
	}
}

func (h *Hub) broadcast(ch, kind string, data any) {
	msg, err := json.Marshal(wsMessage{Seq: h.seq.Add(1), Ch: ch, Type: singular(kind), Data: data})
	if err != nil {
		h.log.Error("marshal ws message", "err", err)
		return
	}

	h.mu.RLock()
	subs := make([]*subscriber, 0, len(h.subs[ch]))
	for s := range h.subs[ch] {
		subs = append(subs, s)
	}
	h.mu.RUnlock()

	for _, s := range subs {
		select {
		case s.send <- msg:
		default:
			// A slow consumer is dropped rather than allowed to block the
			// hub for everyone else; its connection's writer goroutine sees
			// the closed channel and tears the connection down.
			h.mu.Lock()
			delete(h.subs[ch], s)
			h.mu.Unlock()
			close(s.send)
		}
	}
}

func (h *Hub) sendTo(sub *subscriber, ch, kind string, data any) {
	msg, err := json.Marshal(wsMessage{Seq: h.seq.Add(1), Ch: ch, Type: singular(kind), Data: data})
	if err != nil {
		return
	}
	select {
	case sub.send <- msg:
	default:
	}
}

// fetch reads the single newest row for one channel and a comparable key for
// it (a candle's bucket timestamp, a trade's fill id) so poll() can tell
// whether it has already been broadcast.
func (h *Hub) fetch(ctx context.Context, kind, symbol string, interval int) (data any, key string, ok bool) {
	switch kind {
	case "candles":
		rows, err := h.markets.Candles(ctx, symbol, interval, 1)
		if err != nil || len(rows) == 0 {
			return nil, "", false
		}
		c := rows[len(rows)-1]
		return CandleView{
			BucketTS: c.BucketTS.UTC(), Open: c.Open, High: c.High, Low: c.Low,
			Close: c.Close, Volume: c.Volume, TradeCount: c.TradeCount,
		}, c.BucketTS.UTC().Format(time.RFC3339Nano), true
	case "trades":
		rows, err := h.markets.RecentTrades(ctx, symbol, 1)
		if err != nil || len(rows) == 0 {
			return nil, "", false
		}
		t := rows[0]
		return TradeView{
			FillID: t.FillID, Side: t.Side, Px: t.Px, Qty: t.Qty,
			BlockNumber: t.BlockNumber, TxHash: "0x" + hex.EncodeToString(t.TxHash),
		}, strconv.FormatInt(t.FillID, 10), true
	default:
		return nil, "", false
	}
}

// parseChannel reads this file's own wire grammar -- see the package doc.
func parseChannel(ch string) (kind, symbol string, interval int, ok bool) {
	parts := strings.Split(ch, ":")
	switch {
	case len(parts) == 3 && parts[0] == "candles":
		n, err := strconv.Atoi(parts[2])
		if err != nil || parts[1] == "" {
			return "", "", 0, false
		}
		return "candles", parts[1], n, true
	case len(parts) == 2 && parts[0] == "trades":
		if parts[1] == "" {
			return "", "", 0, false
		}
		return "trades", parts[1], 0, true
	default:
		return "", "", 0, false
	}
}

func singular(kind string) string {
	if kind == "candles" {
		return "candle"
	}
	return "trade"
}

// pingInterval keeps intermediaries (and a stdlib http.Server whose
// WriteTimeout/IdleTimeout we've zeroed for this connection, see below) from
// treating an idle-but-alive stream as dead, and reaps a genuinely dead peer
// itself: Ping erroring cancels the connection's context.
const pingInterval = 30 * time.Second

func (h *handler) stream(w http.ResponseWriter, r *http.Request) {
	if h.hub == nil {
		h.fail(w, fail(KindUpstream, "no_market_data", "market data is not available: this gateway has no database configured", nil))
		return
	}

	conn, err := websocket.Accept(w, r, nil)
	if err != nil {
		return // Accept already wrote a response on failure.
	}

	// cmd/gateway's http.Server sets WriteTimeout/IdleTimeout for ordinary
	// request/response handlers; applied unmodified they would kill this
	// connection well before a real trading session ends. Reset both once,
	// per-connection, and rely on the ping loop below to reap a connection
	// whose peer actually goes away instead.
	rc := http.NewResponseController(w)
	_ = rc.SetWriteDeadline(time.Time{})
	_ = rc.SetReadDeadline(time.Time{})

	ctx, cancel := context.WithCancel(r.Context())
	sub := newSubscriber()
	defer h.hub.unsubscribeAll(sub)
	defer conn.CloseNow()

	go func() {
		defer cancel()
		for {
			select {
			case <-ctx.Done():
				return
			case msg, ok := <-sub.send:
				if !ok {
					return
				}
				wctx, wcancel := context.WithTimeout(ctx, 10*time.Second)
				err := conn.Write(wctx, websocket.MessageText, msg)
				wcancel()
				if err != nil {
					return
				}
			}
		}
	}()

	go func() {
		defer cancel()
		t := time.NewTicker(pingInterval)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				pctx, pcancel := context.WithTimeout(ctx, 10*time.Second)
				err := conn.Ping(pctx)
				pcancel()
				if err != nil {
					return
				}
			}
		}
	}()

	// Only this loop calls conn.Read -- coder/websocket requires exactly one
	// reader at a time.
	for {
		_, data, err := conn.Read(ctx)
		if err != nil {
			cancel()
			return
		}
		var req struct {
			Op string   `json:"op"`
			Ch []string `json:"ch"`
		}
		// A malformed frame or an op we don't recognise (there is no "unsub"
		// on either side yet) is ignored, not fatal -- a future client sending
		// one it invented should not be able to kill the connection.
		if err := json.Unmarshal(data, &req); err != nil || req.Op != "sub" {
			continue
		}
		h.hub.Subscribe(ctx, sub, req.Ch)
	}
}
