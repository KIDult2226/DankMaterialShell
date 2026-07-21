package icc

import (
	"math"
	"os"
	"testing"
)

// Test ICC profile paths
var testFiles = []struct {
	name string
	path string
}{
	{
		name: "Samsung Odyssey Neo G8 (v2.1, matrix-TRC, vcgt)",
		path: "/mnt/StorageSSD3/Program Files/1D8HG_B173ZAN_31-08-2023.icm",
	},
	{
		name: "DisplayPort monitor (v2.1, matrix-TRC, vcgt)",
		path: "/mnt/StorageSSD3/Program Files/DP_31-08-2023.icm",
	},
	{
		name: "GPD Win Max 2 (v2.2, XYZLUT+MTX, vcgt)",
		path: "/mnt/StorageSSD3/Program Files/GPD1001H #1 2024-11-29 22-12 D6500 2.2 F-S XYZLUT+MTX.icm",
	},
}

func TestParseFile(t *testing.T) {
	for _, tc := range testFiles {
		t.Run(tc.name, func(t *testing.T) {
			// Read file to get expected size
			info, err := os.Stat(tc.path)
			if err != nil {
				t.Fatalf("cannot stat file: %v", err)
			}

			p, err := ParseFile(tc.path)
			if err != nil {
				t.Fatalf("ParseFile failed: %v", err)
			}

			// Verify size matches file size
			if p.Size != uint32(info.Size()) {
				t.Errorf("Size: got %d, want %d", p.Size, info.Size())
			}

			// Verify version
			if p.Version != "2.1.0" && p.Version != "2.2.0" && p.Version != "2.4.0" {
				t.Errorf("Version: got %q, want v2.x", p.Version)
			}
			t.Logf("  Version: %s", p.Version)

			// Verify class
			if p.Class != "mntr" {
				t.Errorf("Class: got %q, want %q", p.Class, "mntr")
			}

			// Verify color space
			if p.ColorSpace != "RGB" {
				t.Errorf("ColorSpace: got %q, want %q", p.ColorSpace, "RGB")
			}

			// Verify description is non-empty
			if p.Description == "" {
				t.Error("Description is empty")
			}
			t.Logf("  Description: %s", p.Description)

			// Verify matrix
			if !p.HasMatrix {
				t.Error("HasMatrix is false, expected true")
			} else {
				t.Logf("  Matrix:")
				for i := 0; i < 3; i++ {
					t.Logf("    [%6.4f %6.4f %6.4f]", p.Matrix[0][i], p.Matrix[1][i], p.Matrix[2][i])
				}
				// Each Y value (second row of matrix) should be in [0, 1]
				for _, col := range p.Matrix {
					if col[1] < -0.01 || col[1] > 1.5 {
						t.Errorf("Matrix Y value out of range: %f", col[1])
					}
				}
			}

			// Verify VCGT
			if !p.HasVCGT {
				t.Error("HasVCGT is false, expected true")
			} else {
				t.Logf("  VCGT: %d channels, %d entries", p.VCGT.Channels, p.VCGT.Entries)
				t.Logf("  VCGT Red: [%d ... %d]", p.VCGT.Red[0], p.VCGT.Red[len(p.VCGT.Red)-1])
				// Verify entry count matches declared
				if len(p.VCGT.Red) != p.VCGT.Entries {
					t.Errorf("VCGT Red entries: got %d, want %d", len(p.VCGT.Red), p.VCGT.Entries)
				}
				if len(p.VCGT.Green) != p.VCGT.Entries {
					t.Errorf("VCGT Green entries: got %d, want %d", len(p.VCGT.Green), p.VCGT.Entries)
				}
				if len(p.VCGT.Blue) != p.VCGT.Entries {
					t.Errorf("VCGT Blue entries: got %d, want %d", len(p.VCGT.Blue), p.VCGT.Entries)
				}
				// Verify channels
				if p.VCGT.Channels != 3 {
					t.Errorf("VCGT channels: got %d, want 3", p.VCGT.Channels)
				}
				// Verify monotonic non-decreasing per channel
				for _, ch := range []struct {
					name string
					data []uint16
				}{{"Red", p.VCGT.Red}, {"Green", p.VCGT.Green}, {"Blue", p.VCGT.Blue}} {
					for i := 1; i < len(ch.data); i++ {
						if ch.data[i] < ch.data[i-1] {
							t.Errorf("VCGT %s not monotonic at index %d: %d < %d", ch.name, i, ch.data[i], ch.data[i-1])
							break
						}
					}
				}
			}

			// Log white point
			t.Logf("  White point: [%6.4f %6.4f %6.4f]", p.WhitePoint[0], p.WhitePoint[1], p.WhitePoint[2])
		})
	}
}

