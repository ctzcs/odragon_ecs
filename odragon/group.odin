package odragon

import "core:mem"

// Group: a reusable sparse-set collection of entity ids (port of DragonECS's
// EcsGroup, including its paged sparse storage).
//
//	dense[1..] = entity ids, dense[0] unused
//	pages[e >> 6].slots[e & 63] = dense index (0 = absent); nil page = all absent
//
// The sparse side is paged (64 entities per page) instead of one flat array
// per group: a flat array costs 4 bytes x world capacity per group, which
// adds up when many long-lived groups exist in a large world. Each page
// tracks its nonzero-slot count and is freed the moment it empties, so memory
// stays proportional to the occupied id regions.
// (DragonECS shares a null page + XOR checksums to detect empty pages; the
// explicit counter achieves the same with O(1) exactness.)

GROUP_PAGE_SHIFT :: 6
GROUP_PAGE_SIZE :: 1 << GROUP_PAGE_SHIFT // 64

Group_Page :: struct {
	slots: [GROUP_PAGE_SIZE]i32,
	count: i32, // nonzero slots; the page is freed when this hits 0
}

Group :: struct {
	world:     ^World,
	dense:     [dynamic]i32,
	pages:     [dynamic]^Group_Page,
	allocator: mem.Allocator,
}

// Groups register with their world and are pruned automatically when buffered
// entities are released (EcsGroup parity). Destroy groups before their world.
group_create :: proc(w: ^World, allocator := context.allocator) -> ^Group {
	g := new(Group, allocator)
	g.world = w
	g.allocator = allocator
	g.dense = make([dynamic]i32, 0, 64, allocator)
	append(&g.dense, 0)
	g.pages = make([dynamic]^Group_Page, 0, (w.capacity >> GROUP_PAGE_SHIFT) + 1, allocator)
	world_register_group(w, g)
	return g
}

group_destroy :: proc(g: ^Group) {
	world_unregister_group(g.world, g)
	group_clear(g)
	delete(g.dense)
	delete(g.pages)
	free(g, g.allocator)
}

@(private)
group_page :: proc "contextless" (g: ^Group, e: i32) -> ^Group_Page {
	pi := e >> GROUP_PAGE_SHIFT
	if pi >= i32(len(g.pages)) {
		return nil
	}
	return g.pages[pi]
}

@(private)
group_page_or_create :: proc(g: ^Group, e: i32) -> ^Group_Page {
	pi := e >> GROUP_PAGE_SHIFT
	for i32(len(g.pages)) <= pi {
		append(&g.pages, nil)
	}
	if g.pages[pi] == nil {
		g.pages[pi] = new(Group_Page, g.allocator) // zero-initialized
	}
	return g.pages[pi]
}

group_add :: proc(g: ^Group, e: Entity) {
	id := i32(e)
	page := group_page_or_create(g, id)
	si := id & (GROUP_PAGE_SIZE - 1)
	if page.slots[si] != 0 {
		return
	}
	append(&g.dense, id)
	page.slots[si] = i32(len(g.dense)) - 1
	page.count += 1
}

group_remove :: proc(g: ^Group, e: Entity) {
	id := i32(e)
	page := group_page(g, id)
	if page == nil {
		return
	}
	si := id & (GROUP_PAGE_SIZE - 1)
	di := page.slots[si]
	if di == 0 {
		return
	}
	last := i32(len(g.dense)) - 1
	last_id := g.dense[last]
	g.dense[di] = last_id
	group_page(g, last_id).slots[last_id & (GROUP_PAGE_SIZE - 1)] = di
	pop(&g.dense)
	page.slots[si] = 0
	page.count -= 1
	if page.count == 0 {
		pi := id >> GROUP_PAGE_SHIFT
		free(page, g.allocator)
		g.pages[pi] = nil
	}
}

group_has :: proc "contextless" (g: ^Group, e: Entity) -> bool {
	id := i32(e)
	page := group_page(g, id)
	return page != nil && page.slots[id & (GROUP_PAGE_SIZE - 1)] != 0
}

group_count :: proc "contextless" (g: ^Group) -> i32 {
	return i32(len(g.dense)) - 1
}

group_clear :: proc(g: ^Group) {
	for &p in g.pages {
		if p != nil {
			free(p, g.allocator)
			p = nil
		}
	}
	clear(&g.dense)
	append(&g.dense, 0)
}

// All entity ids in the group (unordered).
group_entities :: proc "contextless" (g: ^Group) -> []i32 {
	return g.dense[1:]
}

group_copy_from :: proc(g: ^Group, entities: []Entity) {
	group_clear(g)
	for e in entities {
		group_add(g, e)
	}
}

// dst = dst ∪ src
group_union_with :: proc(dst: ^Group, src: ^Group) {
	for id in group_entities(src) {
		group_add(dst, Entity(id))
	}
}

// dst = dst ∩ src
group_intersect_with :: proc(dst: ^Group, src: ^Group) {
	for i := len(dst.dense) - 1; i >= 1; i -= 1 {
		if !group_has(src, Entity(dst.dense[i])) {
			group_remove(dst, Entity(dst.dense[i]))
		}
	}
}

// dst = dst ∖ src
group_except_with :: proc(dst: ^Group, src: ^Group) {
	for id in group_entities(src) {
		group_remove(dst, Entity(id))
	}
}

// Drops entities that are no longer alive in the world (e.g. after deletions).
group_prune :: proc(g: ^Group, w: ^World) {
	for i := len(g.dense) - 1; i >= 1; i -= 1 {
		if !world_alive_id(w, g.dense[i]) {
			group_remove(g, Entity(g.dense[i]))
		}
	}
}
