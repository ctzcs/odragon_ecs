package main

// Comprehensive ECS benchmark suite, mirrored scenario-for-scenario by
// bench_cs/ (DragonECS, .NET). Each scenario reports the best of N runs.

import "core:fmt"
import "core:time"
import odon "odon:odragon"

Pos :: struct {
	x, y, z: f32,
}
Vel :: struct {
	x, y, z: f32,
}
Health :: struct {
	hp: f32,
}
Mana :: struct {
	mp: f32,
}
Buff :: struct {
	t: f32,
}
TagA :: struct {}

N :: 1_000_000
CHURN :: 100_000
REPEATS :: 5

State :: struct {
	w:        ^odon.World,
	order:    []i32,
	sink:     f32,
	mask_exc: odon.Mask,
	mask_any: odon.Mask,
}

populate :: proc(w: ^odon.World) {
	// cached pool pointers: the standard hot-path pattern (same as caching
	// EcsPool<T> references on the C# side)
	poses := odon.get_pool(w, Pos)
	vels := odon.get_pool(w, Vel)
	hps := odon.get_pool(w, Health)
	manas := odon.get_pool(w, Mana)
	tags := odon.get_tag_pool(w, TagA)
	for i in 0 ..< N {
		e := odon.new_entity(w)
		odon.pool_set(poses, e, Pos{1, 2, 3})
		odon.pool_set(vels, e, Vel{1, 1, 1})
		odon.pool_set(hps, e, Health{100})
		if i % 10 == 0 {
			odon.pool_set(manas, e, Mana{50})
			odon.tag_pool_add(tags, e)
		}
	}
}

measure :: proc(name: string, repeats: int, f: proc(), after_each: proc() = nil) {
	best := time.Duration(max(i64))
	for i in 0 ..< repeats {
		t0 := time.now()
		f()
		d := time.since(t0)
		if d < best {
			best = d
		}
		if after_each != nil {
			after_each()
		}
	}
	fmt.printf("  %-46s %9v\n", name, best)
}

