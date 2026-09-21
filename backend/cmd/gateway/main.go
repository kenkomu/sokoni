// Command gateway serves the phone's API: register a passkey, prepare an
// operation, submit the signed assertion, and poll for the outcome.
//
// It refuses to start if the bundler cannot serve our EntryPoint, or if the
// deployed paymaster holds a different signer than the key we sign with. Both
// failures are total and silent at runtime — every operation rejected with an
// opaque AA code — so they are far cheaper to find at boot than on a phone.
package main

import (
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"log/slog"
	"math/big"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/ethereum/go-ethereum/common"

	"github.com/kenkomu/sokoni/backend/internal/bundler"
	"github.com/kenkomu/sokoni/backend/internal/chain"
	"github.com/kenkomu/sokoni/backend/internal/gateway"
	"github.com/kenkomu/sokoni/backend/internal/id"
	"github.com/kenkomu/sokoni/backend/internal/paymaster"
	"github.com/kenkomu/sokoni/backend/internal/store"
	"github.com/redis/go-redis/v9"
)

func main() {
	log := slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
	if err := run(log); err != nil {
		log.Error("gateway stopped", "err", err)
		os.Exit(1)
	}
}

func env(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

// splitNonEmpty is comma-split with blank entries dropped, so
// "a,,b" and a trailing comma don't produce an empty fingerprint
// that would silently never match anything.
func splitNonEmpty(v string) []string {
	if v == "" {
		return nil
	}
	var out []string
	for _, s := range strings.Split(v, ",") {
		if s = strings.TrimSpace(s); s != "" {
			out = append(out, s)
		}
	}
	return out
}

func require(key string) (string, error) {
	if v := os.Getenv(key); v != "" {
		return v, nil
	}
	return "", fmt.Errorf("%s is not set (see .env.example)", key)
}

func envBig(key string, def *big.Int) (*big.Int, error) {
	v := os.Getenv(key)
	if v == "" {
		return def, nil
	}
	n, ok := new(big.Int).SetString(v, 10)
	if !ok || n.Sign() < 0 {
		return nil, fmt.Errorf("%s=%q is not a non-negative integer", key, v)
	}
	return n, nil
}

type wiring struct {
	addr       string
	rpcURL     string
	bundlerURL string
	paymaster  common.Address
	signerKey  string
	dsn        string
	redisURL   string
	nodeID     int64
}

func loadConfig() (gateway.Config, wiring, error) {
	var cfg gateway.Config
	w := wiring{
		addr:     env("GATEWAY_ADDR", ":8080"),
		rpcURL:   env("MONAD_RPC_HTTP", chain.TestnetRPC),
		dsn:      os.Getenv("DATABASE_URL"),
		redisURL: os.Getenv("REDIS_URL"),
	}

	var err error
	if w.bundlerURL, err = require("BUNDLER_RPC_URL"); err != nil {
		return cfg, w, err
	}
	if w.signerKey, err = require("PAYMASTER_SIGNER_KEY"); err != nil {
		return cfg, w, err
	}
	pm, err := require("SOKONI_PAYMASTER")
	if err != nil {
		return cfg, w, err
	}
	w.paymaster = common.HexToAddress(pm)
	fac, err := require("SOKONI_FACTORY")
	if err != nil {
		return cfg, w, err
	}
	// Optional: unset leaves MeraFactory at the zero address, and the
	// service layer answers /v1/mera/* with KindUpstream rather than the
	// gateway refusing to start — same graceful-degradation shape as
	// Markets/DATABASE_URL.
	meraFac := os.Getenv("SOKONI_MERA_FACTORY")

	node, err := strconv.ParseInt(env("GATEWAY_NODE_ID", "1"), 10, 64)
	if err != nil {
		return cfg, w, fmt.Errorf("GATEWAY_NODE_ID: %w", err)
	}
	w.nodeID = node

	tokens, err := gateway.ParseTokens(os.Getenv("SPONSORED_TOKENS"))
	if err != nil {
		return cfg, w, fmt.Errorf("SPONSORED_TOKENS: %w", err)
	}
	// A gateway that sponsors nothing can do nothing, and would say so only
	// when a user tries. Say it now.
	if len(tokens) == 0 {
		return cfg, w, fmt.Errorf("SPONSORED_TOKENS is empty; the gateway would have nothing it could send")
	}

	chainID, ok := new(big.Int).SetString(env("SOKONI_CHAIN_ID", strconv.Itoa(chain.TestnetChainID)), 10)
	if !ok {
		return cfg, w, fmt.Errorf("SOKONI_CHAIN_ID is not a number")
	}

	gas := gateway.DefaultGas()
	for _, g := range []struct {
		key string
		dst **big.Int
	}{
		{"VERIFICATION_GAS", &gas.Verification},
		{"VERIFICATION_GAS_DEPLOY", &gas.VerificationWithDeploy},
		{"CALL_GAS", &gas.Call},
		{"PRE_VERIFICATION_GAS", &gas.PreVerification},
		{"MAX_PRIORITY_FEE", &gas.MaxPriorityFee},
		{"MAX_FEE", &gas.MaxFee},
	} {
		if *g.dst, err = envBig(g.key, *g.dst); err != nil {
			return cfg, w, err
		}
	}

	cfg = gateway.Config{
		EntryPoint: common.HexToAddress(env("ENTRYPOINT", chain.EntryPointV07)),
		Factory:    common.HexToAddress(fac),
		MeraFactory: func() common.Address {
			if meraFac == "" {
				return common.Address{}
			}
			return common.HexToAddress(meraFac)
		}(),
		ChainID: chainID,
		// The same relying party the phone binds its passkeys to (SOKONI_RP_ID
		// on the client). A mismatch fails every assertion with "wrong relying
		// party", which is at least an honest error.
		// sokoni.app is parked and unowned; sokoni.bitshada.com is the real,
		// already-deployed domain this actually serves assetlinks.json from.
		RPIDHash: sha256.Sum256([]byte(env("SOKONI_RP_ID", "sokoni.bitshada.com"))),
		Tokens:   tokens,
		Gas:      gas,
		// See gateway.Config.AndroidCertFingerprints. Comma-separated: a
		// device is signed with one certificate at a time, but a real
		// rollout eventually needs the debug key, the release key, and
		// Play's own upload-signing key listed together.
		AndroidPackageName:      env("ANDROID_PACKAGE_NAME", "app.sokoni"),
		AndroidCertFingerprints: splitNonEmpty(os.Getenv("ANDROID_CERT_FINGERPRINTS")),
	}
	return cfg, w, nil
}

func run(log *slog.Logger) error {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	cfg, w, err := loadConfig()
	if err != nil {
		return err
	}

	rpc := chain.NewClient(w.rpcURL, 10)
	bnd := bundler.New(w.bundlerURL, cfg.EntryPoint, 10)
	sponsor, err := paymaster.NewSponsor(w.paymaster, cfg.ChainID, w.signerKey)
	if err != nil {
		return fmt.Errorf("sponsor: %w", err)
	}

	// ---- preflight: refuse to start on a configuration that cannot work -----
	ok, err := bnd.SupportsConfiguredEntryPoint(ctx)
	if err != nil {
		return fmt.Errorf("bundler unreachable: %w", err)
	}
	if !ok {
		return fmt.Errorf("bundler does not support EntryPoint %s — wrong version or wrong network", cfg.EntryPoint)
	}
	if err := sponsor.VerifyDeployment(ctx, rpc); err != nil {
		return err
	}
	log.Info("preflight passed", "chain", cfg.ChainID, "entryPoint", cfg.EntryPoint,
		"paymaster", w.paymaster, "signer", sponsor.SignerAddress(), "tokens", len(cfg.Tokens))

	accounts, meraAccounts, db, closeDB, err := openAccounts(ctx, w, log)
	if err != nil {
		return err
	}
	defer closeDB()

	ops, closeOps, err := openOps(w, log)
	if err != nil {
		return err
	}
	defer closeOps()

	// db is nil in the same no-DATABASE_URL laptop mode that leaves accounts
	// in memory -- Markets stays nil too, and the market-data endpoints/hub
	// degrade to a 503 rather than the gateway refusing to start.
	var markets gateway.MarketData
	if db != nil {
		markets = db
	}

	svc := gateway.NewService(cfg, gateway.Deps{
		Chain:        rpc,
		Bundler:      bnd,
		Sponsor:      sponsor,
		Accounts:     accounts,
		MeraAccounts: meraAccounts,
		Ops:          ops,
		Markets:      markets,
		Log:          log,
	})

	var hub *gateway.Hub
	if markets != nil {
		hub = gateway.NewHub(markets, log)
		go hub.Run(ctx, 750*time.Millisecond)
	}

	srv := &http.Server{
		Addr:              w.addr,
		Handler:           gateway.NewHandler(svc, hub, log),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	errc := make(chan error, 1)
	go func() {
		log.Info("gateway listening", "addr", w.addr)
		errc <- srv.ListenAndServe()
	}()

	select {
	case <-ctx.Done():
		shutdown, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		log.Info("shutting down")
		return srv.Shutdown(shutdown)
	case err := <-errc:
		if errors.Is(err, http.ErrServerClosed) {
			return nil
		}
		return err
	}
}

// openOps uses Redis when REDIS_URL is set, and memory otherwise. Memory is
// fine for a laptop and wrong for anything else: a restart forgets every
// operation between prepare and submit, so a phone that already has a signed
// assertion for one gets "no such operation" back for something it was just
// asked to sign.
func openOps(w wiring, log *slog.Logger) (gateway.PendingOps, func(), error) {
	if w.redisURL == "" {
		log.Warn("REDIS_URL not set; operations are in memory and a restart forgets them")
		return gateway.NewMemoryOps(time.Hour, nil), func() {}, nil
	}
	opt, err := redis.ParseURL(w.redisURL)
	if err != nil {
		return nil, nil, fmt.Errorf("parse REDIS_URL: %w", err)
	}
	rdb := redis.NewClient(opt)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := rdb.Ping(ctx).Err(); err != nil {
		rdb.Close()
		return nil, nil, fmt.Errorf("ping redis: %w", err)
	}
	return gateway.NewRedisOps(rdb, time.Hour), func() { rdb.Close() }, nil
}

// openAccounts uses Postgres when DATABASE_URL is set, and memory otherwise.
// Memory is fine for a laptop and wrong for anything else: a restart forgets
// every registration, and the phone has to register again.
//
// The returned *store.Store is nil in memory mode and non-nil otherwise --
// it backs Deps.Markets too (run's caller), so market data and accounts
// share one connection rather than opening a second pool.
// openAccounts also returns the Mera (Option 2) accounts store, sharing the
// same pool and id.Generator as the WebAuthn one rather than opening a
// second connection — both just mint account_id rows in the same table.
func openAccounts(ctx context.Context, w wiring, log *slog.Logger) (gateway.Accounts, gateway.MeraAccounts, *store.Store, func(), error) {
	if w.dsn == "" {
		log.Warn("DATABASE_URL not set; accounts are in memory and a restart forgets them")
		return gateway.NewMemoryAccounts(), gateway.NewMemoryMeraAccounts(), nil, func() {}, nil
	}
	db, err := store.Open(ctx, w.dsn)
	if err != nil {
		return nil, nil, nil, nil, fmt.Errorf("open database: %w", err)
	}
	gen, err := id.NewGenerator(w.nodeID)
	if err != nil {
		db.Close()
		return nil, nil, nil, nil, err
	}
	return gateway.NewPostgresAccounts(db.Pool(), gen),
		gateway.NewPostgresMeraAccounts(db.Pool(), gen),
		db, db.Close, nil
}
