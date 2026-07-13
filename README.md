# Singleflight with Generics!

[![GoDoc](https://pkg.go.dev/badge/pkg.venceslau.dev/singleflight)](https://pkg.go.dev/pkg.venceslau.dev/singleflight)

> Package singleflight provides a duplicate function call suppression mechanism.

A type-safe wrapper around [golang.org/x/sync/singleflight](https://golang.org/x/sync/singleflight) that adds generic type support.

- No more type assertions needed in your code:
  - `Group[K ~string, V any]` - A type-safe version of the original Group.
  - `Result[V any]` - A generic version of the Result type.
- 100% compatible with the original package, maintaining identical behavior.

For usage examples, see [examples_test.go](examples_test.go).

### Updates & Versioning

- This package will be kept in sync with the original `golang.org/x/sync/singleflight` package until it adds native generic support.
- Version tags will align with the original package's versioning.
- **If you notice an update before I do, please open an issue or submit a pull request**.
