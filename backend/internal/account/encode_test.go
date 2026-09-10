package account

import (
	"bytes"
	"encoding/json"
	"math/big"
	"os"
	"path/filepath"
	"testing"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/common/hexutil"
)

const vectorPath = "../../../contracts/test/fixtures/userop_vector.json"

// Numeric fields stay json.Number rather than float64 — the P-256 coordinates
// are 256-bit and would be destroyed by a float.
type vector struct {
	Factory               string `json:"factory"`
	CounterfactualAccount string `json:"counterfactualAccount"`

	SigOwnerIndex        json.Number `json:"sigOwnerIndex"`
	SigAuthenticatorData string      `json:"sigAuthenticatorData"`
	SigClientDataJSON    string      `json:"sigClientDataJSONHex"`
	SigChallengeIndex    json.Number `json:"sigChallengeIndex"`
	SigTypeIndex         json.Number `json:"sigTypeIndex"`
	SigR                 json.Number `json:"sigR"`
	SigS                 json.Number `json:"sigS"`
	EncodedSignature     string      `json:"encodedSignature"`

	ExecuteTarget  string      `json:"executeTarget"`
	ExecuteValue   json.Number `json:"executeValue"`
	ExecuteData    string      `json:"executeData"`
	EncodedExecute string      `json:"encodedExecute"`

	RpIDHash             string      `json:"rpIdHash"`
	OwnerX               json.Number `json:"ownerX"`
	OwnerY               json.Number `json:"ownerY"`
	Salt                 json.Number `json:"salt"`
	EncodedCreateAccount string      `json:"encodedCreateAccount"`
}

func loadVector(t *testing.T) vector {
	t.Helper()
	raw, err := os.ReadFile(filepath.Clean(vectorPath))
	if err != nil {
		t.Fatalf("read fixture: %v (run `make userop-vector`)", err)
	}
	var v vector
	if err := json.Unmarshal(raw, &v); err != nil {
		t.Fatalf("decode fixture: %v", err)
	}
	return v
}

func mustBig(t *testing.T, n json.Number) *big.Int {
	t.Helper()
	v, ok := new(big.Int).SetString(n.String(), 10)
	if !ok {
		t.Fatalf("not an integer: %q", n.String())
	}
	return v
}

func mustBytes(t *testing.T, s string) []byte {
	t.Helper()
	b, err := hexutil.Decode(s)
	if err != nil {
		t.Fatalf("decode %q: %v", s, err)
	}
	return b
}

func mustHash(t *testing.T, s string) [32]byte {
	t.Helper()
	var out [32]byte
	copy(out[:], mustBytes(t, s))
	return out
}

func vectorAssertion(t *testing.T, v vector) Assertion {
	t.Helper()
	return Assertion{
		AuthenticatorData: mustBytes(t, v.SigAuthenticatorData),
		ClientDataJSON:    string(mustBytes(t, v.SigClientDataJSON)),
		ChallengeIndex:    mustBig(t, v.SigChallengeIndex).Uint64(),
		TypeIndex:         mustBig(t, v.SigTypeIndex).Uint64(),
		R:                 mustBig(t, v.SigR),
		S:                 mustBig(t, v.SigS),
	}
}

func vectorOwners(t *testing.T, v vector) []Passkey {
	t.Helper()
	return []Passkey{{X: mustBig(t, v.OwnerX), Y: mustBig(t, v.OwnerY)}}
}

// The join between the authenticator and the account. If these bytes are wrong
// the account rejects every operation, and the bundler says only "AA23 reverted".
func TestEncodeSignatureMatchesTheContract(t *testing.T) {
	v := loadVector(t)

	got, err := EncodeSignature(mustBig(t, v.SigOwnerIndex).Uint64(), vectorAssertion(t, v))
	if err != nil {
		t.Fatalf("encode: %v", err)
	}
	if want := mustBytes(t, v.EncodedSignature); !bytes.Equal(got, want) {
		t.Fatalf("signature encoding mismatch\n got %x\nwant %x", got, want)
	}
}

func TestEncodeExecuteMatchesTheContract(t *testing.T) {
	v := loadVector(t)

	got, err := EncodeExecute(
		common.HexToAddress(v.ExecuteTarget),
		mustBig(t, v.ExecuteValue),
		mustBytes(t, v.ExecuteData))
	if err != nil {
		t.Fatalf("encode: %v", err)
	}
	if want := mustBytes(t, v.EncodedExecute); !bytes.Equal(got, want) {
		t.Fatalf("execute encoding mismatch\n got %x\nwant %x", got, want)
	}
}

func TestEncodeCreateAccountMatchesTheContract(t *testing.T) {
	v := loadVector(t)

	got, err := EncodeCreateAccount(mustHash(t, v.RpIDHash), vectorOwners(t, v), mustBig(t, v.Salt))
	if err != nil {
		t.Fatalf("encode: %v", err)
	}
	if want := mustBytes(t, v.EncodedCreateAccount); !bytes.Equal(got, want) {
		t.Fatalf("createAccount encoding mismatch\n got %x\nwant %x", got, want)
	}
}

