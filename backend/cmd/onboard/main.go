// Command onboard drives one sponsored passkey operation end to end against a
// live chain, and prints what happened at every step.
//
// This is the harness that answers Phase 1's two open questions separately
// rather than together:
//
//  1. Does a real bundler accept a paymaster we deployed ourselves, and does
//     counterfactual deployment work on real Monad?
//  2. Does a real device's Secure Enclave produce an assertion the account
//     accepts?
//
// It answers the first while deliberately dodging the second: signing is done
// by script/gen_webauthn_vector.py, the same pure-Python P-256 signer the
// Foundry tests use. So the whole 4337 path can be proven on chain with no
// phone, no app build and no Digital Asset Links setup. Swap the signer for a
// device afterwards and the only new variable is the authenticator.
//
// It is a diagnostic, not a service. The gateway that does this for real users
// is Phase 2.
//
//	go run ./cmd/onboard --to 0x... --value 0
package main

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"math/big"
	"os"
	"os/exec"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/ethereum/go-ethereum/common"

	"github.com/kenkomu/sokoni/backend/internal/account"
	"github.com/kenkomu/sokoni/backend/internal/bundler"
	"github.com/kenkomu/sokoni/backend/internal/chain"
	"github.com/kenkomu/sokoni/backend/internal/paymaster"
	"github.com/kenkomu/sokoni/backend/internal/userop"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintf(os.Stderr, "\n  ✗ %v\n", err)
		os.Exit(1)
	}
}

type config struct {
	rpcURL     string
	bundlerURL string
	entryPoint common.Address
	factory    common.Address
	paymaster  common.Address
	signerKey  string
	chainID    *big.Int
	rpIDHash   [32]byte
	signer     string
}

