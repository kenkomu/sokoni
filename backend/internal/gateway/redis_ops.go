package gateway

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"time"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/common/hexutil"
	"github.com/redis/go-redis/v9"

	"github.com/kenkomu/sokoni/backend/internal/userop"
)

// RedisOps persists prepared operations so a gateway restart — or, eventually,
// a second instance — does not silently lose the window between prepare and
// submit. Before this existed, a restart mid-flow made a phone's already-signed
// operation permanently unsubmittable: the phone held a valid assertion over a
// challenge the gateway no longer remembered building, and submit would answer
// "no such operation" for something the user had just approved with their
// fingerprint.
//
// Records are stored as JSON, not through userop.UserOperation's own
// MarshalJSON: that method is shaped for the bundler's wire format (initCode
// split into factory/factoryData, paymasterAndData split into four fields) and
// has no matching Unmarshal. Round-tripping storage through it would mean
// reconstructing internal fields — VerificationGasLimit, CallGasLimit and the
// rest — from a shape that was never designed to be read back. This package
// keeps its own storage format instead, so the two can change independently.
//
// Concurrency note: Put/Get/MarkSubmitted are plain Redis commands, not a
// transaction. That is fine for one gateway instance, which is all this
// exists to make durable today. A second instance racing another to mark the
// same operation submitted would want a Lua script or WATCH/MULTI — worth
// doing when there actually is a second instance, not before.
type RedisOps struct {
	rdb *redis.Client
	// How long a landed or expired operation stays gettable after it stops
	// being live, so a client polling status a little late still gets an
	// answer instead of "no such operation".
	retention time.Duration
}

func NewRedisOps(rdb *redis.Client, retention time.Duration) *RedisOps {
	return &RedisOps{rdb: rdb, retention: retention}
}

func opKey(id string) string { return "sokoni:op:" + id }

// record is Pending's storage shape — deliberately separate from both
// userop.UserOperation's bundler-facing JSON and from Go's default struct
// tags, so a change to either does not silently change what is on disk.
type record struct {
	ID           string    `json:"id"`
	CredentialID string    `json:"credentialId"`
	Op           opRecord  `json:"op"`
	UserOpHash   string    `json:"userOpHash"`
	ExpiresAt    time.Time `json:"expiresAt"`
	SubmittedAt  time.Time `json:"submittedAt,omitzero"`
	BundlerHash  string    `json:"bundlerHash,omitempty"`
}

type opRecord struct {
	Sender               string `json:"sender"`
	Nonce                string `json:"nonce"`
	InitCode             string `json:"initCode,omitempty"`
	CallData             string `json:"callData,omitempty"`
	VerificationGasLimit string `json:"verificationGasLimit"`
	CallGasLimit         string `json:"callGasLimit"`
	PreVerificationGas   string `json:"preVerificationGas"`
	MaxPriorityFeePerGas string `json:"maxPriorityFeePerGas"`
	MaxFeePerGas         string `json:"maxFeePerGas"`
	PaymasterAndData     string `json:"paymasterAndData,omitempty"`
	Signature            string `json:"signature,omitempty"`
}

func bigString(v *big.Int) string {
	if v == nil {
		return "0"
	}
	return v.String()
}

func parseBig(s string) (*big.Int, error) {
	if s == "" {
		return big.NewInt(0), nil
	}
	v, ok := new(big.Int).SetString(s, 10)
	if !ok {
		return nil, fmt.Errorf("not a decimal integer: %q", s)
	}
	return v, nil
}

func toRecord(p Pending) (record, error) {
	if p.Op == nil {
		return record{}, fmt.Errorf("pending %s has no operation", p.ID)
	}
	op := p.Op
	return record{
		ID:           p.ID,
		CredentialID: p.CredentialID,
		Op: opRecord{
			Sender:               op.Sender.Hex(),
			Nonce:                bigString(op.Nonce),
			InitCode:             hexutil.Encode(op.InitCode),
			CallData:             hexutil.Encode(op.CallData),
			VerificationGasLimit: bigString(op.VerificationGasLimit),
			CallGasLimit:         bigString(op.CallGasLimit),
			PreVerificationGas:   bigString(op.PreVerificationGas),
			MaxPriorityFeePerGas: bigString(op.MaxPriorityFeePerGas),
			MaxFeePerGas:         bigString(op.MaxFeePerGas),
			PaymasterAndData:     hexutil.Encode(op.PaymasterAndData),
			Signature:            hexutil.Encode(op.Signature),
		},
		UserOpHash:  p.UserOpHash.Hex(),
		ExpiresAt:   p.ExpiresAt,
		SubmittedAt: p.SubmittedAt,
		BundlerHash: p.BundlerHash.Hex(),
	}, nil
}

