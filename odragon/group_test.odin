package odragon

import "core:testing"

@(test)
test_group_paging :: proc(t: ^testing.T) {
	w := world_create()
	defer world_destroy(w)

	// 200 entities -> ids 1..200 -> pages 0..3 (64 slots per page)
	es: [200]Entity
	for i in 0 ..< 200 {
		es[i] = new_entity(w)
		add(w, es[i], Pos)
	}

	g := group_create(w)
	defer group_destroy(g)
	for e in es {
		group_add(g, e)
	}
	testing.expect(t, group_count(g) == 200)

	non_nil := 0
	for p in g.pages {
		if p != nil {
			non_nil += 1
		}
	}
	testing.expect(t, non_nil == 4, "ids 1..200 must occupy exactly 4 pages")

	// empty page 2 (ids 128..191) completely: the page must be freed
	for id in 128 ..< 192 {
		group_remove(g, Entity(id))
	}
	testing.expect(t, g.pages[2] == nil, "emptied page must be freed")
	testing.expect(t, group_count(g) == 136)
	testing.expect(t, group_has(g, es[0]) && group_has(g, es[199]))
	testing.expect(t, !group_has(g, es[128]))

	// clear frees all remaining pages
	group_clear(g)
	for p in g.pages {
		testing.expect(t, p == nil)
	}
	testing.expect(t, group_count(g) == 0)

	// reuse after clear still works
	group_add(g, es[7])
	testing.expect(t, group_has(g, es[7]) && group_count(g) == 1)
}
