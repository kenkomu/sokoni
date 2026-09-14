// Package bundler talks to an ERC-4337 bundler.
//
// A bundler is a second, separate endpoint from the chain RPC: it keeps the
// alternative mempool of user operations, simulates them, and submits bundles
// to the EntryPoint. It speaks a small standard set of JSON-RPC methods, so
// every provider is interchangeable and the choice is configuration rather than
// code. Monad's own docs list Alchemy, Biconomy, Pimlico, Sequence, thirdweb
// and ZeroDev on both mainnet and testnet, plus FastLane, Gelato and Openfort
// on testnet.
//
// It has its own quota, so it gets its own token bucket rather than sharing the
// indexer's. The reason is the same one behind the chain client's: a rate limit
// must slow us down, never take a service out.
package bundler

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"math/big"
	"net/http"
	"sync/atomic"
	"time"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/common/hexutil"

	"github.com/kenkomu/sokoni/backend/internal/chain"
	"github.com/kenkomu/sokoni/backend/internal/userop"
)

// Client is a JSON-RPC client for a bundler endpoint.
type Client struct {
	url        string
	entryPoint common.Address
	http       *http.Client
	bucket     *chain.TokenBucket
	seq        atomic.Uint64
}

func New(url string, entryPoint common.Address, ratePerSec float64) *Client {
	return &Client{
		url:        url,
		entryPoint: entryPoint,
		http:       &http.Client{Timeout: 30 * time.Second},
		bucket:     chain.NewTokenBucket(ratePerSec, ratePerSec*2),
	}
}

// EntryPoint is the address this client submits against.
func (c *Client) EntryPoint() common.Address { return c.entryPoint }

type rpcRequest struct {
	JSONRPC string `json:"jsonrpc"`
	ID      uint64 `json:"id"`
	Method  string `json:"method"`
	Params  []any  `json:"params"`
}

type rpcResponse struct {
	ID     uint64          `json:"id"`
	Result json.RawMessage `json:"result"`
	Error  *chain.RPCError `json:"error"`
}

func (c *Client) call(ctx context.Context, method string, params []any) (json.RawMessage, error) {
	if err := c.bucket.Take(ctx, 1); err != nil {
		return nil, err
	}

	payload, err := json.Marshal(rpcRequest{
		JSONRPC: "2.0", ID: c.seq.Add(1), Method: method, Params: params,
	})
	if err != nil {
		return nil, err
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.url, bytes.NewReader(payload))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := c.http.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode == http.StatusTooManyRequests {
		return nil, &chain.RPCError{Code: -32007, Message: "429 too many requests"}
	}

	var out rpcResponse
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, fmt.Errorf("decode %s: %w", method, err)
	}
	if out.Error != nil {
		return nil, annotate(out.Error)
	}
	return out.Result, nil
}

// annotate turns a bundler's numeric rejection code into something a human can
// act on. These codes are the actual debugging surface of ERC-4337 — the raw
// message is often just "AA33 reverted", which names the stage and nothing else.
func annotate(err *chain.RPCError) error {
	var hint string
	switch err.Code {
	case -32500:
		// Narrower once: "bad signature, or nonce already used". Widened after
		// a live rejection on Monad testnet used this same code for
		// "preVerificationGas is not enough" — a gas-parameter problem, not a
		// signature one. -32500 is the bundler's general validation-failure
		// bucket; the message it comes with says which.
		hint = "validation rejected it — read the message: a bad signature, a used nonce, " +
			"and an insufficient gas parameter (preVerificationGas, most often) all surface here"
	case -32501:
		hint = "the paymaster rejected it — check the approval signature, its validity window, and the maxCost ceiling"
	case -32502:
		hint = "the account or paymaster used an opcode banned during validation (see ERC-7562)"
	case -32503:
		hint = "outside the validity window: the approval has expired or is not yet due"
	case -32504:
		hint = "the paymaster is throttled or banned by this bundler — usually too little stake, or too many recent failures"
	case -32505:
		hint = "the paymaster's stake or unstake delay is below what this bundler requires"
	case -32507:
		hint = "the signature did not verify"
	case -32521:
		hint = "the operation reverted during execution, not validation"
	default:
		return err
	}
	return fmt.Errorf("%w — %s", err, hint)
}

