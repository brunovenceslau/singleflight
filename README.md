# Singleflight with Generics!

[![GoDoc](https://pkg.go.dev/badge/pkg.venceslau.dev/singleflight)](https://pkg.go.dev/pkg.venceslau.dev/singleflight)

> Package singleflight provides a duplicate function call suppression mechanism.

A type-safe wrapper around [golang.org/x/sync/singleflight](https://golang.org/x/sync/singleflight) that adds generic type support.

- No more type assertions needed in your code:
  - `Group[K ~string, V any]` - A type-safe version of the original Group.
  - `Result[V any]` - A generic version of the Result type.
- 100% compatible with the original package, maintaining identical behavior.

## Installation

```bash
go get pkg.venceslau.dev/singleflight
```

## Usage

### Do

Suppress duplicate in-flight calls for the same key; duplicates wait for the
original and receive the same result.

```go
package main

import (
	"fmt"

	"pkg.venceslau.dev/singleflight"
)

func main() {
	var g singleflight.Group[string, string]

	v, err, _ := g.Do("key", func() (string, error) {
		return "value", nil
	})

	fmt.Println(v, err)
	// Output: value <nil>
}
```

### DoChan

Like `Do`, but returns a channel that receives a typed `Result[V]` when ready.
Results are shared across calls made with a duplicate key.

```go
var g singleflight.Group[string, string]

block := make(chan struct{})
res1c := g.DoChan("key", func() (string, error) {
	<-block
	return "func 1", nil
})
res2c := g.DoChan("key", func() (string, error) {
	<-block
	return "func 2", nil
})
close(block)

res1 := <-res1c
res2 := <-res2c

fmt.Println("Shared:", res2.Shared)          // Shared: true
fmt.Println("Equal results:", res1.Val == res2.Val) // Equal results: true
fmt.Println("Result:", res1.Val)             // Result: func 1
```

### Forget

Drop the in-flight suppression entry for a key so the next call re-runs `fn`
instead of joining the original.

```go
g.Forget("key")
```

For runnable, tested examples see [examples_test.go](examples_test.go).

### Updates & Versioning

- This package will be kept in sync with the original `golang.org/x/sync/singleflight` package until it adds native generic support.
- Version tags will align with the original package's versioning.
- **If you notice an update before I do, please open an issue or submit a pull request**.