main :: proc() {
	s := State{}
	context.user_ptr = &s

	// permutation of ids 1..N for the random-access scenario
	s.order = make([]i32, N)
	defer delete(s.order)
	{
		stride :: 999_983 // coprime with N: visits every id exactly once
		x := 0
		for i in 0 ..< N {
			s.order[i] = i32(x) + 1
			x = (x + stride) % N
		}
	}

	// --- create (populate only; world recycled between runs, untimed) ---
	s.w = odon.world_create()
	measure(
		"create 1M entities (Pos+Vel+Health, 10% +Mana+Tag)",
		3,
		proc() {
			s := (^State)(context.user_ptr)
			populate(s.w)
		},
		proc() {
			s := (^State)(context.user_ptr)
			odon.world_destroy(s.w)
			s.w = odon.world_create()
		},
	)

	// same, with capacity hints (world_create cap + pool_reserve, both set up
	// outside the timed region — matching the C# EcsWorldConfig ctor)
	prepare_reserved :: proc(s: ^State) {
		odon.world_destroy(s.w)
		s.w = odon.world_create(initial_capacity = N)
		odon.pool_reserve(odon.get_pool(s.w, Pos), N)
		odon.pool_reserve(odon.get_pool(s.w, Vel), N)
		odon.pool_reserve(odon.get_pool(s.w, Health), N)
		odon.pool_reserve(odon.get_pool(s.w, Mana), N)
		odon.tag_pool_reserve(odon.get_tag_pool(s.w, TagA), N)
	}
	prepare_reserved(&s)
	measure(
		"create 1M entities, reserved",
		3,
		proc() {
			s := (^State)(context.user_ptr)
			populate(s.w)
		},
		proc() {
			s := (^State)(context.user_ptr)
			prepare_reserved(s)
		},
	)

	// persistent bench world
	populate(s.w)
	defer odon.world_destroy(s.w)

	mb := odon.mask_new(s.w)
	odon.mask_inc(&mb, Pos)
	odon.mask_inc(&mb, Vel)
	odon.mask_exc(&mb, TagA)
	s.mask_exc = odon.mask_build(&mb)
	defer odon.mask_destroy(&s.mask_exc)

	mb2 := odon.mask_new(s.w)
	odon.mask_inc(&mb2, Pos)
	odon.mask_any(&mb2, Vel)
	odon.mask_any(&mb2, Mana)
	s.mask_any = odon.mask_build(&mb2)
	defer odon.mask_destroy(&s.mask_any)

	measure("iterate query1 (Pos) x1M", REPEATS, proc() {
		s := (^State)(context.user_ptr)
		q := odon.query1(s.w, Pos)
		e: odon.Entity
		p: ^Pos
		sum: f32
		for odon.query_next(&q, &e, &p) {
			sum += p.x
		}
		s.sink += sum
	})

	measure("iterate query2 (Pos+Vel, write) x1M", REPEATS, proc() {
		s := (^State)(context.user_ptr)
		q := odon.query2(s.w, Pos, Vel)
		e: odon.Entity
		p: ^Pos
		v: ^Vel
		for odon.query_next(&q, &e, &p, &v) {
			p.x += v.x
		}
	})

	measure("iterate query3 (Pos+Vel+Health, write) x1M", REPEATS, proc() {
		s := (^State)(context.user_ptr)
		q := odon.query3(s.w, Pos, Vel, Health)
		e: odon.Entity
		p: ^Pos
		v: ^Vel
		h: ^Health
		for odon.query_next(&q, &e, &p, &v, &h) {
			p.x += v.x * 0.0001
			h.hp -= 0.0001
		}
	})

	measure("iterate sparse query2 (Pos+Mana) x100k", REPEATS, proc() {
		s := (^State)(context.user_ptr)
		q := odon.query2(s.w, Pos, Mana)
		e: odon.Entity
		p: ^Pos
		m: ^Mana
		sum: f32
		for odon.query_next(&q, &e, &p, &m) {
			sum += p.x + m.mp
		}
		s.sink += sum
	})

	measure("mask query scan, uncached (Pos+Vel, exc Tag) x900k", REPEATS, proc() {
		s := (^State)(context.user_ptr)
		n: i32
		q := odon.query_uncached(s.w, &s.mask_exc)
		e: odon.Entity
		for odon.query_next(&q, &e) {
			n += 1
		}
		s.sink += f32(n)
	})

	measure("mask query scan, uncached (Pos, any Vel|Mana) x1M", REPEATS, proc() {
		s := (^State)(context.user_ptr)
		n: i32
		q := odon.query_uncached(s.w, &s.mask_any)
		e: odon.Entity
		for odon.query_next(&q, &e) {
			n += 1
		}
		s.sink += f32(n)
	})

	measure("query() auto-cached repeat (exc Tag) x900k", REPEATS, proc() {
		s := (^State)(context.user_ptr)
		n: i32
		q := odon.query(s.w, &s.mask_exc)
		e: odon.Entity
		for #force_inline odon.query_next(&q, &e) {
			n += i32(e)
		}
		s.sink += f32(n)
	})

	measure("cached query repeat + iterate slice x900k", REPEATS, proc() {
		s := (^State)(context.user_ptr)
		r := odon.query_cached(s.w, &s.mask_exc)
		n: i32
		for e in r {
			n += i32(e) // sum ids: forces a real pass over the slice
		}
		s.sink += f32(n)
	})

	measure("random access pool_get x1M (permutation)", REPEATS, proc() {
		s := (^State)(context.user_ptr)
		pool := odon.get_pool(s.w, Pos)
		sum: f32
		for id in s.order {
			sum += odon.pool_get(pool, odon.Entity(id)).x
		}
		s.sink += sum
	})

	measure(
		"churn: add+del Buff on 100k entities",
		REPEATS,
		proc() {
			s := (^State)(context.user_ptr)
			buffs := odon.get_pool(s.w, Buff)
			for i in 1 ..= CHURN {
				odon.pool_add(buffs, odon.Entity(i32(i)))^ = {0.5}
			}
			for i in 1 ..= CHURN {
				odon.pool_del(buffs, odon.Entity(i32(i)))
			}
		},
	)

	measure(
		"delete 1M entities (+flush)",
		3,
		proc() {
			s := (^State)(context.user_ptr)
			for id in odon.world_entities(s.w) {
				odon.del_entity(s.w, odon.Entity(id))
			}
			odon.world_release_del_buffer(s.w)
		},
		proc() {
			s := (^State)(context.user_ptr)
			populate(s.w)
		},
	)

	fmt.printf("  (sink: %.1f)\n", s.sink)
}