// SendUserOperation submits an operation and returns its hash.
//
// Retrying is safe. The userOpHash is deterministic, and the EntryPoint's nonce
// makes execution single-shot: a duplicate submission is either rejected as
// already known, or lands as the same operation. That is worth more than it
// sounds — a network timeout here is otherwise indistinguishable from a
// rejection, and giving up on a submitted operation strands user intent.
func (c *Client) SendUserOperation(ctx context.Context, op *userop.UserOperation) (common.Hash, error) {
	return chain.Retry(ctx, "eth_sendUserOperation", 4, func(ctx context.Context) (common.Hash, error) {
		raw, err := c.call(ctx, "eth_sendUserOperation", []any{op, c.entryPoint.Hex()})
		if err != nil {
			return common.Hash{}, err
		}
		var hash string
		if err := json.Unmarshal(raw, &hash); err != nil {
			return common.Hash{}, err
		}
		return common.HexToHash(hash), nil
	})
}

// GasEstimate is what a bundler thinks an operation will cost.
type GasEstimate struct {
	PreVerificationGas            *big.Int
	VerificationGasLimit          *big.Int
	CallGasLimit                  *big.Int
	PaymasterVerificationGasLimit *big.Int
	PaymasterPostOpGasLimit       *big.Int
}

type rawEstimate struct {
	PreVerificationGas            string `json:"preVerificationGas"`
	VerificationGasLimit          string `json:"verificationGasLimit"`
	CallGasLimit                  string `json:"callGasLimit"`
	PaymasterVerificationGasLimit string `json:"paymasterVerificationGasLimit"`
	PaymasterPostOpGasLimit       string `json:"paymasterPostOpGasLimit"`
}

// EstimateUserOperationGas asks the bundler to simulate and price an operation.
//
// Use it to sanity-check the hardcoded limits, not on the critical path. Monad
// charges gas on the limit rather than the amount used, so a per-operation
// estimate buys nothing at runtime and costs a round trip. It also needs a
// dummy signature of the right shape and cost, which for a passkey account
// means a full WebAuthn assertion — the estimate is only as honest as that
// dummy is representative.
func (c *Client) EstimateUserOperationGas(ctx context.Context, op *userop.UserOperation) (*GasEstimate, error) {
	return chain.Retry(ctx, "eth_estimateUserOperationGas", 4, func(ctx context.Context) (*GasEstimate, error) {
		raw, err := c.call(ctx, "eth_estimateUserOperationGas", []any{op, c.entryPoint.Hex()})
		if err != nil {
			return nil, err
		}
		var r rawEstimate
		if err := json.Unmarshal(raw, &r); err != nil {
			return nil, err
		}
		est := &GasEstimate{}
		for _, f := range []struct {
			src string
			dst **big.Int
		}{
			{r.PreVerificationGas, &est.PreVerificationGas},
			{r.VerificationGasLimit, &est.VerificationGasLimit},
			{r.CallGasLimit, &est.CallGasLimit},
			{r.PaymasterVerificationGasLimit, &est.PaymasterVerificationGasLimit},
			{r.PaymasterPostOpGasLimit, &est.PaymasterPostOpGasLimit},
		} {
			if f.src == "" {
				continue
			}
			v, err := hexutil.DecodeBig(f.src)
			if err != nil {
				return nil, fmt.Errorf("estimate field %q: %w", f.src, err)
			}
			*f.dst = v
		}
		return est, nil
	})
}

// Receipt is the outcome of an operation once it has landed.
type Receipt struct {
	UserOpHash    common.Hash
	Sender        common.Address
	Paymaster     common.Address
	Nonce         *big.Int
	ActualGasCost *big.Int
	ActualGasUsed *big.Int
	Success       bool
	Reason        string
	TxHash        common.Hash
	BlockNumber   uint64
}

