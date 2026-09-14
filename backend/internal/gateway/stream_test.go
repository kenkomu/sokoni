package gateway

import (
	"context"
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"

	"github.com/kenkomu/sokoni/backend/internal/store"
)

// dialStream connects a real WS client to the given httptest.Server's
// /v1/stream. Closing the returned func closes the connection.
func dialStream(t *testing.T, srv *httptest.Server) (*websocket.Conn, func()) {
	t.Helper()
	url := "ws" + strings.TrimPrefix(srv.URL, "http") + "/v1/stream"
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	conn, _, err := websocket.Dial(ctx, url, nil)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	return conn, func() { conn.CloseNow() }
}

func readMessage(t *testing.T, conn *websocket.Conn) wsMessage {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_, data, err := conn.Read(ctx)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	var msg wsMessage
	if err := json.Unmarshal(data, &msg); err != nil {
		t.Fatalf("unmarshal %s: %v", data, err)
	}
	return msg
}

func TestStreamSubscribeSendsSnapshot(t *testing.T) {
	r, srv := newServer(t)
	r.markets.markets = []store.Market{{Symbol: "MON-USDC"}}
	r.markets.trades["MON-USDC"] = []store.Trade{
		{FillID: 1, Side: "buy", Px: "1", Qty: "1", BlockNumber: 1, TxHash: make([]byte, 32)},
	}

	conn, closeConn := dialStream(t, srv)
	defer closeConn()

	if err := conn.Write(context.Background(), websocket.MessageText,
		[]byte(`{"op":"sub","ch":["trades:MON-USDC"]}`)); err != nil {
		t.Fatalf("subscribe: %v", err)
	}

	msg := readMessage(t, conn)
	if msg.Ch != "trades:MON-USDC" || msg.Type != "trade" {
		t.Errorf("snapshot message = %+v, want ch=trades:MON-USDC type=trade", msg)
	}
	if msg.Seq == 0 {
		t.Error("seq should be nonzero")
	}
}

func TestStreamBroadcastsIncreasingSeq(t *testing.T) {
	r, srv := newServer(t)
	r.markets.markets = []store.Market{{Symbol: "MON-USDC"}}
	r.markets.trades["MON-USDC"] = []store.Trade{
		{FillID: 1, Side: "buy", Px: "1", Qty: "1", BlockNumber: 1, TxHash: make([]byte, 32)},
	}

	conn, closeConn := dialStream(t, srv)
	defer closeConn()
	if err := conn.Write(context.Background(), websocket.MessageText,
		[]byte(`{"op":"sub","ch":["trades:MON-USDC"]}`)); err != nil {
		t.Fatalf("subscribe: %v", err)
	}
	snapshot := readMessage(t, conn)

	hubCtx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go r.hub.Run(hubCtx, 10*time.Millisecond)

	// A new fill appears -- the next poll tick should notice and broadcast.
	r.markets.mu.Lock()
	r.markets.trades["MON-USDC"] = append([]store.Trade{
		{FillID: 2, Side: "sell", Px: "2", Qty: "2", BlockNumber: 2, TxHash: make([]byte, 32)},
	}, r.markets.trades["MON-USDC"]...)
	r.markets.mu.Unlock()

	got := readMessage(t, conn)
	if got.Seq <= snapshot.Seq {
		t.Errorf("broadcast seq %d, want greater than snapshot seq %d", got.Seq, snapshot.Seq)
	}
	data, _ := got.Data.(map[string]any)
	if data["fillId"] != float64(2) {
		t.Errorf("broadcast data = %v, want the new fill (id 2)", data)
	}
}

func TestStreamIgnoresAnUnknownOp(t *testing.T) {
	_, srv := newServer(t)
	conn, closeConn := dialStream(t, srv)
	defer closeConn()

	if err := conn.Write(context.Background(), websocket.MessageText,
		[]byte(`{"op":"nonsense"}`)); err != nil {
		t.Fatalf("write: %v", err)
	}
	// Connection must still be alive and able to subscribe afterward.
	if err := conn.Write(context.Background(), websocket.MessageText,
		[]byte(`{"op":"sub","ch":[]}`)); err != nil {
		t.Fatalf("connection died after an unknown op: %v", err)
	}
}

func TestStreamRefusesUpgradeWithNoMarketData(t *testing.T) {
	r := newRig(t)
	r.hub = nil // simulates DATABASE_URL unset
	svc := r.svc
	srv := httptest.NewServer(NewHandler(svc, nil, quietLog()))
	defer srv.Close()

	url := "ws" + strings.TrimPrefix(srv.URL, "http") + "/v1/stream"
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_, resp, err := websocket.Dial(ctx, url, nil)
	if err == nil {
		t.Fatal("expected the upgrade to be refused")
	}
	if resp != nil && resp.StatusCode != 502 {
		t.Errorf("status = %d, want 502 (KindUpstream)", resp.StatusCode)
	}
}
