// Copyright (c) 2023 Bruno Marques Venceslau de Souza. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

// Copyright 2013 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

package singleflight_test

import (
	"errors"
	"testing"
	"testing/synctest"

	"github.com/brunomvsouza/singleflight"
)

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
