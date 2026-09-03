// Copyright (c) 2023 Bruno Marques Venceslau de Souza. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

// Copyright 2013 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

package singleflight_test

import (
	"errors"
	"sync"
	"sync/atomic"
	"testing"
	"testing/synctest"

	upstream "golang.org/x/sync/singleflight"
	"pkg.venceslau.dev/singleflight"
)

// cacheKey exercises the K ~string constraint with a named string type rather
// than the builtin string.
type cacheKey string

func TestGroup_Do(t *testing.T) {
	t.Run("success", func(t *testing.T) {
		var g singleflight.Group[string, string]
		v, err, _ := g.Do("key", func() (string, error) {
			return "value", nil
		})
		if err != nil {
			t.Errorf("unexpected error: %v", err)
		}
		if v != "value" {
			t.Errorf("got %s, want %s", v, "value")
		}
	})

	t.Run("error", func(t *testing.T) {
		expectedErr := errors.New("test error")

		var g singleflight.Group[string, string]
		v, err, _ := g.Do("key", func() (string, error) {
			return "", expectedErr
		})

		if err != expectedErr {
			t.Errorf("got error %v, want %v", err, expectedErr)
		}
		if v != "" {
			t.Errorf("got value %s, want empty string", v)
		}
	})
}

// TestGroup_Do_NilValue exercises the false branch of the `if result != nil`
// guard in Do: a pointer V whose fn returns nil must yield a nil V (the zero
// value) without attempting the type assertion. A naive `v = result.(V)` would
// panic here while every other test still passed.
func TestGroup_Do_NilValue(t *testing.T) {
	var g singleflight.Group[string, *int]
	v, err, shared := g.Do("key", func() (*int, error) {
		return nil, nil
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if v != nil {
		t.Fatalf("got %v, want nil", v)
	}
	if shared {
		t.Errorf("shared = true; want false")
	}
}

// TestGroup_Do_Panic verifies the wrapper preserves upstream's contract that a
// panic in fn propagates to the caller of Do (rather than being swallowed by
// the any->V conversion).
func TestGroup_Do_Panic(t *testing.T) {
	var g singleflight.Group[string, string]
	defer func() {
		if r := recover(); r == nil {
			t.Fatal("expected panic to propagate, got none")
		}
	}()
	_, _, _ = g.Do("key", func() (string, error) {
		panic("boom")
	})
	t.Fatal("Do returned; expected panic")
}

// TestGroup_Do_SuppressesDuplicates is the core suppression guarantee: under N
// concurrent callers of the same key, fn must execute exactly once and every
// caller must receive the same value. The execution counter asserted == 1 is a
// stronger statement than "the second fn must not run". It also exercises the
// K ~string constraint via cacheKey.
func TestGroup_Do_SuppressesDuplicates(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		var g singleflight.Group[cacheKey, int]
		var calls atomic.Int64
		block := make(chan struct{})

		const n = 100
		results := make([]int, n)
		shared := make([]bool, n)
		var wg sync.WaitGroup
		wg.Add(n)
		for i := range n {
			go func(i int) {
				defer wg.Done()
				v, _, sh := g.Do("key", func() (int, error) {
					calls.Add(1)
					<-block
					return 42, nil
				})
				results[i], shared[i] = v, sh
			}(i)
		}

		synctest.Wait() // all n goroutines parked: one in fn, n-1 waiting on it
		close(block)
		wg.Wait()

		if got := calls.Load(); got != 1 {
			t.Fatalf("fn executed %d times; want exactly 1", got)
		}
		sharedCount := 0
		for i := range n {
			if results[i] != 42 {
				t.Fatalf("results[%d] = %d; want 42", i, results[i])
			}
			if shared[i] {
				sharedCount++
			}
		}
		// With duplicate suppression in effect, at least the suppressed callers
		// must observe Shared=true.
		if sharedCount == 0 {
			t.Errorf("no caller saw Shared=true; want at least the duplicates")
		}
	})
}

func TestGroup_DoChan(t *testing.T) {
	t.Run("single call", func(t *testing.T) {
		synctest.Test(t, func(t *testing.T) {
			var g singleflight.Group[string, int]
			ch := g.DoChan("key", func() (int, error) {
				return 42, nil
			})

			res := <-ch
			if got, want := res.Val, 42; got != want {
				t.Errorf("DoChan = %v; want %v", got, want)
			}
			if res.Err != nil {
				t.Errorf("DoChan error = %v", res.Err)
			}
			if res.Shared {
				t.Errorf("DoChan shared = true; want false")
			}
		})
	})

	t.Run("concurrent calls", func(t *testing.T) {
		synctest.Test(t, func(t *testing.T) {
			var g singleflight.Group[string, int]
			unblock := make(chan struct{})

			ch1 := g.DoChan("key", func() (int, error) {
				<-unblock
				return 42, nil
			})

			// Wait until the first call is durably blocked inside fn before
			// issuing the duplicate, so the suppression is deterministic.
			synctest.Wait()

			ch2 := g.DoChan("key", func() (int, error) {
				t.Error("second call should not be executed")
				return 0, nil
			})

			close(unblock)

			res1 := <-ch1
			if got, want := res1.Val, 42; got != want {
				t.Errorf("first DoChan = %v; want %v", got, want)
			}
			if !res1.Shared {
				t.Errorf("first DoChan shared = false; want true")
			}

			res2 := <-ch2
			if got, want := res2.Val, 42; got != want {
				t.Errorf("second DoChan = %v; want %v", got, want)
			}
			if !res2.Shared {
				t.Errorf("second DoChan shared = false; want true")
			}
		})
	})
}

