# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A type-safe, generic wrapper around `golang.org/x/sync/singleflight`. The entire library is a single package (`singleflight.go`, ~90 lines) exposing `Group[K ~string, V any]` and `Result[V any]`, which delegate to an embedded `singleflight.Group` from the upstream package.

## Commands

```bash
go test ./... -race                          # run all tests with the race detector
go test ./... -race -run TestGroup_DoChan    # run a single test by name
go test ./... -race -coverprofile=cover.out  # tests with coverage (CI enforces totals)
golangci-lint run                            # lint (CI pins v2.12)
```

Requires Go 1.25+ (`go.mod` declares `go 1.25.0`). CI tests against Go 1.25.x and 1.26.x.

## Core design constraint

The wrapper must stay **100% behavior-compatible** with upstream `golang.org/x/sync/singleflight` — it only adds generic typing, never changes runtime semantics. When upstream changes its API, mirror it here exactly; when upstream gains native generics, this package becomes obsolete (see README's versioning policy: tags align with the upstream version).

A weekly scheduled workflow, `.github/workflows/upstream-check.yaml`, runs `.github/scripts/check-upstream.sh` and fails the run when upstream `golang.org/x/sync` has moved past the `go.mod` pin or the newest repo tag — that failure is the alarm that catch-up work (mirroring upstream, cutting an aligned tag) is due.

Implications for any change:
- The generic methods (`Do`, `DoChan`, `Forget`) are thin pass-throughs: convert `K` → `string` on the way in, and convert the upstream `any` result → `V` on the way out.
- The conversion guards with `if result != nil` before the `result.(V)` type assertion. This is deliberate — upstream returns `any`, and on the error path `fn` typically yields a nil value; asserting on nil would panic, so a nil result must fall through to `V`'s zero value instead.
- `DoChan` returns a buffered channel and spawns a goroutine (`convertDoChanResult`) to translate `singleflight.Result` → `Result[V]` as it arrives. Preserve the "channel is never closed" contract from upstream.

## Testing notes

Concurrency tests use `testing/synctest` (Go 1.25) to make goroutine scheduling deterministic — `synctest.Wait()` blocks until the first call is durably parked inside `fn` before the duplicate call is issued, so duplicate-suppression assertions (`Shared == true`, "second call should not execute") are reliable rather than racy. Follow this pattern for any new concurrency test instead of `time.Sleep`.

Coverage is gated in CI via `vladopajic/go-test-coverage`: 70% per-package/per-file, 93% total. New code paths generally need test coverage to pass.
