package odragon

import "core:testing"

Frozen :: struct {}
Marked :: struct {}

@(test)
test_tag_pool_basics :: proc(t: ^testing.T) {
	w := world_create()
	defer world_destroy(w)

	e := new_entity(w)
	add(w, e, Pos) // keep alive
	add(w, e, Frozen)

	testing.expect(t, has(w, e, Frozen))
	testing.expect(t, w.pools[component_id(Frozen)].is_tag, "zero-size component must route to tag pool")

	// get/try_get on a tag return nil pointer but report presence
	testing.expect(t, get(w, e, Frozen) == nil)
	_, ok := try_get(w, e, Frozen)
	testing.expect(t, ok)

	tp := get_tag_pool(w, Frozen)
	tag_pool_toggle(tp, e)
	testing.expect(t, !has(w, e, Frozen))
	tag_pool_toggle(tp, e)
	testing.expect(t, has(w, e, Frozen))
	tag_pool_set(tp, e, false)
	testing.expect(t, !has(w, e, Frozen))
	tag_pool_set(tp, e, true)
	testing.expect(t, has(w, e, Frozen))

	del(w, e, Frozen)
	testing.expect(t, !has(w, e, Frozen))
	testing.expect(t, is_alive(w, e), "Pos remains, entity alive")
}

@(test)
test_tag_pool_iteration_and_query :: proc(t: ^testing.T) {
	w := world_create()
	defer world_destroy(w)

	// 10 with Pos, 4 of them Frozen
	for i in 0 ..< 10 {
		e := new_entity(w)
		add(w, e, Pos)
		if i < 4 {
			add(w, e, Frozen)
		}
	}

	// query1 directly on a tag: pointer out is nil
	q := query1(w, Frozen)
	n := 0
	e: Entity
	tag: ^Frozen
	for query_next(&q, &e, &tag) {
		n += 1
		testing.expect(t, tag == nil)
		testing.expect(t, has(w, e, Pos))
	}
	testing.expect(t, n == 4)

	// mask exc on a tag
	mb := mask_new(w)
	mask_inc(&mb, Pos)
	mask_exc(&mb, Frozen)
	m := mask_build(&mb)
	defer mask_destroy(&m)
	testing.expect(t, len(query_all(w, &m, context.temp_allocator)) == 6)

	// query2 mixing data + tag
	q2 := query2(w, Pos, Frozen)
	n2 := 0
	p2: ^Pos
	t2: ^Frozen
	for query_next(&q2, &e, &p2, &t2) {
		n2 += 1
		testing.expect(t, p2 != nil && t2 == nil)
	}
	testing.expect(t, n2 == 4)
}

@(test)
test_tag_copy_and_listener :: proc(t: ^testing.T) {
	w := world_create()
	defer world_destroy(w)

	counts: [2]i32 // [adds, dels]
	tp := get_tag_pool(w, Marked)
	append(
		&tp.listeners,
		Pool_Listener {
			on_add = proc(data: rawptr, e: Entity) { (^[2]i32)(data)[0] += 1 },
			on_del = proc(data: rawptr, e: Entity) { (^[2]i32)(data)[1] += 1 },
			data = &counts,
		},
	)

	src := new_entity(w)
	add(w, src, Pos)
	add(w, src, Marked)
	testing.expect(t, counts[0] == 1)

	dst := new_entity(w)
	add(w, dst, Pos)
	copy_entity(w, dst, src)
	testing.expect(t, has(w, dst, Marked), "tag must be copied")
	testing.expect(t, counts[0] == 2)

	del(w, dst, Marked)
	testing.expect(t, counts[1] == 1)
	testing.expect(t, !has(w, dst, Marked))
}

@(test)
test_tag_pool_swap_remove_iteration :: proc(t: ^testing.T) {
	w := world_create()
	defer world_destroy(w)

	es: [8]Entity
	for i in 0 ..< 8 {
		es[i] = new_entity(w)
		add(w, es[i], Pos)
		add(w, es[i], Frozen)
	}

	// delete a few tags, then iterate: dense list must stay compact
	del(w, es[1], Frozen)
	del(w, es[5], Frozen)
	del(w, es[2], Frozen)

	tp := get_tag_pool(w, Frozen)
	ents := tag_pool_entities(tp)
	testing.expect(t, len(ents) == 5)
	for id in ents {
		testing.expect(t, has(w, Entity(id), Frozen))
	}
	testing.expect(t, tp.count == 5)
}
