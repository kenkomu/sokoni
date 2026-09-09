// Package chain holds everything that talks to Monad.
//
// Every address in this file was read back from https://rpc.monad.xyz on
// 2026-09-09 (block 103,290,450) and confirmed to carry bytecode, with EIP-55
// checksums verified. Do not add an address here that has not been checked
// on-chain: a typo'd address is a silent loss of funds, not a crash.
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
