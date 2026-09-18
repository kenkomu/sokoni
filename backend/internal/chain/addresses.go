// Package chain holds everything that talks to Monad.
//
// Every address in this file was read back from chain and confirmed to
// carry bytecode, with EIP-55 checksums verified — most from
// https://rpc.monad.xyz (mainnet, chain 143) on 2026-09-09, a few later
// additions from https://testnet-rpc.monad.xyz (testnet, chain 10143) where
// noted. **Mainnet and testnet addresses are never interchangeable** — an
// address with real bytecode on one routinely has none on the other (see
// the Kuru section below for a bug this caused). Do not add an address here
// that has not been checked on-chain against the specific network it is for:
// a typo'd address is a silent loss of funds, not a crash.
package chain

// Network parameters.
const (
	MainnetChainID = 143
	TestnetChainID = 10143

	MainnetRPC = "https://rpc.monad.xyz"
	MainnetWS  = "wss://rpc.monad.xyz"
	TestnetRPC = "https://testnet-rpc.monad.xyz"
	TestnetWS  = "wss://testnet-rpc.monad.xyz"

	// BlockTime is the mean measured over 1,000 mainnet blocks on 2026-09-09.
	BlockTimeMS = 300

	// PublicRPCLimit is the ceiling the provider actually enforces. The Monad
	// docs say 25 rps; QuickNode rejects at 50/s with JSON-RPC code -32007.
	// Trust neither number — throttle to what you configured.
	PublicRPCLimit = 50
)

// Token is an ERC-20 we care about. Decimals differ across tokens on Monad
// (AUSD and USDC are 6, MON and WMON are 18), so the scale travels with the
// token rather than living in a constant somebody forgets to change.
type Token struct {
	Address  string
	Symbol   string
	Decimals int32
}

var (
	AUSD = Token{Address: "0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a", Symbol: "AUSD", Decimals: 6}
	USDC = Token{Address: "0x754704Bc059F8C67012fEd69BC8A327a5aafb603", Symbol: "USDC", Decimals: 6}
	WMON = Token{Address: "0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A", Symbol: "WMON", Decimals: 18}
)

// Agora Instant Settlement. Fixed-price, not an AMM: no constant-product curve,
// no external LPs, no price impact.
//
// Verified live on Monad: getPrice() is exactly 1e18, both purchase fees are 0,
// isPaused() is false, reserves ~9.79M AUSD / ~1.02M USDC.
//
// ACCESS IS GATED. Every swap path requires the APPROVED_SWAPPER role; ~71
// addresses hold it. See docs/adr/0004-agora-as-treasury-rail.md.
const (
	AgoraFactory      = "0x8468587Af422ad440F58a57E955eCA6A970b5375"
	AgoraPairAUSDUSDC = "0xf33286E3222D1c829dACeac48c0Ec651F6452470"

	RoleApprovedSwapper = "APPROVED_SWAPPER"
	RoleWhitelister     = "WHITELISTER_ROLE"
)

// ERC-4337. Both EntryPoint versions are canonical on Monad and verified
// deployed. We target v0.7.
const (
	EntryPointV07 = "0x0000000071727De22E5E9d8BAf0edAc6f37da032"
	EntryPointV06 = "0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789"

	// P256Precompile verifies secp256r1 signatures (EIP-7951). This is what
	// makes passkey accounts possible: the Secure Enclave's own curve, checked
	// natively on-chain.
	P256Precompile = "0x0000000000000000000000000000000000000100"
)

// Kuru. The on-chain CLOB ADR 1 builds around — this is "the matching core"
// the rest of the system reads state from and never reimplements.
//
// Every address below carries real bytecode on Monad **mainnet**, checked
// 2026-09-14 (block 104,763,787), EIP-55 checksummed. The two markets were
// published at docs.kuru.io/contracts/Contract-addresses. That page was not
// taken on faith: an independent keccak of `OrderCreated(uint40,address,
// uint96,uint32,bool)` from src/venue/kuru.go matched a real event topic0
// seen live on KuruMarketMONUSDC in the same block range — a coincidental
// match on a 32-byte hash is not something that happens by chance, so this
// is treated as confirming the whole event set the same page lists,
// including Trade, not merely the one event actually observed.
//
// All four addresses are 141-byte proxies of the same shape (see
// src/venue/kuru.go's note on the pattern) rather than four different full
// contracts, which is consistent with one factory deploying lightweight
// clones per market — the same shape SokoniAccountFactory uses for us.
//
// These are NOT valid on testnet — a chain-mismatch bug caught 2026-09-15:
// the backend runs against testnet (MONAD_RPC_HTTP=testnet-rpc.monad.xyz in
// .env.example), but the addresses below have empty bytecode there
// (eth_getCode == "0x"), which is why every seeded market showed zero
// trades forever, not because nobody had traded. See KuruTestnet below for
// the addresses actually deployed on 10143.
const (
	KuruRouter        = "0xd651346d7c789536ebf06dc72aE3C8502cd695CC"
	KuruMarginAccount = "0x2A68ba1833cDf93fa9Da1EEbd7F46242aD8E90c5"

	// Markets. venue_ref in the `markets` table points at one of these.
	KuruMarketMONAUSD = "0x131A2e70A5b31a517A74b8c567149bc294470Da9"
	KuruMarketMONUSDC = "0x065C9d28E428A0db40191a54d33d5b7c71a9C394"
)

// KuruTestnet holds the Monad testnet (10143) equivalents, verified live via
// eth_getCode on 2026-09-15 (block 62,756,147) and cross-checked against
// docs.kuru.io/contracts/Contract-addresses, which lists these same values.
// Only one official market exists on testnet — MON-USDC. There is no
// testnet MON-AUSD market: AUSD itself has no deployed contract on 10143
// (eth_getCode == "0x" at the mainnet AUSD address), so that pair cannot
// exist here at all, not merely "not yet traded."
//
// getMarketParams() (selector 0x90c9427c) was called live against
// KuruMarketMONUSDC and decoded by hand (cast call, no ABI on file for this
// contract): pricePrecision 1e8, baseAsset 0x0 (native MON, Kuru's
// convention per the mainnet migration's note), baseDecimals 18, quoteAsset
// KuruTestnetUSDC, quoteDecimals 6, tickSize raw 100 (=0.000001 at that
// precision), minSize raw 2e12 wei (=0.000002 MON) — identical human values
// to the mainnet market, so the seed migration's tick_size/min_qty/
// price_precision numbers carry over unchanged; only venue_ref and
// quote_token change.
const (
	KuruTestnetRouter        = "0x7EFbE105Ca7415dE98F96622173458ac1c054630"
	KuruTestnetMarginAccount = "0xd029C2D98ff85D8F64799017fE00a59B1159CE02"
	KuruTestnetForwarder     = "0x681bB1508E14433b148a2549ba2726454aDc9BB4"

	KuruTestnetMarketMONUSDC = "0xa241896A7Dbe8a550D2E5fF7A914bB1989ceD2D9"

	// Not the mainnet USDC — Kuru's own testnet quote token for this market,
	// a separate ERC-20 with a fixed 1e9-unit test supply (no public faucet
	// or mint function found; acquiring test balance is unresolved).
	KuruTestnetUSDC = "0x3bA3d39AFcf8bb994f7964B3e0171Ea2Ba361570"
)