func fromRecord(r record) (Pending, error) {
	nonce, err := parseBig(r.Op.Nonce)
	if err != nil {
		return Pending{}, fmt.Errorf("nonce: %w", err)
	}
	verificationGas, err := parseBig(r.Op.VerificationGasLimit)
	if err != nil {
		return Pending{}, fmt.Errorf("verificationGasLimit: %w", err)
	}
	callGas, err := parseBig(r.Op.CallGasLimit)
	if err != nil {
		return Pending{}, fmt.Errorf("callGasLimit: %w", err)
	}
	preVerificationGas, err := parseBig(r.Op.PreVerificationGas)
	if err != nil {
		return Pending{}, fmt.Errorf("preVerificationGas: %w", err)
	}
	priorityFee, err := parseBig(r.Op.MaxPriorityFeePerGas)
	if err != nil {
		return Pending{}, fmt.Errorf("maxPriorityFeePerGas: %w", err)
	}
	maxFee, err := parseBig(r.Op.MaxFeePerGas)
	if err != nil {
		return Pending{}, fmt.Errorf("maxFeePerGas: %w", err)
	}

	return Pending{
		ID:           r.ID,
		CredentialID: r.CredentialID,
		Op: &userop.UserOperation{
			Sender:               common.HexToAddress(r.Op.Sender),
			Nonce:                nonce,
			InitCode:             hexutil.MustDecode(orZeroHex(r.Op.InitCode)),
			CallData:             hexutil.MustDecode(orZeroHex(r.Op.CallData)),
			VerificationGasLimit: verificationGas,
			CallGasLimit:         callGas,
			PreVerificationGas:   preVerificationGas,
			MaxPriorityFeePerGas: priorityFee,
			MaxFeePerGas:         maxFee,
			PaymasterAndData:     hexutil.MustDecode(orZeroHex(r.Op.PaymasterAndData)),
			Signature:            hexutil.MustDecode(orZeroHex(r.Op.Signature)),
		},
		UserOpHash:  common.HexToHash(r.UserOpHash),
		ExpiresAt:   r.ExpiresAt,
		SubmittedAt: r.SubmittedAt,
		BundlerHash: common.HexToHash(r.BundlerHash),
	}, nil
}

// orZeroHex makes an empty field decodable: hexutil.Decode rejects "" outright,
// but InitCode and PaymasterAndData are legitimately empty on most operations.
func orZeroHex(s string) string {
	if s == "" {
		return "0x"
	}
	return s
}

func (r *RedisOps) ttl(expiresAt time.Time) time.Duration {
	d := time.Until(expiresAt.Add(r.retention))
	if d <= 0 {
		// Already past retention (a clock skew or a very late write). Keep it
		// gettable for a few more seconds rather than writing a key Redis
		// would refuse or immediately evict — a status check landing in that
		// narrow window should still get an answer.
		return 5 * time.Second
	}
	return d
}

func (r *RedisOps) Put(ctx context.Context, p Pending) error {
	rec, err := toRecord(p)
	if err != nil {
		return err
	}
	data, err := json.Marshal(rec)
	if err != nil {
		return fmt.Errorf("marshal pending %s: %w", p.ID, err)
	}
	if err := r.rdb.Set(ctx, opKey(p.ID), data, r.ttl(p.ExpiresAt)).Err(); err != nil {
		return fmt.Errorf("redis set %s: %w", p.ID, err)
	}
	return nil
}

func (r *RedisOps) Get(ctx context.Context, id string) (Pending, bool, error) {
	data, err := r.rdb.Get(ctx, opKey(id)).Bytes()
	if errors.Is(err, redis.Nil) {
		return Pending{}, false, nil
	}
	if err != nil {
		return Pending{}, false, fmt.Errorf("redis get %s: %w", id, err)
	}
	var rec record
	if err := json.Unmarshal(data, &rec); err != nil {
		return Pending{}, false, fmt.Errorf("decode pending %s: %w", id, err)
	}
	p, err := fromRecord(rec)
	if err != nil {
		return Pending{}, false, fmt.Errorf("decode pending %s: %w", id, err)
	}
	return p, true, nil
}

func (r *RedisOps) MarkSubmitted(ctx context.Context, id string, hash common.Hash, at time.Time) error {
	p, found, err := r.Get(ctx, id)
	if err != nil {
		return err
	}
	if !found {
		return fmt.Errorf("operation %s vanished before it could be marked submitted", id)
	}
	if p.Submitted() {
		return nil
	}
	p.SubmittedAt, p.BundlerHash = at, hash
	// Keep it around for status reads well past the signing window, same as
	// MemoryOps does.
	if p.ExpiresAt.Before(at) {
		p.ExpiresAt = at
	}
	return r.Put(ctx, p)
}
