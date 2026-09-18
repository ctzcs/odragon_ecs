package odragon

import "core:mem"
import "core:slice"

// Mask: inc/exc/any component constraints, stored both as flat ID lists and
// pre-aggregated 32-bit bitmap chunks. Because component IDs are global and
// single-level, the chunks are world-independent (DragonECS's EcsStaticMask /
// EcsMask pair collapses into this single type).

Mask_Chunk :: struct {
	index: i32,
	bits:  i32,
}

Mask :: struct {
	inc:         []i32,
	exc:         []i32,
	any:         []i32,
	inc_chunks:  []Mask_Chunk,
	exc_chunks:  []Mask_Chunk,
	any_chunks:  []Mask_Chunk,
	allocator:   mem.Allocator,
}

Mask_Builder :: struct {
	world:     ^World,
	inc:       [dynamic]i32,
	exc:       [dynamic]i32,
	any:       [dynamic]i32,
	allocator: mem.Allocator,
}

mask_new :: proc(w: ^World, allocator := context.allocator) -> Mask_Builder {
	return Mask_Builder {
		world = w,
		inc = make([dynamic]i32, 0, 8, allocator),
		exc = make([dynamic]i32, 0, 8, allocator),
		any = make([dynamic]i32, 0, 8, allocator),
		allocator = allocator,
	}
}

// Generic builder variants also register T's pool in the builder's world,
// mirroring DragonECS's EcsMask.New(world).Inc<T>().

mask_inc :: proc(b: ^Mask_Builder, $T: typeid) -> ^Mask_Builder {
	ensure_pool(b.world, T)
	append(&b.inc, component_id(T))
	return b
}

mask_exc :: proc(b: ^Mask_Builder, $T: typeid) -> ^Mask_Builder {
	ensure_pool(b.world, T)
	append(&b.exc, component_id(T))
	return b
}

mask_any :: proc(b: ^Mask_Builder, $T: typeid) -> ^Mask_Builder {
	ensure_pool(b.world, T)
	append(&b.any, component_id(T))
	return b
}

mask_inc_id :: proc(b: ^Mask_Builder, cid: i32) -> ^Mask_Builder {
	append(&b.inc, cid)
	return b
}

mask_exc_id :: proc(b: ^Mask_Builder, cid: i32) -> ^Mask_Builder {
	append(&b.exc, cid)
	return b
}

mask_any_id :: proc(b: ^Mask_Builder, cid: i32) -> ^Mask_Builder {
	append(&b.any, cid)
	return b
}

@(private)
ids_to_chunks :: proc(ids: []i32, allocator: mem.Allocator) -> []Mask_Chunk {
	chunks := make([dynamic]Mask_Chunk, 0, 4, allocator)
	for id in ids {
		ci := id >> 5
		if len(chunks) > 0 && chunks[len(chunks) - 1].index == ci {
			chunks[len(chunks) - 1].bits |= 1 << u32(id & 31)
		} else {
			append(&chunks, Mask_Chunk{index = ci, bits = 1 << u32(id & 31)})
		}
	}
	return chunks[:]
}

@(private)
sorted_ids :: proc(ids: [dynamic]i32, allocator: mem.Allocator) -> []i32 {
	out := make([]i32, len(ids), allocator)
	copy(out, ids[:])
	slice.sort(out)
	return out
}

// Builds an immutable Mask from the builder (sorted + chunk-aggregated) and
// releases the builder's scratch arrays.
mask_build :: proc(b: ^Mask_Builder, allocator := context.allocator) -> Mask {
	m := Mask {
		allocator = allocator,
	}
	m.inc = sorted_ids(b.inc, allocator)
	m.exc = sorted_ids(b.exc, allocator)
	m.any = sorted_ids(b.any, allocator)
	m.inc_chunks = ids_to_chunks(m.inc, allocator)
	m.exc_chunks = ids_to_chunks(m.exc, allocator)
	m.any_chunks = ids_to_chunks(m.any, allocator)
	delete(b.inc)
	delete(b.exc)
	delete(b.any)
	return m
}

mask_destroy :: proc(m: ^Mask) {
	delete(m.inc, m.allocator)
	delete(m.exc, m.allocator)
	delete(m.any, m.allocator)
	delete(m.inc_chunks, m.allocator)
	delete(m.exc_chunks, m.allocator)
	delete(m.any_chunks, m.allocator)
	m^ = {}
}

// Applies the mask to an entity as a template: adds empty components for inc
// constraints, removes them for exc constraints. Basis of DragonECS's
// ITemplateNode mechanism. Pools not yet registered in this world are skipped.
mask_apply :: proc(w: ^World, e: Entity, m: ^Mask) {
	assert(is_alive(w, e), "mask_apply: entity is not alive")
	id := i32(e)
	for cid in m.inc {
		if int(cid) >= len(w.pools) || w.pools[cid].data == nil {
			continue
		}
		slot := &w.pools[cid]
		if !slot.has(slot.data, id) {
			slot.add_empty(slot.data, id)
		}
	}
	for cid in m.exc {
		if int(cid) >= len(w.pools) || w.pools[cid].data == nil {
			continue
		}
		slot := &w.pools[cid]
		if slot.has(slot.data, id) {
			slot.del(slot.data, id)
		}
	}
}

// Bitmap match against an entity's mask row: all inc bits set, no exc bits
// set, and (if any constraints exist) at least one any bit set.
@(private)
mask_matches :: proc "contextless" (w: ^World, m: ^Mask, e: i32) -> bool {
	base := e << w.mask_shift
	for c in m.inc_chunks {
		if w.masks[base + c.index] & c.bits != c.bits {
			return false
		}
	}
	for c in m.exc_chunks {
		if w.masks[base + c.index] & c.bits != 0 {
			return false
		}
	}
	if len(m.any_chunks) > 0 {
		found := false
		for c in m.any_chunks {
			if w.masks[base + c.index] & c.bits != 0 {
				found = true
				break
			}
		}
		if !found {
			return false
		}
	}
	return true
}
