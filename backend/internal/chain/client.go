package chain

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"math/big"
	"net/http"
	"strconv"
	"sync/atomic"
	"time"
)

// RPCError is a JSON-RPC error object. Code -32007 is the provider's
// rate-limit rejection; see IsRateLimited.
type RPCError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

func (e *RPCError) Error() string { return fmt.Sprintf("rpc error %d: %s", e.Code, e.Message) }

type rpcRequest struct {
	JSONRPC string `json:"jsonrpc"`
	ID      uint64 `json:"id"`
	Method  string `json:"method"`
	Params  []any  `json:"params"`
}

type rpcResponse struct {
	ID     uint64          `json:"id"`
	Result json.RawMessage `json:"result"`
	Error  *RPCError       `json:"error"`
}

// Client is a JSON-RPC client for Monad.
//
// It speaks batch JSON-RPC deliberately. Measured on 2026-09-09, a single
// eth_getBlockByNumber round trip costs ~441ms while sixteen of them issued
// together cost ~448ms — latency dominates, so the win is in asking for many
// things at once. A batch is one HTTP request instead of sixteen, which is
// kinder to both the connection pool and the provider's limiter.
//
// Every call passes through the bucket. There is no unthrottled path.
type Client struct {
	url        string
	http       *http.Client
	bucket     *TokenBucket
	batchLimit int
	seq        atomic.Uint64
}

type ClientOption func(*Client)

// WithBatchLimit caps requests per batch. QuickNode's documented batch limit on
// the Monad endpoint is 100; keep well under it.
func WithBatchLimit(n int) ClientOption { return func(c *Client) { c.batchLimit = n } }

func NewClient(url string, ratePerSec float64, opts ...ClientOption) *Client {
	c := &Client{
		url:        url,
		http:       &http.Client{Timeout: 30 * time.Second},
		bucket:     NewTokenBucket(ratePerSec, ratePerSec*2),
		batchLimit: 16,
	}
	for _, o := range opts {
		o(c)
	}
	return c
}

func (c *Client) call(ctx context.Context, reqs []rpcRequest) ([]rpcResponse, error) {
	if err := c.bucket.Take(ctx, float64(len(reqs))); err != nil {
		return nil, err
	}

	var payload []byte
	var err error
	if len(reqs) == 1 {
		payload, err = json.Marshal(reqs[0])
	} else {
		payload, err = json.Marshal(reqs)
	}
	if err != nil {
		return nil, err
	}

	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, c.url, bytes.NewReader(payload))
	if err != nil {
		return nil, err
	}
	httpReq.Header.Set("Content-Type", "application/json")

	resp, err := c.http.Do(httpReq)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode == http.StatusTooManyRequests {
		return nil, &RPCError{Code: -32007, Message: "429 too many requests"}
	}

	dec := json.NewDecoder(resp.Body)
	if len(reqs) == 1 {
		var one rpcResponse
		if err := dec.Decode(&one); err != nil {
			return nil, fmt.Errorf("decode: %w", err)
		}
		if one.Error != nil {
			return nil, one.Error
		}
		return []rpcResponse{one}, nil
	}

	var many []rpcResponse
	if err := dec.Decode(&many); err != nil {
		return nil, fmt.Errorf("decode batch: %w", err)
	}
	for i := range many {
		if many[i].Error != nil {
			return nil, many[i].Error
		}
	}
	return many, nil
}

// BlockNumber returns the current head.
//
// Note this is an expensive call on the public endpoint (~1149ms measured), so
// callers should not put it in a tight loop — refresh the head only when the
// follower believes it has caught up.
func (c *Client) BlockNumber(ctx context.Context) (uint64, error) {
	return Retry(ctx, "eth_blockNumber", 6, func(ctx context.Context) (uint64, error) {
		out, err := c.call(ctx, []rpcRequest{{
			JSONRPC: "2.0", ID: c.seq.Add(1), Method: "eth_blockNumber", Params: []any{},
		}})
		if err != nil {
			return 0, err
		}
		var hex string
		if err := json.Unmarshal(out[0].Result, &hex); err != nil {
			return 0, err
		}
		return strconv.ParseUint(hex[2:], 16, 64)
	})
}

