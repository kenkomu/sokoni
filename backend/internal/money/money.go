// Package money holds monetary amounts.
//
// An amount is a big.Int of base units plus the scale those units are in.
// Never a float: 0.1+0.2 is a rounding bug that costs real money, and float64
// silently loses integer precision above 2^53, which an 18-decimal token
// passes trivially.
//
// Tokens on Monad do not share a scale — AUSD and USDC are 6 decimals, MON and
// WMON are 18 — so the scale travels with the value rather than living in a
// constant somebody forgets to change.
package money

import (
	"database/sql/driver"
	"fmt"
	"math/big"
	"strings"
)

type Amount struct {
	units    *big.Int
	decimals int32
}

func New(units *big.Int, decimals int32) Amount {
	return Amount{units: new(big.Int).Set(units), decimals: decimals}
}

func Zero(decimals int32) Amount { return Amount{units: big.NewInt(0), decimals: decimals} }

// Parse reads a plain decimal string. It refuses input with more precision than
// the scale allows rather than silently truncating a user's amount.
func Parse(s string, decimals int32) (Amount, error) {
	s = strings.TrimSpace(s)
	if s == "" {
		return Amount{}, fmt.Errorf("empty amount")
	}
	neg := strings.HasPrefix(s, "-")
	s = strings.TrimPrefix(s, "-")

	whole, frac, _ := strings.Cut(s, ".")
	if whole == "" {
		whole = "0"
	}
	if !isDigits(whole) || (frac != "" && !isDigits(frac)) {
		return Amount{}, fmt.Errorf("not a decimal string: %q", s)
	}
	if int32(len(frac)) > decimals {
		return Amount{}, fmt.Errorf("%q has more precision than %d decimals", s, decimals)
	}
	frac += strings.Repeat("0", int(decimals)-len(frac))

	units, ok := new(big.Int).SetString(whole+frac, 10)
	if !ok {
		return Amount{}, fmt.Errorf("not a decimal string: %q", s)
	}
	if neg {
		units.Neg(units)
	}
	return Amount{units: units, decimals: decimals}, nil
}

func isDigits(s string) bool {
	for _, r := range s {
		if r < '0' || r > '9' {
			return false
		}
	}
	return len(s) > 0
}

func (a Amount) Units() *big.Int { return new(big.Int).Set(a.units) }
func (a Amount) Decimals() int32 { return a.decimals }
func (a Amount) IsZero() bool    { return a.units == nil || a.units.Sign() == 0 }
func (a Amount) Sign() int {
	if a.units == nil {
		return 0
	}
	return a.units.Sign()
}

// String renders a plain decimal. This is the only representation that crosses
// the API — JSON numbers would put it back through a float on some clients.
func (a Amount) String() string {
	if a.units == nil {
		return "0"
	}
	neg := a.units.Sign() < 0
	abs := new(big.Int).Abs(a.units).String()

	d := int(a.decimals)
	if d == 0 {
		return sign(neg) + abs
	}
	if len(abs) <= d {
		abs = strings.Repeat("0", d-len(abs)+1) + abs
	}
	whole, frac := abs[:len(abs)-d], abs[len(abs)-d:]
	frac = strings.TrimRight(frac, "0")
	if frac == "" {
		return sign(neg) + whole
	}
	return sign(neg) + whole + "." + frac
}

func sign(neg bool) string {
	if neg {
		return "-"
	}
	return ""
}

func (a Amount) MarshalJSON() ([]byte, error) { return []byte(`"` + a.String() + `"`), nil }

// Value implements driver.Valuer so an Amount round-trips through a
// numeric(38,18) column without going near a float.
func (a Amount) Value() (driver.Value, error) { return a.String(), nil }

func (a Amount) sameScale(b Amount) error {
	if a.decimals != b.decimals {
		return fmt.Errorf("scale mismatch: %d vs %d", a.decimals, b.decimals)
	}
	return nil
}

func (a Amount) Add(b Amount) (Amount, error) {
	if err := a.sameScale(b); err != nil {
		return Amount{}, err
	}
	return Amount{units: new(big.Int).Add(a.units, b.units), decimals: a.decimals}, nil
}

func (a Amount) Sub(b Amount) (Amount, error) {
	if err := a.sameScale(b); err != nil {
		return Amount{}, err
	}
	return Amount{units: new(big.Int).Sub(a.units, b.units), decimals: a.decimals}, nil
}

func (a Amount) Cmp(b Amount) (int, error) {
	if err := a.sameScale(b); err != nil {
		return 0, err
	}
	return a.units.Cmp(b.units), nil
}

// Rescale converts to another scale. It refuses a conversion that would drop
// significant digits rather than rounding silently.
func (a Amount) Rescale(decimals int32) (Amount, error) {
	if decimals == a.decimals {
		return a, nil
	}
	if decimals > a.decimals {
		mul := new(big.Int).Exp(big.NewInt(10), big.NewInt(int64(decimals-a.decimals)), nil)
		return Amount{units: new(big.Int).Mul(a.units, mul), decimals: decimals}, nil
	}
	div := new(big.Int).Exp(big.NewInt(10), big.NewInt(int64(a.decimals-decimals)), nil)
	q, r := new(big.Int).QuoRem(a.units, div, new(big.Int))
	if r.Sign() != 0 {
		return Amount{}, fmt.Errorf("rescale to %d would lose precision", decimals)
	}
	return Amount{units: q, decimals: decimals}, nil
}
