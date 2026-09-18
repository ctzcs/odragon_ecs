package odragon

import "core:mem"
import "core:testing"

@(test)
test_world_registry_and_handle_resolve :: proc(t: ^testing.T) {
	w1 := world_create()
	w2 := world_create()
	defer world_destroy(w1)
	defer world_destroy(w2)

	testing.expect(t, world_by_id(w1.id) == w1)
	testing.expect(t, world_by_id(w2.id) == w2)

	e := new_entity(w1)
	add(w1, e, Pos)
	h := handle(w1, e)

	rw, re, alive := resolve_handle(h)
	testing.expect(t, rw == w1 && re == e && alive)

	// after deletion the same handle no longer resolves as alive
	del_entity(w1, e)
	_, _, alive2 := resolve_handle(h)
	testing.expect(t, !alive2)
}

Res :: struct {
	buf: [dynamic]u8,
}

@(test)
test_component_lifecycle :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)

	{
		w := world_create()
		p := get_pool(w, Res)
		pool_set_lifecycle(
			p,
			on_init = proc(data: rawptr, item: ^Res) {
				item.buf = make([dynamic]u8, 0, 16, context.allocator)
			},
			on_del = proc(data: rawptr, item: ^Res) {
				delete(item.buf)
			},
		)

		// direct component removal
		e1 := new_entity(w)
		add(w, e1, Pos)
		add(w, e1, Res)
		del(w, e1, Res)

		// entity deletion must run on_del too (via the flush)
		e2 := new_entity(w)
		add(w, e2, Pos)
		add(w, e2, Res)
		del_entity(w, e2)
		world_release_del_buffer(w)

		world_destroy(w)
	}

	for _, leak in track.allocation_map {
		testing.fail(t)
		_ = leak
		break
	}
}

@(test)
test_group_auto_prune_on_flush :: proc(t: ^testing.T) {
	w := world_create()
	defer world_destroy(w)

	g := group_create(w)
	defer group_destroy(g)

	es: [4]Entity
	for i in 0 ..< 4 {
		es[i] = new_entity(w)
		add(w, es[i], Pos)
		group_add(g, es[i])
	}
	testing.expect(t, group_count(g) == 4)

	del_entity(w, es[1])
	del_entity(w, es[3])
	world_release_del_buffer(w)

	testing.expect(t, group_count(g) == 2)
	testing.expect(t, group_has(g, es[0]) && group_has(g, es[2]))
	testing.expect(t, !group_has(g, es[1]) && !group_has(g, es[3]))
}

@(test)
test_has_uses_bitmap :: proc(t: ^testing.T) {
	w := world_create()
	defer world_destroy(w)

	e := new_entity(w)
	add(w, e, Pos)
	testing.expect(t, has(w, e, Pos))
	testing.expect(t, !has(w, e, Vel))
	// out-of-range entity id must not crash the bitmap read
	testing.expect(t, !has(w, Entity(1 << 20), Pos))
	// tag components too
	add(w, e, Dead)
	testing.expect(t, has(w, e, Dead))
}
