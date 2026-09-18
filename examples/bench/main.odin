package main

import "core:fmt"
import "core:time"
import odon "odon:odragon"

Pos :: struct {
	x, y, z: f32,
}
Vel :: struct {
	x, y, z: f32,
}
TagA :: struct {}

N :: 1_000_000

main :: proc() {
	w := odon.world_create()
	defer odon.world_destroy(w)

	t0 := time.now()
	for i in 0 ..< N {
		e := odon.new_entity(w)
		odon.add(w, e, Pos)^ = {1, 2, 3}
		odon.add(w, e, Vel)^ = {1, 1, 1}
		if i % 10 == 0 {
			odon.add(w, e, TagA)
		}
	}
	fmt.printf("create %v entities (2-3 comps each): %v\n", N, time.since(t0))

	t1 := time.now()
	sum: f32
	{
		q := odon.query2(w, Pos, Vel)
		e: odon.Entity
		pos: ^Pos
		vel: ^Vel
		for odon.query_next(&q, &e, &pos, &vel) {
			sum += pos.x * vel.x
		}
	}
	fmt.printf("query2 iterate (Pos+Vel): %v (sum=%.0f)\n", time.since(t1), sum)

	mb := odon.mask_new(w)
	odon.mask_inc(&mb, Pos)
	odon.mask_inc(&mb, Vel)
	odon.mask_exc(&mb, TagA)
	m := odon.mask_build(&mb)
	defer odon.mask_destroy(&m)

	t2 := time.now()
	n := 0
	q2 := odon.query(w, &m)
	e2: odon.Entity
	for odon.query_next(&q2, &e2) {
		n += 1
	}
	fmt.printf("mask query (Pos+Vel, exc TagA): %v (matched=%v)\n", time.since(t2), n)

	t3 := time.now()
	r1 := odon.query_cached(w, &m)
	d_first := time.since(t3)
	t4 := time.now()
	r2 := odon.query_cached(w, &m)
	d_cached := time.since(t4)
	fmt.printf("cached query: first=%v repeat=%v (n=%v)\n", d_first, d_cached, len(r2))

	t5 := time.now()
	for i in 0 ..< 100_000 {
		odon.del_entity(w, odon.Entity(i32((i * 7) % N + 1)))
	}
	odon.world_release_del_buffer(w)
	for i in 0 ..< 100_000 {
		e := odon.new_entity(w)
		odon.add(w, e, Pos)^ = {1, 2, 3}
		odon.add(w, e, Vel)^ = {1, 1, 1}
	}
	fmt.printf("churn 100k delete + recreate: %v\n", time.since(t5))
}
