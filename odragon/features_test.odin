package odragon

import "core:mem"
import "core:testing"

@(test)
test_query_cache_hits :: proc(t: ^testing.T) {
	w := world_create()
	defer world_destroy(w)

	for i in 0 ..< 10 {
		e := new_entity(w)
		add(w, e, Pos)
		add(w, e, Vel)
	}

	mb := mask_new(w)
	mask_inc(&mb, Pos)
	m := mask_build(&mb)
	defer mask_destroy(&m)

	r1 := query_cached(w, &m)
	testing.expect(t, len(r1) == 10)
	r2 := query_cached(w, &m)
	testing.expect(t, len(r2) == 10)
	testing.expect(t, &r1[0] == &r2[0], "unchanged world must reuse the cached slice")

	// An unrelated pool changing must not invalidate the Pos query
	extra := new_entity(w)
	add(w, extra, Vel)
	r3 := query_cached(w, &m)
	testing.expect(t, len(r3) == 10)
	testing.expect(t, &r1[0] == &r3[0], "unrelated pool change must keep the cache")

	// A Pos add must invalidate
	e2 := new_entity(w)
	add(w, e2, Pos)
	r4 := query_cached(w, &m)
	testing.expect(t, len(r4) == 11)

	// Deletion must invalidate too
	del_entity(w, e2)
	r5 := query_cached(w, &m)
	testing.expect(t, len(r5) == 10)
}

Config :: struct {
	dt: f32,
}

@(test)
test_world_components :: proc(t: ^testing.T) {
	w := world_create()
	defer world_destroy(w)

	testing.expect(t, !world_has(w, Config))
	cfg := world_get(w, Config)
	testing.expect(t, world_has(w, Config))
	cfg.dt = 0.16
	testing.expect(t, world_get(w, Config).dt == 0.16)
	testing.expect(t, world_get(w, Config) == cfg, "singleton must be stable")

	world_del(w, Config)
	testing.expect(t, !world_has(w, Config))
}

@(test)
test_group_set_ops :: proc(t: ^testing.T) {
	w := world_create()
	defer world_destroy(w)

	es: [6]Entity
	for i in 0 ..< 6 {
		es[i] = new_entity(w)
		add(w, es[i], Pos)
	}

	a := group_create(w)
	defer group_destroy(a)
	b := group_create(w)
	defer group_destroy(b)

	// a = {0,1,2,3}, b = {2,3,4,5}
	for i in 0 ..< 4 { group_add(a, es[i]) }
	for i in 2 ..< 6 { group_add(b, es[i]) }

	testing.expect(t, group_count(a) == 4)
	testing.expect(t, group_has(a, es[0]) && group_has(a, es[3]))
	testing.expect(t, !group_has(a, es[4]))

	group_remove(a, es[0])
	testing.expect(t, !group_has(a, es[0]) && group_count(a) == 3)
	group_add(a, es[0])

	u := group_create(w)
	defer group_destroy(u)
	group_union_with(u, a)
	group_union_with(u, b)
	testing.expect(t, group_count(u) == 6)

	x := group_create(w)
	defer group_destroy(x)
	group_union_with(x, a)
	group_intersect_with(x, b)
	testing.expect(t, group_count(x) == 2)
	testing.expect(t, group_has(x, es[2]) && group_has(x, es[3]))

	group_except_with(a, b)
	testing.expect(t, group_count(a) == 2)
	testing.expect(t, group_has(a, es[0]) && group_has(a, es[1]))

	// prune drops dead entities
	del_entity(w, es[0])
	group_prune(a, w)
	testing.expect(t, group_count(a) == 1)
}

@(test)
test_pool_listeners :: proc(t: ^testing.T) {
	w := world_create()
	defer world_destroy(w)

	counts: [2]i32 // [adds, dels]
	p := get_pool(w, Pos)
	pool_add_listener(
		p,
		on_add = proc(data: rawptr, e: Entity) {
			(^[2]i32)(data)[0] += 1
		},
		on_del = proc(data: rawptr, e: Entity) {
			(^[2]i32)(data)[1] += 1
		},
		data = &counts,
	)

	e := new_entity(w)
	add(w, e, Pos)
	add(w, e, Vel)
	del(w, e, Pos)
	testing.expect(t, counts[0] == 1 && counts[1] == 1)
}

@(test)
test_copy_entity :: proc(t: ^testing.T) {
	w := world_create()
	defer world_destroy(w)

	src := new_entity(w)
	add(w, src, Pos)^ = {3, 4}
	add(w, src, Vel)^ = {1, 1}

	dst := new_entity(w)
	add(w, dst, Dead) // keep dst alive

	copy_entity(w, dst, src)
	testing.expect(t, has(w, dst, Pos) && has(w, dst, Vel))
	testing.expect(t, get(w, dst, Pos).x == 3)
	testing.expect(t, has(w, dst, Dead), "unrelated components untouched")
	testing.expect(t, w.comp_counts[i32(dst)] == 3)
}

