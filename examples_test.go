package singleflight_test

import (
	"fmt"

	"pkg.venceslau.dev/singleflight"
)

func ExampleGroup_Do() {
	var g singleflight.Group[string, string]

	v, err, _ := g.Do("key", func() (string, error) {
		return "value", nil
	})

	fmt.Println(v, err)

	// Output: value <nil>
}

func ExampleGroup_DoChan() {
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

	// Results are shared by functions executed with duplicate keys.
	fmt.Println("Shared:", res2.Shared)
	// Only the first function is executed: it is registered and started with "key",
	// and doesn't complete before the second function is registered with a duplicate key.
	fmt.Println("Equal results:", res1.Val == res2.Val)
	fmt.Println("Result:", res1.Val)

	// Output:
	// Shared: true
	// Equal results: true
	// Result: func 1
}

func ExampleGroup_Forget() {
	var g singleflight.Group[string, string]

	g.Forget("key")
}