// initCode is the factory address glued to that call, and nothing else.
func TestInitCodeIsFactoryPlusCreateCall(t *testing.T) {
	v := loadVector(t)
	factory := common.HexToAddress(v.Factory)

	got, err := InitCode(factory, mustHash(t, v.RpIDHash), vectorOwners(t, v), mustBig(t, v.Salt))
	if err != nil {
		t.Fatalf("initCode: %v", err)
	}
	if !bytes.Equal(got[:20], factory.Bytes()) {
		t.Errorf("first 20 bytes should be the factory, got %x", got[:20])
	}
	if want := mustBytes(t, v.EncodedCreateAccount); !bytes.Equal(got[20:], want) {
		t.Errorf("remainder should be the createAccount call\n got %x\nwant %x", got[20:], want)
	}
}

// getAddress and createAccount take identical arguments and differ only in
// selector — easy to get backwards, and the symptom would be funds sent to an
// address nothing deploys to.
func TestGetAddressDiffersOnlyBySelector(t *testing.T) {
	v := loadVector(t)
	owners := vectorOwners(t, v)
	rp := mustHash(t, v.RpIDHash)
	salt := mustBig(t, v.Salt)

	create, err := EncodeCreateAccount(rp, owners, salt)
	if err != nil {
		t.Fatal(err)
	}
	get, err := EncodeGetAddress(rp, owners, salt)
	if err != nil {
		t.Fatal(err)
	}

	if bytes.Equal(create[:4], get[:4]) {
		t.Fatal("selectors must differ")
	}
	if !bytes.Equal(create[4:], get[4:]) {
		t.Fatal("arguments must encode identically")
	}
	if want := Hex(selector(getAddressSig)); Hex(get[:4]) != want {
		t.Errorf("getAddress selector = %s, want %s", Hex(get[:4]), want)
	}
}

// The selector must be derived from the signature, not remembered.
func TestSelectorsAreDerived(t *testing.T) {
	// execute(address,uint256,bytes) — the one shared with the vector, so a
	// wrong derivation would already have failed above; assert it directly too.
	if got := Hex(selector("execute(address,uint256,bytes)")); got != "0xb61d27f6" {
		t.Errorf("execute selector = %s, want 0xb61d27f6", got)
	}
	if got := Hex(selector("getNonce(address,uint192)")); got != "0x35567e1a" {
		t.Errorf("getNonce selector = %s, want 0x35567e1a", got)
	}
}

func TestEncodeGetNonce(t *testing.T) {
	sender := common.HexToAddress("0xA1")
	got, err := EncodeGetNonce(sender, nil)
	if err != nil {
		t.Fatalf("encode: %v", err)
	}
	if len(got) != 4+32+32 {
		t.Fatalf("length %d, want 68", len(got))
	}
	if !bytes.Equal(got[4+12:4+32], sender.Bytes()) {
		t.Errorf("sender not in the first word: %x", got[4:36])
	}

	if _, err := EncodeGetNonce(sender, new(big.Int).Lsh(big.NewInt(1), 192)); err == nil {
		t.Error("expected an error for a key past uint192")
	}
	if _, err := EncodeGetNonce(sender, big.NewInt(-1)); err == nil {
		t.Error("expected an error for a negative key")
	}
}

func TestEncodeSignatureRejectsMalformedAssertions(t *testing.T) {
	v := loadVector(t)
	good := vectorAssertion(t, v)

	tests := []struct {
		name   string
		mutate func(Assertion) Assertion
	}{
		{"nil r", func(a Assertion) Assertion { a.R = nil; return a }},
		{"nil s", func(a Assertion) Assertion { a.S = nil; return a }},
		{"short authenticatorData", func(a Assertion) Assertion {
			a.AuthenticatorData = a.AuthenticatorData[:20]
			return a
		}},
		{"empty clientDataJSON", func(a Assertion) Assertion { a.ClientDataJSON = ""; return a }},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if _, err := EncodeSignature(0, tc.mutate(good)); err == nil {
				t.Fatal("expected an error")
			}
		})
	}
}

func TestFactoryCallsRejectBadOwners(t *testing.T) {
	rp := [32]byte{1}
	if _, err := EncodeCreateAccount(rp, nil, big.NewInt(0)); err == nil {
		t.Error("expected an error for no owners")
	}
	if _, err := EncodeCreateAccount(rp, []Passkey{{X: big.NewInt(1)}}, big.NewInt(0)); err == nil {
		t.Error("expected an error for a nil coordinate")
	}
}

// ownerIndex is a real field, not padding: changing it must change the bytes.
func TestOwnerIndexIsCarried(t *testing.T) {
	v := loadVector(t)
	a := vectorAssertion(t, v)

	first, err := EncodeSignature(0, a)
	if err != nil {
		t.Fatal(err)
	}
	second, err := EncodeSignature(1, a)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Equal(first, second) {
		t.Fatal("ownerIndex must affect the encoding")
	}
}
