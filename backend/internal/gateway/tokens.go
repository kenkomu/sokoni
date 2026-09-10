package gateway

import (
	"fmt"
	"strconv"
	"strings"

	"github.com/ethereum/go-ethereum/common"
)

// ParseTokens reads SPONSORED_TOKENS: comma-separated address:SYMBOL:decimals.
//
//	0x754704Bc059F8C67012fEd69BC8A327a5aafb603:USDC:6,0x...:AUSD:6
//
// Decimals travel with the token for the same reason they do in money.Amount:
// tokens on Monad do not share a scale, and a constant somebody forgets to
// change is a thousandfold error waiting to happen.
func ParseTokens(s string) ([]Token, error) {
	s = strings.TrimSpace(s)
	if s == "" {
		return nil, nil
	}
	var out []Token
	seen := make(map[common.Address]bool)
	for _, entry := range strings.Split(s, ",") {
		parts := strings.Split(strings.TrimSpace(entry), ":")
		if len(parts) != 3 {
			return nil, fmt.Errorf("token %q: want address:SYMBOL:decimals", entry)
		}
		if !common.IsHexAddress(parts[0]) {
			return nil, fmt.Errorf("token %q: %q is not an address", entry, parts[0])
		}
		if parts[1] == "" {
			return nil, fmt.Errorf("token %q: symbol is empty", entry)
		}
		dec, err := strconv.ParseInt(parts[2], 10, 32)
		if err != nil || dec < 0 || dec > 36 {
			return nil, fmt.Errorf("token %q: decimals must be 0..36", entry)
		}
		addr := common.HexToAddress(parts[0])
		if seen[addr] {
			return nil, fmt.Errorf("token %s listed twice", addr)
		}
		seen[addr] = true
		out = append(out, Token{Address: addr, Symbol: parts[1], Decimals: int32(dec)})
	}
	return out, nil
}
