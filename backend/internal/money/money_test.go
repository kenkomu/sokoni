package money

import "testing"

func TestParseAndString(t *testing.T) {
	cases := []struct {
		in   string
		dec  int32
		want string
	}{
		{"1", 6, "1"},
		{"1.5", 6, "1.5"},
		{"0.000001", 6, "0.000001"},
		{"1234.567890", 6, "1234.56789"},
		{"-2.25", 6, "-2.25"},
		{"0", 18, "0"},
	}
	for _, c := range cases {
		a, err := Parse(c.in, c.dec)
		if err != nil {
			t.Fatalf("Parse(%q): %v", c.in, err)
		}
		if got := a.String(); got != c.want {
			t.Errorf("Parse(%q).String() = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestParseRefusesExcessPrecision(t *testing.T) {
	// AUSD is 6 decimals. Silently truncating a user's amount is a money bug.
	if _, err := Parse("1.0000001", 6); err == nil {
		t.Fatal("expected error for more precision than scale allows")
	}
}

func TestScaleMismatchIsAnError(t *testing.T) {
	ausd, _ := Parse("1", 6)
	mon, _ := Parse("1", 18)
	if _, err := ausd.Add(mon); err == nil {
		t.Fatal("expected scale mismatch adding 6-dec to 18-dec")
	}
}

func TestRescaleRefusesLossyDownscale(t *testing.T) {
	a, _ := Parse("1.000000000000000001", 18)
	if _, err := a.Rescale(6); err == nil {
		t.Fatal("expected refusal: downscale would drop significant digits")
	}
	b, _ := Parse("1.5", 18)
	c, err := b.Rescale(6)
	if err != nil || c.String() != "1.5" {
		t.Fatalf("clean downscale failed: %v %q", err, c.String())
	}
}
