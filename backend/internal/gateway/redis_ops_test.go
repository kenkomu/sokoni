package gateway

import (
	"context"
	"math/big"
	"os"
	"testing"
	"time"

	"github.com/ethereum/go-ethereum/common"
	"github.com/redis/go-redis/v9"

	"github.com/kenkomu/sokoni/backend/internal/userop"
)

// Runs against a real Redis. CI provides one; locally it skips unless
// REDIS_URL is set (`make up`).
func redisOps(t *testing.T) *RedisOps {
	t.Helper()
	url := os.Getenv("REDIS_URL")
	if url == "" {
		t.Skip("REDIS_URL not set; CI runs this against a real Redis")
	}
	opt, err := redis.ParseURL(url)
	if err != nil {
		t.Fatalf("parse REDIS_URL: %v", err)
	}
	rdb := redis.NewClient(opt)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := rdb.Ping(ctx).Err(); err != nil {
		t.Fatalf("ping redis: %v", err)
	}
	t.Cleanup(func() { rdb.Close() })
	return NewRedisOps(rdb, time.Hour)
}

func testPending(id string) Pending {
	return Pending{
		ID:           id,
		CredentialID: "cred-1",
		Op: &userop.UserOperation{
			Sender:               common.HexToAddress("0xACC7"),
			Nonce:                big.NewInt(3),
			InitCode:             nil, // deployed already: no factory call
			CallData:             []byte{0xb6, 0x1d, 0x27, 0xf6},
			VerificationGasLimit: big.NewInt(600_000),
			CallGasLimit:         big.NewInt(400_000),
			PreVerificationGas:   big.NewInt(1_400_000),
			MaxPriorityFeePerGas: big.NewInt(3_000_000_000),
			MaxFeePerGas:         big.NewInt(200_000_000_000),
			PaymasterAndData:     bytes65(),
		},
		UserOpHash: common.HexToHash("0xabc123"),
		ExpiresAt:  time.Now().Add(5 * time.Minute).UTC(),
	}
}

func bytes65() []byte {
	b := make([]byte, 65)
	for i := range b {
		b[i] = byte(i)
	}
	return b
}

func TestRedisOpsRoundTrip(t *testing.T) {
	ops := redisOps(t)
	ctx := context.Background()
	want := testPending("redis-rt-" + t.Name())

	if err := ops.Put(ctx, want); err != nil {
		t.Fatalf("put: %v", err)
	}
	got, found, err := ops.Get(ctx, want.ID)
	if err != nil || !found {
		t.Fatalf("get: found=%v err=%v", found, err)
	}

	if got.CredentialID != want.CredentialID {
		t.Errorf("credentialID = %q, want %q", got.CredentialID, want.CredentialID)
	}
	if got.UserOpHash != want.UserOpHash {
		t.Errorf("userOpHash = %s, want %s", got.UserOpHash, want.UserOpHash)
	}
	if got.Op.Sender != want.Op.Sender {
		t.Errorf("sender = %s, want %s", got.Op.Sender, want.Op.Sender)
	}
	if got.Op.Nonce.Cmp(want.Op.Nonce) != 0 {
		t.Errorf("nonce = %s, want %s", got.Op.Nonce, want.Op.Nonce)
	}
	if got.Op.MaxFeePerGas.Cmp(want.Op.MaxFeePerGas) != 0 {
		t.Errorf("maxFeePerGas = %s, want %s", got.Op.MaxFeePerGas, want.Op.MaxFeePerGas)
	}
	if !bytesEqual(got.Op.CallData, want.Op.CallData) {
		t.Errorf("callData = %x, want %x", got.Op.CallData, want.Op.CallData)
	}
	if !bytesEqual(got.Op.PaymasterAndData, want.Op.PaymasterAndData) {
		t.Errorf("paymasterAndData = %x, want %x", got.Op.PaymasterAndData, want.Op.PaymasterAndData)
	}
	if len(got.Op.InitCode) != 0 {
		t.Errorf("initCode should round-trip empty, got %d bytes", len(got.Op.InitCode))
	}
	if got.Submitted() {
		t.Error("a freshly put pending must not read as submitted")
	}
}

func TestRedisOpsSurvivesANewClient(t *testing.T) {
	url := os.Getenv("REDIS_URL")
	if url == "" {
		t.Skip("REDIS_URL not set")
	}
	ops := redisOps(t)
	ctx := context.Background()
	want := testPending("redis-restart-" + t.Name())
	if err := ops.Put(ctx, want); err != nil {
		t.Fatal(err)
	}

	// A fresh client against the same Redis stands in for a gateway restart —
	// the failure mode this whole store exists to close.
	fresh := redisOps(t)
	got, found, err := fresh.Get(ctx, want.ID)
	if err != nil || !found {
		t.Fatalf("a restart must not lose a prepared operation: found=%v err=%v", found, err)
	}
	if got.Op.Sender != want.Op.Sender {
		t.Errorf("sender = %s, want %s", got.Op.Sender, want.Op.Sender)
	}
}

func TestRedisOpsMarkSubmittedIsIdempotent(t *testing.T) {
	ops := redisOps(t)
	ctx := context.Background()
	p := testPending("redis-submit-" + t.Name())
	if err := ops.Put(ctx, p); err != nil {
		t.Fatal(err)
	}

	hash := common.HexToHash("0xdeadbeef")
	at := time.Now().UTC()
	if err := ops.MarkSubmitted(ctx, p.ID, hash, at); err != nil {
		t.Fatalf("first mark: %v", err)
	}
	// A second mark, as if a retried submit raced the first, must not error
	// and must not change the recorded hash.
	if err := ops.MarkSubmitted(ctx, p.ID, common.HexToHash("0xother"), at.Add(time.Second)); err != nil {
		t.Fatalf("second mark: %v", err)
	}

	got, _, err := ops.Get(ctx, p.ID)
	if err != nil {
		t.Fatal(err)
	}
	if !got.Submitted() {
		t.Fatal("must read as submitted")
	}
	if got.BundlerHash != hash {
		t.Errorf("bundlerHash = %s, want the first mark's %s", got.BundlerHash, hash)
	}
}

func TestRedisOpsMarkSubmittedOnUnknownOpErrors(t *testing.T) {
	ops := redisOps(t)
	err := ops.MarkSubmitted(context.Background(), "redis-nope-"+t.Name(), common.HexToHash("0x1"), time.Now())
	if err == nil {
		t.Fatal("expected an error for an operation that was never put")
	}
}

func TestRedisOpsGetMissingReturnsNotFound(t *testing.T) {
	ops := redisOps(t)
	_, found, err := ops.Get(context.Background(), "redis-missing-"+t.Name())
	if err != nil || found {
		t.Fatalf("found=%v err=%v, want not found and no error", found, err)
	}
}

func bytesEqual(a, b []byte) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