// TestGroup_DoChan_ResultConversion covers convertDoChanResult across the value,
// nil-value (the `if srcResult.Val != nil` false branch), and error paths — none
// of which were exercised before.
func TestGroup_DoChan_ResultConversion(t *testing.T) {
	wantErr := errors.New("boom")
	tests := []struct {
		name    string
		fn      func() (*int, error)
		wantNil bool
		wantErr error
	}{
		{"nil value", func() (*int, error) { return nil, nil }, true, nil},
		{"non-nil value", func() (*int, error) { x := 7; return &x, nil }, false, nil},
		{"error with nil value", func() (*int, error) { return nil, wantErr }, true, wantErr},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			synctest.Test(t, func(t *testing.T) {
				var g singleflight.Group[string, *int]
				res := <-g.DoChan("key", tt.fn)
				if (res.Val == nil) != tt.wantNil {
					t.Errorf("Val nil = %v; want %v", res.Val == nil, tt.wantNil)
				}
				if !errors.Is(res.Err, tt.wantErr) {
					t.Errorf("Err = %v; want %v", res.Err, tt.wantErr)
				}
			})
		})
	}
}

// TestGroup_DoChan_SharedError confirms a failing in-flight call still suppresses
// duplicates and that Shared=true is propagated alongside the error.
func TestGroup_DoChan_SharedError(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		wantErr := errors.New("boom")
		var g singleflight.Group[string, int]
		block := make(chan struct{})

		ch1 := g.DoChan("key", func() (int, error) {
			<-block
			return 0, wantErr
		})
		synctest.Wait()
		ch2 := g.DoChan("key", func() (int, error) {
			t.Error("second fn must not run")
			return 0, nil
		})
		close(block)

		for i, ch := range []<-chan singleflight.Result[int]{ch1, ch2} {
			res := <-ch
			if !errors.Is(res.Err, wantErr) {
				t.Errorf("caller %d Err = %v; want %v", i, res.Err, wantErr)
			}
			if !res.Shared {
				t.Errorf("caller %d Shared = false; want true", i)
			}
		}
	})
}

// TestGroup_Forget verifies the de-suppression semantics: forgetting an in-flight
// key makes the next Do/DoChan re-run fn instead of joining the original call.
// This is the only behavior of Forget, and nothing exercised it before.
func TestGroup_Forget(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		var g singleflight.Group[string, int]
		var calls atomic.Int64
		block := make(chan struct{})

		ch1 := g.DoChan("key", func() (int, error) {
			calls.Add(1)
			<-block
			return 1, nil
		})
		synctest.Wait() // first call durably in-flight

		g.Forget("key") // drop the in-flight suppression entry

		ch2 := g.DoChan("key", func() (int, error) {
			calls.Add(1)
			<-block
			return 2, nil
		})
		synctest.Wait()

		close(block)
		r1, r2 := <-ch1, <-ch2

		if got := calls.Load(); got != 2 {
			t.Fatalf("fn executed %d times; want 2 after Forget", got)
		}
		if r1.Shared || r2.Shared {
			t.Errorf("Shared = (%v,%v); want both false after Forget", r1.Shared, r2.Shared)
		}
		if r1.Val != 1 || r2.Val != 2 {
			t.Errorf("got (%d,%d); want (1,2)", r1.Val, r2.Val)
		}
	})
}

// TestParity_WithUpstream pins the package's headline claim — "100% compatibility
// with the original package's behavior" — by running the same call sequence
// against both the wrapper and golang.org/x/sync/singleflight and asserting the
// observable results (value, error, shared) match.
func TestParity_WithUpstream(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		var g singleflight.Group[string, string]
		var u upstream.Group
		block := make(chan struct{})

		gch := g.DoChan("k", func() (string, error) { <-block; return "v", nil })
		uch := u.DoChan("k", func() (any, error) { <-block; return "v", nil })
		synctest.Wait()
		gch2 := g.DoChan("k", func() (string, error) { return "x", nil })
		uch2 := u.DoChan("k", func() (any, error) { return "x", nil })
		close(block)

		gr, ur := <-gch, <-uch
		gr2, ur2 := <-gch2, <-uch2

		if gr.Val != ur.Val.(string) || gr.Shared != ur.Shared || gr.Err != ur.Err {
			t.Errorf("primary: wrapper{%v %v %v} != upstream{%v %v %v}",
				gr.Val, gr.Shared, gr.Err, ur.Val, ur.Shared, ur.Err)
		}
		if gr2.Val != ur2.Val.(string) || gr2.Shared != ur2.Shared {
			t.Errorf("duplicate: wrapper{%v %v} != upstream{%v %v}",
				gr2.Val, gr2.Shared, ur2.Val, ur2.Shared)
		}
	})
}

// Note on panic semantics: a panic in fn passed to DoChan is re-raised by
// upstream via `go panic(e)`, which deliberately crashes the whole process and
// cannot be recovered. It is therefore intentionally not tested here — doing so
// would kill the test binary. The wrapper inherits this behavior unchanged; see
// TestGroup_Do_Panic for the recoverable Do path.
