package odragon

import "core:mem"

// Group: a reusable sparse-set collection of entity ids (port of DragonECS's
// EcsGroup; uses a flat sparse array instead of paged unmanaged memory —
// 4 bytes per world-capacity slot).
//
//	dense[1..] = entity ids, dense[0] unused
//	sparse[e]  = index into dense (0 = absent)

Group :: struct {
	dense:     [dynamic]i32,
	sparse:    [dynamic]i32,
	allocator: mem.Allocator,
}

group_create :: proc(w: ^World, allocator := context.allocator) -> ^Group {
	g := new(Group, allocator)
	g.allocator = allocator
	g.dense = make([dynamic]i32, 0, 64, allocator)
	append(&g.dense, 0)
	g.sparse = make([dynamic]i32, int(w.capacity), int(w.capacity), allocator)
	return g
}

group_destroy :: proc(g: ^Group) {
	delete(g.dense)
	delete(g.sparse)
	free(g, g.allocator)
}

@(private)
group_ensure :: proc(g: ^Group, e: i32) {
	for i32(len(g.sparse)) <= e {
		append(&g.sparse, 0)
	}
}

group_add :: proc(g: ^Group, e: Entity) {
	id := i32(e)
	group_ensure(g, id)
	if g.sparse[id] != 0 {
		return
	}
	append(&g.dense, id)
	g.sparse[id] = i32(len(g.dense)) - 1
}

group_remove :: proc(g: ^Group, e: Entity) {
	id := i32(e)
	if id >= i32(len(g.sparse)) {
		return
	}
	di := g.sparse[id]
	if di == 0 {
		return
	}
	last := i32(len(g.dense)) - 1
	last_id := g.dense[last]
	g.dense[di] = last_id
	g.sparse[last_id] = di
	pop(&g.dense)
	g.sparse[id] = 0
}

group_has :: proc "contextless" (g: ^Group, e: Entity) -> bool {
	id := i32(e)
	return id < i32(len(g.sparse)) && g.sparse[id] != 0
}

group_count :: proc "contextless" (g: ^Group) -> i32 {
	return i32(len(g.dense)) - 1
}

group_clear :: proc(g: ^Group) {
	for id in g.dense[1:] {
		g.sparse[id] = 0
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
