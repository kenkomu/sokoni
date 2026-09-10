package gateway

import "testing"

const (
	usdc = "0x754704Bc059F8C67012fEd69BC8A327a5aafb603"
	ausd = "0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a"
)

func TestParseTokens(t *testing.T) {
	got, err := ParseTokens(usdc + ":USDC:6, " + ausd + ":AUSD:6")
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 || got[0].Symbol != "USDC" || got[1].Symbol != "AUSD" || got[1].Decimals != 6 {
		t.Fatalf("got %+v", got)
	}

	if got, err := ParseTokens("  "); err != nil || got != nil {
		t.Errorf("empty list: got %v, %v", got, err)
	}
}

func TestParseTokensRefusesMalformedEntries(t *testing.T) {
	for _, bad := range []string{
		"nope",
		"0x12:USDC:6",                        // not an address
		usdc + "::6",                         // no symbol
		usdc + ":USDC:six",                   // decimals not a number
		usdc + ":USDC:99",                    // implausible scale
		usdc + ":USDC",                       // missing decimals
		usdc + ":USDC:6," + usdc + ":USDC:6", // listed twice
	} {
		if _, err := ParseTokens(bad); err == nil {
			t.Errorf("%q must be refused", bad)
		}
	}
}
