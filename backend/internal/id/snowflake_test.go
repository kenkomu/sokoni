package id

import "testing"

func TestIDsAreUniqueAndMonotonic(t *testing.T) {
	g, err := NewGenerator(1)
	if err != nil {
		t.Fatal(err)
	}
	seen := make(map[int64]bool, 20000)
	var prev int64
	for range 20000 {
		v, err := g.Next()
		if err != nil {
			t.Fatal(err)
		}
		if seen[v] {
			t.Fatalf("duplicate id %d", v)
		}
		if v <= prev {
			t.Fatalf("id went backwards: %d after %d", v, prev)
		}
		seen[v] = true
		prev = v
	}
}

func TestNodeBoundsAreChecked(t *testing.T) {
	if _, err := NewGenerator(1024); err == nil {
		t.Fatal("expected out-of-range node to be rejected")
	}
}