// BlockHeader is the subset of a block the indexer needs. We ask for headers
// without full transaction bodies: the follower only needs the hash chain to
// detect reorgs, and logs are fetched separately over a block range.
type BlockHeader struct {
	Number     uint64
	Hash       string
	ParentHash string
	Timestamp  uint64
}

type rawHeader struct {
	Number     string `json:"number"`
	Hash       string `json:"hash"`
	ParentHash string `json:"parentHash"`
	Timestamp  string `json:"timestamp"`
}

func parseHexU64(s string) uint64 {
	if len(s) > 2 && s[:2] == "0x" {
		s = s[2:]
	}
	v, _ := strconv.ParseUint(s, 16, 64)
	return v
}

// HeadersRange fetches [from, to] inclusive in batches. This is the call that
// makes the follower keep up with the chain.
func (c *Client) HeadersRange(ctx context.Context, from, to uint64) ([]BlockHeader, error) {
	if to < from {
		return nil, nil
	}
	total := int(to - from + 1)
	out := make([]BlockHeader, 0, total)

	for start := from; start <= to; start += uint64(c.batchLimit) {
		end := min(start+uint64(c.batchLimit)-1, to)

		reqs := make([]rpcRequest, 0, end-start+1)
		for n := start; n <= end; n++ {
			reqs = append(reqs, rpcRequest{
				JSONRPC: "2.0", ID: c.seq.Add(1), Method: "eth_getBlockByNumber",
				Params: []any{"0x" + strconv.FormatUint(n, 16), false},
			})
		}

		batch, err := Retry(ctx, "eth_getBlockByNumber", 6, func(ctx context.Context) ([]rpcResponse, error) {
			return c.call(ctx, reqs)
		})
		if err != nil {
			return nil, err
		}

		// A batch response may arrive out of order; key it by request id.
		byID := make(map[uint64]json.RawMessage, len(batch))
		for _, r := range batch {
			byID[r.ID] = r.Result
		}
		for _, req := range reqs {
			raw, ok := byID[req.ID]
			if !ok {
				return nil, fmt.Errorf("batch missing response for id %d", req.ID)
			}
			var h rawHeader
			if err := json.Unmarshal(raw, &h); err != nil {
				return nil, err
			}
			if h.Hash == "" {
				return nil, fmt.Errorf("null block in range near %s", h.Number)
			}
			out = append(out, BlockHeader{
				Number:     parseHexU64(h.Number),
				Hash:       h.Hash,
				ParentHash: h.ParentHash,
				Timestamp:  parseHexU64(h.Timestamp),
			})
		}
	}
	return out, nil
}

// Call performs an eth_call and returns raw return data.
func (c *Client) Call(ctx context.Context, to string, data string) ([]byte, error) {
	return Retry(ctx, "eth_call", 4, func(ctx context.Context) ([]byte, error) {
		out, err := c.call(ctx, []rpcRequest{{
			JSONRPC: "2.0", ID: c.seq.Add(1), Method: "eth_call",
			Params: []any{map[string]string{"to": to, "data": data}, "latest"},
		}})
		if err != nil {
			return nil, err
		}
		var hex string
		if err := json.Unmarshal(out[0].Result, &hex); err != nil {
			return nil, err
		}
		return decodeHex(hex)
	})
}

// Log is one entry from eth_getLogs.
type Log struct {
	Address     string
	Topics      []string
	Data        []byte
	BlockNumber uint64
	TxHash      string
	LogIndex    uint64
	Removed     bool
}