@(test)
test_mask_apply :: proc(t: ^testing.T) {
	w := world_create()
	defer world_destroy(w)

	e := new_entity(w)
	add(w, e, Vel)

	mb := mask_new(w)
	mask_inc(&mb, Pos)
	mask_exc(&mb, Vel)
	m := mask_build(&mb)
	defer mask_destroy(&m)

	mask_apply(w, e, &m)
	testing.expect(t, has(w, e, Pos))
	testing.expect(t, !has(w, e, Vel), "exc must remove")
}

@(test)
test_typed_queries :: proc(t: ^testing.T) {
	w := world_create()
	defer world_destroy(w)

	for i in 0 ..< 10 {
		e := new_entity(w)
		add(w, e, Pos)^ = {f32(i), 0}
		add(w, e, Vel)^ = {1, 1}
	}
	for i in 0 ..< 5 {
		e := new_entity(w)
		add(w, e, Pos)^ = {100, 0}
	}

	q2 := query2(w, Pos, Vel)
	n := 0
	e: Entity
	pos: ^Pos
	vel: ^Vel
	for query_next(&q2, &e, &pos, &vel) {
		n += 1
		testing.expect(t, vel.x == 1)
		pos.x += vel.x
	}
	testing.expect(t, n == 10)

	Dead2 :: struct {} // ensure a third distinct type
	_ = Dead2

	q1 := query1(w, Vel)
	n1 := 0
	v1: ^Vel
	for query_next(&q1, &e, &v1) {
		n1 += 1
	}
	testing.expect(t, n1 == 10)

	// query3 with a tag that nobody has: no matches
	q3 := query3(w, Pos, Vel, Dead)
	n3 := 0
	p3: ^Pos
	v3: ^Vel
	d3: ^Dead
	for query_next(&q3, &e, &p3, &v3, &d3) {
		n3 += 1
	}
	testing.expect(t, n3 == 0)
}

@(test)
test_copy_entity_cross :: proc(t: ^testing.T) {
	src_w := world_create()
	defer world_destroy(src_w)
	dst_w := world_create()
	defer world_destroy(dst_w)

	// make both worlds aware of both component types
	get_pool(src_w, Pos)
	get_pool(src_w, Vel)
	get_pool(dst_w, Pos)
	get_pool(dst_w, Vel)

	src := new_entity(src_w)
	add(src_w, src, Pos)^ = {9, 8}
	add(src_w, src, Vel)^ = {2, 2}

	dst := new_entity(dst_w)
	add(dst_w, dst, Dead)

	copy_entity_cross(dst_w, dst, src_w, src)
	testing.expect(t, has(dst_w, dst, Pos) && has(dst_w, dst, Vel))
	testing.expect(t, get(dst_w, dst, Pos).x == 9)
	// source world untouched
	testing.expect(t, has(src_w, src, Pos))
}

@(test)
test_new_entity_with :: proc(t: ^testing.T) {
	w := world_create()
	defer world_destroy(w)

	mb := mask_new(w)
	mask_inc(&mb, Pos)
	mask_inc(&mb, Vel)
	m := mask_build(&mb)
	defer mask_destroy(&m)

	e := new_entity_with(w, &m)
	testing.expect(t, has(w, e, Pos) && has(w, e, Vel))
	testing.expect(t, w.comp_counts[i32(e)] == 2)
}

@(test)
test_pool_pointer_consistency :: proc(t: ^testing.T) {
	w := world_create()
	defer world_destroy(w)

	// systems cache pool pointers and use them directly; the world bitmap
	// must stay in sync (queries, has(), auto-delete all observe it)
	p := get_pool(w, Pos)
	e := new_entity(w)
	pool_add(p, e)^ = {42, 0}
	testing.expect(t, has(w, e, Pos))
	testing.expect(t, w.comp_counts[i32(e)] == 1)

	mb := mask_new(w)
	mask_inc(&mb, Pos)
	m := mask_build(&mb)
	defer mask_destroy(&m)
	testing.expect(t, len(query_all(w, &m, context.temp_allocator)) == 1)

	pool_del(p, e)
	testing.expect(t, !has(w, e, Pos))
	testing.expect(t, !is_alive(w, e), "last component removed via pool must auto-delete")
}

@(test)
test_no_leaks_extended :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)

	{
		w := world_create()
		world_get(w, Config)^ = Config{dt = 0.1}

		p := get_pool(w, Vel)
		pool_add_listener(p, on_add = proc(data: rawptr, e: Entity) {})

		for i in 0 ..< 100 {
			e := new_entity(w)
			add(w, e, Pos)
			if i % 2 == 0 { add(w, e, Vel) }
		}

		mb := mask_new(w)
		mask_inc(&mb, Pos)
		m := mask_build(&mb)
		for i in 0 ..< 5 {
			r := query_cached(w, &m)
			_ = r
		}
		mask_destroy(&m)

		g := group_create(w)
		for e in world_entities(w) { group_add(g, Entity(e)) }
		group_destroy(g)

		q := query2(w, Pos, Vel)
		e: Entity
		p2: ^Pos
		v2: ^Vel
		for query_next(&q, &e, &p2, &v2) {}

		world_del(w, Config)
		world_destroy(w)
	}

	for _, leak in track.allocation_map {
		testing.fail(t)
		_ = leak
		break
	}
	for bf in track.bad_free_array {
		testing.fail(t)
		_ = bf
		break
	}
}
