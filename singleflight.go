// Copyright (c) 2023 Bruno Marques Venceslau de Souza. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

// Copyright 2013 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

// Package singleflight provides a duplicate function call suppression
// mechanism with generic type support.
//
// This package is a type-safe wrapper around golang.org/x/sync/singleflight,
// providing generic type support through Group[K ~string, V any] and Result[V any]
// while maintaining 100% compatibility with the original package's behavior.
//
// The wrapper eliminates the need for type assertions in your code while
// preserving the exact same runtime behavior as the original package.
package singleflight

import (
	"golang.org/x/sync/singleflight"
)

// Group represents a class of work and forms a namespace in
// which units of work can be executed with duplicate suppression.
type Group[K ~string, V any] struct {
	group singleflight.Group
}

// Result holds the results of Do, so they can be passed
// on a channel.
type Result[V any] struct {
	Val    V
	Err    error
	Shared bool
}

// Do executes and returns the results of the given function, making
// sure that only one execution is in-flight for a given key at a
// time. If a duplicate comes in, the duplicate caller waits for the
// original to complete and receives the same results.
// The return value shared indicates whether v was given to multiple callers.
func (g *Group[K, V]) Do(key K, fn func() (V, error)) (v V, err error, shared bool) {
	result, err, shared := g.group.Do(string(key), func() (any, error) {
		return fn()
	})

	// Load-bearing guard: when fn produces a value (even a typed nil like
	// (*int)(nil) or a zero int), upstream boxes it into a non-nil any, so the
	// assertion runs and is safe. result is only nil when nothing was produced,
	// in which case v must stay V's zero value. Do not "simplify" to an
	// unconditional result.(V) — it would panic on the nil case.
	if result != nil {
		v = result.(V)
	}

	return v, err, shared
}

// DoChan is like Do but returns a channel that will receive the
// results when they are ready.
//
// The returned channel will not be closed.
//
// Each call starts one extra goroutine to translate the upstream result into a
// typed Result[V]; prefer Do when a channel is not needed. As with the upstream
// package, a panic in fn is re-raised on a dedicated goroutine and crashes the
// process — it cannot be recovered by the caller.
func (g *Group[K, V]) DoChan(key K, fn func() (V, error)) <-chan Result[V] {
	ch := make(chan Result[V], 1)

	upstreamCh := g.group.DoChan(string(key), func() (any, error) {
		return fn()
	})

	go g.convertDoChanResult(upstreamCh, ch)

	return ch
}

// Forget tells the singleflight to forget about a key. Future calls
// to Do for this key will call the function rather than waiting for
// an earlier call to complete.
func (g *Group[K, V]) Forget(key K) {
	g.group.Forget(string(key))
}

func (g *Group[K, V]) convertDoChanResult(src <-chan singleflight.Result, dst chan<- Result[V]) {
	srcResult := <-src

	result := Result[V]{
		Err:    srcResult.Err,
		Shared: srcResult.Shared,
	}

	// Same load-bearing guard as Do: only assert when upstream actually produced
	// a value, otherwise leave result.Val as V's zero value.
	if srcResult.Val != nil {
		result.Val = srcResult.Val.(V)
	}

	dst <- result
}