type rawLog struct {
	Address     string   `json:"address"`
	Topics      []string `json:"topics"`
	Data        string   `json:"data"`
	BlockNumber string   `json:"blockNumber"`
	TxHash      string   `json:"transactionHash"`
	LogIndex    string   `json:"logIndex"`
	Removed     bool     `json:"removed"`
}

// GetLogs fetches logs for [from, to] inclusive, at one address, optionally
// narrowed to specific event topics (nil for "any event at this address").
//
// The public endpoint enforces a 100-block span per call — confirmed live,
// not documented anywhere: a 101-block request returns JSON-RPC -32614,
// "eth_getLogs is limited to a 100 range". Callers must window their own
// requests to at most 100 blocks; this method does not chunk for them,
// because chunking silently would hide that ceiling from a caller who needs
// to know it.
func (c *Client) GetLogs(ctx context.Context, address string, topics []string, from, to uint64) ([]Log, error) {
	if to < from {
		return nil, fmt.Errorf("getLogs: to %d is before from %d", to, from)
	}
	if to-from > 99 {
		return nil, fmt.Errorf("getLogs: range %d..%d exceeds the 100-block ceiling the public endpoint enforces", from, to)
	}

	filter := map[string]any{
		"address":   address,
		"fromBlock": "0x" + strconv.FormatUint(from, 16),
		"toBlock":   "0x" + strconv.FormatUint(to, 16),
	}
	if len(topics) > 0 {
		filter["topics"] = topics
	}

	return Retry(ctx, "eth_getLogs", 6, func(ctx context.Context) ([]Log, error) {
		out, err := c.call(ctx, []rpcRequest{{
			JSONRPC: "2.0", ID: c.seq.Add(1), Method: "eth_getLogs", Params: []any{filter},
		}})
		if err != nil {
			return nil, err
		}
		var raw []rawLog
		if err := json.Unmarshal(out[0].Result, &raw); err != nil {
			return nil, err
		}
		logs := make([]Log, 0, len(raw))
		for _, r := range raw {
			data, err := decodeHex(r.Data)
			if err != nil {
				return nil, fmt.Errorf("log data: %w", err)
			}
			logs = append(logs, Log{
				Address:     r.Address,
				Topics:      r.Topics,
				Data:        data,
				BlockNumber: parseHexU64(r.BlockNumber),
				TxHash:      r.TxHash,
				LogIndex:    parseHexU64(r.LogIndex),
				Removed:     r.Removed,
			})
		}
		return logs, nil
	})
}

// Code returns the deployed bytecode at an address, empty if there is none.
//
// Code returns the deployed bytecode at an address, empty if there is none.
//
// The distinction matters for ERC-4337: an account that does not exist yet must
// carry initCode so the EntryPoint deploys it, and an account that already does
// must not — sending initCode for a deployed account is rejected as AA10.
func (c *Client) Code(ctx context.Context, address string) ([]byte, error) {
	return Retry(ctx, "eth_getCode", 4, func(ctx context.Context) ([]byte, error) {
		out, err := c.call(ctx, []rpcRequest{{
			JSONRPC: "2.0", ID: c.seq.Add(1), Method: "eth_getCode",
			Params: []any{address, "latest"},
		}})
		if err != nil {
			return nil, err
		}
		var hex string
		if err := json.Unmarshal(out[0].Result, &hex); err != nil {
			return nil, err
		}
		return decodeHex(hex)
	})
}

func decodeHex(s string) ([]byte, error) {
	if len(s) >= 2 && s[:2] == "0x" {
		s = s[2:]
	}
	if len(s)%2 != 0 {
		s = "0" + s
	}
	b := make([]byte, len(s)/2)
	for i := 0; i < len(b); i++ {
		v, err := strconv.ParseUint(s[i*2:i*2+2], 16, 8)
		if err != nil {
			return nil, err
		}
		b[i] = byte(v)
	}
	return b, nil
}

// BigFromWord reads a 32-byte EVM word as an unsigned integer.
func BigFromWord(b []byte) *big.Int { return new(big.Int).SetBytes(b) }