type rawReceipt struct {
	UserOpHash    string `json:"userOpHash"`
	Sender        string `json:"sender"`
	Paymaster     string `json:"paymaster"`
	Nonce         string `json:"nonce"`
	ActualGasCost string `json:"actualGasCost"`
	ActualGasUsed string `json:"actualGasUsed"`
	Success       bool   `json:"success"`
	Reason        string `json:"reason"`
	Receipt       struct {
		TransactionHash string `json:"transactionHash"`
		BlockNumber     string `json:"blockNumber"`
	} `json:"receipt"`
}

// GetUserOperationReceipt returns the receipt, or nil if the operation has not
// landed yet.
//
// A nil receipt is the normal state for a few hundred milliseconds after
// submission, and it is also what a permanently dropped operation looks like
// forever — the caller needs a timeout to tell those apart, and must mark the
// order failed rather than leaving intent in limbo.
func (c *Client) GetUserOperationReceipt(ctx context.Context, hash common.Hash) (*Receipt, error) {
	return chain.Retry(ctx, "eth_getUserOperationReceipt", 4, func(ctx context.Context) (*Receipt, error) {
		raw, err := c.call(ctx, "eth_getUserOperationReceipt", []any{hash.Hex()})
		if err != nil {
			return nil, err
		}
		if len(raw) == 0 || string(raw) == "null" {
			return nil, nil
		}
		var r rawReceipt
		if err := json.Unmarshal(raw, &r); err != nil {
			return nil, err
		}
		out := &Receipt{
			UserOpHash:  common.HexToHash(r.UserOpHash),
			Sender:      common.HexToAddress(r.Sender),
			Success:     r.Success,
			Reason:      r.Reason,
			TxHash:      common.HexToHash(r.Receipt.TransactionHash),
			BlockNumber: hexToUint64(r.Receipt.BlockNumber),
		}
		if r.Paymaster != "" {
			out.Paymaster = common.HexToAddress(r.Paymaster)
		}
		out.Nonce = hexToBig(r.Nonce)
		out.ActualGasCost = hexToBig(r.ActualGasCost)
		out.ActualGasUsed = hexToBig(r.ActualGasUsed)
		return out, nil
	})
}

// SupportedEntryPoints is the cheapest possible liveness check, and worth
// calling at boot: a bundler pointed at the wrong EntryPoint version fails
// every operation with an error that does not say so.
func (c *Client) SupportedEntryPoints(ctx context.Context) ([]common.Address, error) {
	return chain.Retry(ctx, "eth_supportedEntryPoints", 4, func(ctx context.Context) ([]common.Address, error) {
		raw, err := c.call(ctx, "eth_supportedEntryPoints", []any{})
		if err != nil {
			return nil, err
		}
		var list []string
		if err := json.Unmarshal(raw, &list); err != nil {
			return nil, err
		}
		out := make([]common.Address, 0, len(list))
		for _, s := range list {
			out = append(out, common.HexToAddress(s))
		}
		return out, nil
	})
}

// SupportsConfiguredEntryPoint reports whether the bundler will accept the
// EntryPoint this client is configured for.
func (c *Client) SupportsConfiguredEntryPoint(ctx context.Context) (bool, error) {
	eps, err := c.SupportedEntryPoints(ctx)
	if err != nil {
		return false, err
	}
	for _, ep := range eps {
		if ep == c.entryPoint {
			return true, nil
		}
	}
	return false, nil
}

func hexToBig(s string) *big.Int {
	if s == "" {
		return nil
	}
	v, err := hexutil.DecodeBig(s)
	if err != nil {
		return nil
	}
	return v
}

func hexToUint64(s string) uint64 {
	v := hexToBig(s)
	if v == nil {
		return 0
	}
	return v.Uint64()
}