func env(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

// require fails with the name of the missing variable rather than a nil
// dereference three steps later.
func require(key string) (string, error) {
	if v := os.Getenv(key); v != "" {
		return v, nil
	}
	return "", fmt.Errorf("%s is not set (see .env.example)", key)
}

func loadConfig() (*config, error) {
	c := &config{
		rpcURL:  env("MONAD_RPC_HTTP", chain.TestnetRPC),
		chainID: big.NewInt(int64(chain.TestnetChainID)),
		entryPoint: common.HexToAddress(
			env("ENTRYPOINT", chain.EntryPointV07)),
		signer: env("PASSKEY_SIGNER", "../contracts/script/gen_webauthn_vector.py"),
	}

	var err error
	if c.bundlerURL, err = require("BUNDLER_RPC_URL"); err != nil {
		return nil, err
	}
	pm, err := require("SOKONI_PAYMASTER")
	if err != nil {
		return nil, err
	}
	c.paymaster = common.HexToAddress(pm)
	fac, err := require("SOKONI_FACTORY")
	if err != nil {
		return nil, err
	}
	c.factory = common.HexToAddress(fac)
	if c.signerKey, err = require("PAYMASTER_SIGNER_KEY"); err != nil {
		return nil, err
	}

	if v := os.Getenv("SOKONI_CHAIN_ID"); v != "" {
		n, ok := new(big.Int).SetString(v, 10)
		if !ok {
			return nil, fmt.Errorf("SOKONI_CHAIN_ID %q is not a number", v)
		}
		c.chainID = n
	}

	// The relying party the passkey is bound to — the same SOKONI_RP_ID the
	// phone and the gateway use. The account stores its sha256, and an assertion
	// from any other domain will not bind. Hashed here rather than written out
	// as a 64-hex default, which the security workflow would take for a key.
	c.rpIDHash = sha256.Sum256([]byte(env("SOKONI_RP_ID", "sokoni.app")))

	return c, nil
}

func step(n int, format string, args ...any) {
	fmt.Printf("\n[%d] %s\n", n, fmt.Sprintf(format, args...))
}

func detail(format string, args ...any) {
	fmt.Printf("    %s\n", fmt.Sprintf(format, args...))
}

func run() error {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	target := flag.String("to", "0x000000000000000000000000000000000000dEaD", "call target")
	value := flag.String("value", "0", "wei to send with the call")
	salt := flag.Uint64("salt", 0, "account salt; change it to onboard a fresh account")
	timeout := flag.Duration("timeout", 90*time.Second, "how long to wait for the receipt")
	flag.Parse()

	cfg, err := loadConfig()
	if err != nil {
		return err
	}

	rpc := chain.NewClient(cfg.rpcURL, 10)
	bnd := bundler.New(cfg.bundlerURL, cfg.entryPoint, 10)

	sponsor, err := paymaster.NewSponsor(cfg.paymaster, cfg.chainID, cfg.signerKey)
	if err != nil {
		return fmt.Errorf("sponsor: %w", err)
	}

	// ---- 1. preflight -------------------------------------------------------
	step(1, "Preflight")
	detail("chain      %s (%s)", cfg.chainID, cfg.rpcURL)
	detail("entryPoint %s", cfg.entryPoint)
	detail("paymaster  %s", cfg.paymaster)
	detail("signing as %s", sponsor.SignerAddress())

	ok, err := bnd.SupportsConfiguredEntryPoint(ctx)
	if err != nil {
		return fmt.Errorf("bundler unreachable: %w", err)
	}
	if !ok {
		return fmt.Errorf("bundler does not support EntryPoint %s — wrong version or wrong network", cfg.entryPoint)
	}
	detail("bundler    supports this EntryPoint ✓")

	if err := sponsor.VerifyDeployment(ctx, rpc); err != nil {
		return err
	}
	detail("paymaster  registered signer matches ✓")

	// ---- 2. the passkey -----------------------------------------------------
	step(2, "Test passkey (pure-Python P-256, the same key the contract tests use)")
	owner, err := passkeyPublicKey(cfg.signer)
	if err != nil {
		return err
	}
	detail("x %s", account.Hex(owner.X.Bytes()))
	detail("y %s", account.Hex(owner.Y.Bytes()))

	// ---- 3. counterfactual address -----------------------------------------
	step(3, "Account address")
	owners := []account.Passkey{owner}
	sender, err := counterfactualAddress(ctx, rpc, cfg, owners, new(big.Int).SetUint64(*salt))
	if err != nil {
		return err
	}
	detail("sender %s", sender)

	code, err := rpc.Code(ctx, sender.Hex())
	if err != nil {
		return fmt.Errorf("check deployment: %w", err)
	}
	deployed := len(code) > 0
	if deployed {
		detail("already deployed — no initCode")
	} else {
		detail("not deployed yet — this operation will deploy it via initCode")
	}

	// ---- 4. build the operation --------------------------------------------
	step(4, "Build the user operation")
	wei, ok := new(big.Int).SetString(*value, 10)
	if !ok {
		return fmt.Errorf("--value %q is not a number", *value)
	}
	callData, err := account.EncodeExecute(common.HexToAddress(*target), wei, nil)
	if err != nil {
		return fmt.Errorf("encode execute: %w", err)
	}

	op := &userop.UserOperation{
		Sender:   sender,
		CallData: callData,
		// Hardcoded rather than estimated. Monad charges on the gas limit, so a
		// per-operation estimate buys nothing at runtime — and estimating with a
		// paymaster is circular anyway, since the estimate needs an approval
		// that already commits to the gas being estimated.
		VerificationGasLimit: envBig("VERIFICATION_GAS", 1_500_000),
		CallGasLimit:         envBig("CALL_GAS", 400_000),
		PreVerificationGas:   envBig("PRE_VERIFICATION_GAS", 200_000),
		MaxPriorityFeePerGas: envBig("MAX_PRIORITY_FEE", 1e9),
		MaxFeePerGas:         envBig("MAX_FEE", 100e9),
	}
	if !deployed {
		if op.InitCode, err = account.InitCode(cfg.factory, cfg.rpIDHash, owners, new(big.Int).SetUint64(*salt)); err != nil {
			return fmt.Errorf("init code: %w", err)
		}
	}

	if op.Nonce, err = fetchNonce(ctx, rpc, cfg.entryPoint, sender); err != nil {
		return err
	}
	detail("nonce    %s", op.Nonce)
	detail("callData %s", account.Hex(callData))

	// ---- 5. sponsorship -----------------------------------------------------
	// Must happen BEFORE the hash: the userOpHash covers paymasterAndData.
	step(5, "Sponsorship")
	validUntil := uint64(time.Now().Add(30 * time.Minute).Unix())
	maxCost := sponsor.MaxCost(op)
	pmd, err := sponsor.Approve(op, validUntil, 0, maxCost)
	if err != nil {
		return fmt.Errorf("approve: %w", err)
	}
	op.PaymasterAndData = pmd
	detail("maxCost    %s wei", maxCost)
	detail("validUntil %s", time.Unix(int64(validUntil), 0).Format(time.RFC3339))

	// ---- 6. sign ------------------------------------------------------------
	step(6, "Sign")
	hash, err := op.Hash(cfg.entryPoint, cfg.chainID)
	if err != nil {
		return fmt.Errorf("userOpHash: %w", err)
	}
	detail("userOpHash %s", hash)

	assertion, err := signWithPasskey(cfg.signer, hash.Hex())
	if err != nil {
		return err
	}
	if op.Signature, err = account.EncodeSignature(0, assertion); err != nil {
		return fmt.Errorf("encode signature: %w", err)
	}
	detail("assertion  %d bytes of authenticatorData, %d-byte signature payload",
		len(assertion.AuthenticatorData), len(op.Signature))

	// ---- 7. submit ----------------------------------------------------------
	step(7, "Submit")
	sent, err := bnd.SendUserOperation(ctx, op)
	if err != nil {
		return fmt.Errorf("send: %w", err)
	}
	detail("accepted as %s", sent)

	// ---- 8. receipt ---------------------------------------------------------
	step(8, "Wait for it to land")
	receipt, err := awaitReceipt(ctx, bnd, sent, *timeout)
	if err != nil {
		return err
	}

	fmt.Println()
	if !receipt.Success {
		return fmt.Errorf("operation landed but reverted: %s (tx %s)", receipt.Reason, receipt.TxHash)
	}
	fmt.Printf("  ✓ sponsored operation landed\n")
	detail("tx        %s", receipt.TxHash)
	detail("block     %d", receipt.BlockNumber)
	detail("gas cost  %s wei, paid by %s", receipt.ActualGasCost, receipt.Paymaster)
	if !deployed {
		detail("account   %s is now deployed", sender)
	}
	fmt.Println("\n  The account holds no MON and has no seed phrase.")
	return nil
}

func envBig(key string, def int64) *big.Int {
	if v := os.Getenv(key); v != "" {
		if n, ok := new(big.Int).SetString(v, 10); ok {
			return n
		}
	}
	return big.NewInt(def)
}

func fetchNonce(ctx context.Context, rpc *chain.Client, entryPoint, sender common.Address) (*big.Int, error) {
	data, err := account.EncodeGetNonce(sender, nil)
	if err != nil {
		return nil, err
	}
	out, err := rpc.Call(ctx, entryPoint.Hex(), account.Hex(data))
	if err != nil {
		return nil, fmt.Errorf("getNonce: %w", err)
	}
	if len(out) != 32 {
		return nil, fmt.Errorf("getNonce returned %d bytes; is %s really an EntryPoint?", len(out), entryPoint)
	}
	return new(big.Int).SetBytes(out), nil
}

func counterfactualAddress(
	ctx context.Context, rpc *chain.Client, cfg *config,
	owners []account.Passkey, salt *big.Int,
) (common.Address, error) {
	data, err := account.EncodeGetAddress(cfg.rpIDHash, owners, salt)
	if err != nil {
		return common.Address{}, err
	}
	out, err := rpc.Call(ctx, cfg.factory.Hex(), account.Hex(data))
	if err != nil {
		return common.Address{}, fmt.Errorf("factory getAddress: %w", err)
	}
	if len(out) != 32 {
		return common.Address{}, fmt.Errorf(
			"factory getAddress returned %d bytes; is %s really the factory?", len(out), cfg.factory)
	}
	return common.BytesToAddress(out[12:]), nil
}

// ---------------------------------------------------------------- passkey

type pubkeyOut struct {
	X string `json:"x"`
	Y string `json:"y"`
}

type assertionOut struct {
	AuthenticatorData string `json:"authenticatorData"`
	ClientDataJSON    string `json:"clientDataJSON"`
	ChallengeIndex    uint64 `json:"challengeIndex"`
	TypeIndex         uint64 `json:"typeIndex"`
	R                 string `json:"r"`
	S                 string `json:"s"`
}

func runSigner(script string, args ...string) ([]byte, error) {
	cmd := exec.Command("python3", append([]string{script}, args...)...)
	out, err := cmd.Output()
	if err != nil {
		var ee *exec.ExitError
		if errors.As(err, &ee) && len(ee.Stderr) > 0 {
			return nil, fmt.Errorf("passkey signer failed: %s", strings.TrimSpace(string(ee.Stderr)))
		}
		return nil, fmt.Errorf("passkey signer %q: %w", script, err)
	}
	return out, nil
}

func passkeyPublicKey(script string) (account.Passkey, error) {
	raw, err := runSigner(script, "--pubkey")
	if err != nil {
		return account.Passkey{}, err
	}
	var p pubkeyOut
	if err := json.Unmarshal(raw, &p); err != nil {
		return account.Passkey{}, fmt.Errorf("decode pubkey: %w", err)
	}
	return account.Passkey{
		X: new(big.Int).SetBytes(common.FromHex(p.X)),
		Y: new(big.Int).SetBytes(common.FromHex(p.Y)),
	}, nil
}

func signWithPasskey(script, challenge string) (account.Assertion, error) {
	raw, err := runSigner(script, "--sign", challenge)
	if err != nil {
		return account.Assertion{}, err
	}
	var a assertionOut
	if err := json.Unmarshal(raw, &a); err != nil {
		return account.Assertion{}, fmt.Errorf("decode assertion: %w", err)
	}
	return account.Assertion{
		AuthenticatorData: common.FromHex(a.AuthenticatorData),
		ClientDataJSON:    a.ClientDataJSON,
		ChallengeIndex:    a.ChallengeIndex,
		TypeIndex:         a.TypeIndex,
		R:                 new(big.Int).SetBytes(common.FromHex(a.R)),
		S:                 new(big.Int).SetBytes(common.FromHex(a.S)),
	}, nil
}

// awaitReceipt polls until the operation lands or the deadline passes.
//
// A nil receipt is the normal state for a few hundred milliseconds after
// submission — and it is also what a permanently dropped operation looks like
// forever. Only the timeout distinguishes them, which is exactly why user
// intent must never be left waiting on this without one.
func awaitReceipt(ctx context.Context, b *bundler.Client, hash common.Hash, timeout time.Duration) (*bundler.Receipt, error) {
	deadline := time.Now().Add(timeout)
	for {
		receipt, err := b.GetUserOperationReceipt(ctx, hash)
		if err != nil {
			return nil, fmt.Errorf("receipt: %w", err)
		}
		if receipt != nil {
			return receipt, nil
		}
		if time.Now().After(deadline) {
			return nil, fmt.Errorf(
				"no receipt for %s after %s — the bundler accepted it but it never landed", hash, timeout)
		}
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(time.Second):
		}
	}
}
