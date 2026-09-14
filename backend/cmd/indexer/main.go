// Command indexer follows Monad and maintains the read projections.
package main

import (
	"context"
	"log/slog"
	"os"
	"os/signal"
	"strconv"
	"syscall"

	"github.com/kenkomu/sokoni/backend/internal/chain"
	"github.com/kenkomu/sokoni/backend/internal/indexer"
	"github.com/kenkomu/sokoni/backend/internal/store"
)

func env(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func envU64(key string, def uint64) uint64 {
	if v := os.Getenv(key); v != "" {
		if n, err := strconv.ParseUint(v, 10, 64); err == nil {
			return n
		}
	}
	return def
}

func main() {
	log := slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	dsn := env("DATABASE_URL", "postgres://sokoni:sokoni@localhost:5433/sokoni")
	db, err := store.Open(ctx, dsn)
	if err != nil {
		log.Error("open database", "err", err)
		os.Exit(1)
	}
	defer db.Close()

	// Sustained RPC budget. The public endpoint rejects at 50/s, so sit well
	// under it and leave headroom for the gateway and treasury sharing it.
	rps := float64(envU64("INDEXER_RPC_RPS", 20))
	client := chain.NewClient(env("MONAD_RPC_HTTP", chain.MainnetRPC), rps,
		chain.WithBatchLimit(int(envU64("INDEXER_WINDOW", 16))))
	db.WithVenueClient(client)

	cfg := indexer.DefaultConfig()
	cfg.Window = envU64("INDEXER_WINDOW", 16)
	cfg.Confirmations = envU64("INDEXER_CONFIRMATIONS", 2)
	cfg.StartBlock = envU64("INDEXER_START_BLOCK", 0)

	log.Info("indexer starting", "rpc", env("MONAD_RPC_HTTP", chain.MainnetRPC), "rps", rps)

	if err := indexer.New(cfg, client, db, log).Run(ctx); err != nil {
		log.Error("indexer stopped with error", "err", err)
		os.Exit(1)
	}
}