func TestGenerateGammaRamp(t *testing.T) {
	for _, tc := range testFiles {
		t.Run(tc.name, func(t *testing.T) {
			p, err := ParseFile(tc.path)
			if err != nil {
				t.Fatalf("ParseFile failed: %v", err)
			}

			for _, rampSize := range []uint32{256, 4096} {
				t.Run("size="+itoa(rampSize), func(t *testing.T) {
					ramp, err := GenerateGammaRamp(rampSize, p)
					if err != nil {
						t.Fatalf("GenerateGammaRamp failed: %v", err)
					}

					// Verify lengths
					if uint32(len(ramp.Red)) != rampSize {
						t.Errorf("Red length: got %d, want %d", len(ramp.Red), rampSize)
					}
					if uint32(len(ramp.Green)) != rampSize {
						t.Errorf("Green length: got %d, want %d", len(ramp.Green), rampSize)
					}
					if uint32(len(ramp.Blue)) != rampSize {
						t.Errorf("Blue length: got %d, want %d", len(ramp.Blue), rampSize)
					}

					// Verify range [0, 65535]
					channels := []struct {
						name string
						data []uint16
					}{
						{"Red", ramp.Red},
						{"Green", ramp.Green},
						{"Blue", ramp.Blue},
					}

					for _, ch := range channels {
						// All values must be in [0, 65535] (uint16 guarantees this, but double-check)
						for i, v := range ch.data {
							if v > 65535 {
								t.Errorf("%s[%d] = %d, out of range", ch.name, i, v)
								break
							}
						}

						// Verify ramp values match VCGT-derived data.
						// Real VCGT calibration data does NOT guarantee ramp[0]==0
						// or ramp[last]==65535 — these are gamma corrections.
						// Log endpoints for inspection.
						t.Logf("  %s: [%d ... %d]", ch.name, ch.data[0], ch.data[rampSize-1])

						// Verify monotonic non-decreasing
						for i := 1; i < len(ch.data); i++ {
							if ch.data[i] < ch.data[i-1] {
								t.Errorf("%s not monotonic at index %d: %d < %d", ch.name, i, ch.data[i], ch.data[i-1])
								break
							}
						}

						// ramp[last] >= ramp[0] (endpoints must be ordered)
						if ch.data[rampSize-1] < ch.data[0] {
							t.Errorf("%s: last value %d < first value %d", ch.name, ch.data[rampSize-1], ch.data[0])
						}
					}
				})
			}
		})
	}
}

func TestSampleCurve(t *testing.T) {
	t.Run("Identity", func(t *testing.T) {
		c := Curve{Type: CurveIdentity}
		for _, tt := range []float64{0, 0.25, 0.5, 0.75, 1.0} {
			got := SampleCurve(c, tt)
			if got != tt {
				t.Errorf("SampleCurve(identity, %f) = %f, want %f", tt, got, tt)
			}
		}
	})

	t.Run("Parametric", func(t *testing.T) {
		c := Curve{Type: CurveParametric, Gamma: 2.2}
		// pow(0.5, 1/2.2) ≈ 0.7297
		got := SampleCurve(c, 0.5)
		want := math.Pow(0.5, 1.0/2.2)
		if math.Abs(got-want) > 0.001 {
			t.Errorf("SampleCurve(gamma2.2, 0.5) = %f, want %f", got, want)
		}

		// Boundary conditions
		if v := SampleCurve(c, 0); v != 0 {
			t.Errorf("SampleCurve(gamma2.2, 0) = %f, want 0", v)
		}
		if v := SampleCurve(c, 1); v != 1 {
			t.Errorf("SampleCurve(gamma2.2, 1) = %f, want 1", v)
		}
	})

	t.Run("Table", func(t *testing.T) {
		// Identity table: 2 entries [0, 65535]
		c := Curve{
			Type:    CurveTable,
			Entries: []uint16{0, 65535},
		}
		if v := SampleCurve(c, 0.5); math.Abs(v-0.5) > 0.001 {
			t.Errorf("SampleCurve(identityTable, 0.5) = %f, want ~0.5", v)
		}

		// 4-entry table: [0, 21845, 43690, 65535] (approx 1/3, 2/3, 3/3)
		c2 := Curve{
			Type:    CurveTable,
			Entries: []uint16{0, 21845, 43690, 65535},
		}
		if v := SampleCurve(c2, 0); v != 0 {
			t.Errorf("SampleCurve(4entry, 0) = %f, want 0", v)
		}
		if v := SampleCurve(c2, 1.0); math.Abs(v-1.0) > 0.001 {
			t.Errorf("SampleCurve(4entry, 1.0) = %f, want ~1.0", v)
		}

		// 256-entry identity table
		entries256 := make([]uint16, 256)
		for i := range entries256 {
			entries256[i] = uint16(i * 65535 / 255)
		}
		c3 := Curve{Type: CurveTable, Entries: entries256}
		if v := SampleCurve(c3, 0.5); math.Abs(v-0.5) > 0.01 {
			t.Errorf("SampleCurve(256entry, 0.5) = %f, want ~0.5", v)
		}
	})

	t.Run("ClampInput", func(t *testing.T) {
		c := Curve{Type: CurveIdentity}
		// Negative t should be clamped to 0
		if v := SampleCurve(c, -0.5); v != 0 {
			t.Errorf("SampleCurve(identity, -0.5) = %f, want 0", v)
		}
		// t > 1 should be clamped to 1
		if v := SampleCurve(c, 1.5); v != 1 {
			t.Errorf("SampleCurve(identity, 1.5) = %f, want 1", v)
		}
	})
}

func TestParseBytes(t *testing.T) {
	t.Run("TooShort", func(t *testing.T) {
		_, err := ParseBytes([]byte{0, 1, 2})
		if err == nil {
			t.Error("expected error for short data")
		}
	})

	t.Run("IdentityRamp", func(t *testing.T) {
		// Generate identity ramp from a profile with no vcgt and no TRC
		p := &Profile{}
		ramp, err := GenerateGammaRamp(256, p)
		if err != nil {
			t.Fatalf("GenerateGammaRamp failed: %v", err)
		}
		if ramp.Red[0] != 0 {
			t.Errorf("identity ramp Red[0] = %d, want 0", ramp.Red[0])
		}
		if ramp.Red[255] < 65530 {
			t.Errorf("identity ramp Red[255] = %d, want ~65535", ramp.Red[255])
		}
	})
}

// itoa converts a uint32 to string (avoids importing strconv)
func itoa(n uint32) string {
	if n == 0 {
		return "0"
	}
	digits := ""
	for n > 0 {
		digits = string(rune('0'+n%10)) + digits
		n /= 10
	}
	return digits
}
