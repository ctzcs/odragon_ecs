	package odragon

import "base:runtime"
import "core:mem"
import "core:sync"

SLEEP_BIT :: 0x8000
GEN_MAX :: 0x7fff

MASK_CHUNK_SIZE :: 32

// World: entity container + pool table + per-entity component bitmaps.
// Port of DragonECS's EcsWorld, with single-level component IDs:
// a global component ID is directly the pool-table index and bitmap bit index.
World :: struct {
	id:          i16,
	allocator:   mem.Allocator,
	dispenser:   Id_Dispenser,
	capacity:    i32,
	gens:        [dynamic]u16, // generation per entity; high bit = sleep marker
	comp_counts: [dynamic]i32,
	masks:       [dynamic]i32, // per-entity bitmap; row of entity e starts at e << mask_shift
	mask_shift:  u32, // log2(chunks per entity); chunks = 1 << shift (min 2 => 64 components)
	pools:       [dynamic]Any_Pool, // indexed by global component ID, data == nil = not used here
	del_buffer:  [dynamic]i32, // two-phase deletion: marked entities pending release
	version:     u32, // bumped on any structural change (for query caching)
	alive:       i32,
	query_cache: map[u64]^Cached_Query, // mask hash -> cached query results
	world_comps: map[typeid]rawptr, // world singleton components (EcsWorld.Get<T>)
	groups:      [dynamic]^Group, // registered groups auto-pruned on flush
}

@(private)
_next_world_id: i16 = 1

// Global world registry: lets a bare Entity_Long be resolved back to its
// world (port of DragonECS's static _worlds table + entlong world lookup).
@(private)
_worlds_by_id: map[i16]^World

@(private)
_worlds_mu: sync.Mutex

@(private, init)
_worlds_init :: proc "contextless" () {
	context = runtime.default_context()
	_worlds_by_id = make(map[i16]^World, 16, runtime.heap_allocator())
}

world_by_id :: proc(id: i16) -> ^World {
	sync.lock(&_worlds_mu)
	defer sync.unlock(&_worlds_mu)
	return _worlds_by_id[id]
}

// Resolves a long handle to its world + entity, checking liveness.
resolve_handle :: proc(h: Entity_Long) -> (w: ^World, e: Entity, alive: bool) {
	w = world_by_id(i16(h.world_id))
	if w == nil {
		return nil, NULL_ENTITY, false
	}
	return w, entity_of(h), is_alive_handle(w, h)
}

@(private)
next_pow2_i32 :: proc "contextless" (x: i32) -> i32 {
	v := i32(1)
	for v < x {
		v *= 2
	}
	return v
}

// initial_capacity pre-sizes entity storage (gens/counts/bitmap rows and pool
// mappings) — worth it for mass spawning; pools can additionally be
// pre-reserved with pool_reserve.
world_create :: proc(allocator := context.allocator, initial_capacity: i32 = 64) -> ^World {
	cap := max(64, next_pow2_i32(initial_capacity))
	w := new(World, allocator)
	w.allocator = allocator
	sync.lock(&_worlds_mu)
	w.id = _next_world_id
	_next_world_id += 1
	_worlds_by_id[w.id] = w
	sync.unlock(&_worlds_mu)
	dispenser_init(&w.dispenser, cap, allocator)
	w.capacity = cap
	w.gens = make([dynamic]u16, int(cap), int(cap), allocator)
	w.comp_counts = make([dynamic]i32, int(cap), int(cap), allocator)
	w.mask_shift = 1
	w.masks = make([dynamic]i32, int(cap << 1), int(cap << 1), allocator)
	w.pools = make([dynamic]Any_Pool, 64, 64, allocator)
	w.del_buffer = make([dynamic]i32, 0, 64, allocator)
	w.query_cache = make(map[u64]^Cached_Query, 32, allocator)
	w.world_comps = make(map[typeid]rawptr, 16, allocator)
	w.groups = make([dynamic]^Group, 0, 8, allocator)
	return w
}

// NOTE: destroy groups before their world. world_destroy does not free
// user-owned groups, it only drops the registration list.
world_destroy :: proc(w: ^World) {
	world_release_del_buffer(w)
	for &slot in &w.pools {
		if slot.data != nil {
			slot.destroy(slot.data)
			slot.data = nil
		}
	}
	for _, entry in w.query_cache {
		cached_query_free(entry, w.allocator)
	}
	delete(w.query_cache)
	for _, v in w.world_comps {
		free(v, w.allocator)
	}
	delete(w.world_comps)
	delete(w.groups)
	sync.lock(&_worlds_mu)
	delete_key(&_worlds_by_id, w.id)
	sync.unlock(&_worlds_mu)
	dispenser_destroy(&w.dispenser)
	delete(w.gens)
	delete(w.comp_counts)
	delete(w.masks)
	delete(w.pools)
	delete(w.del_buffer)
	free(w, w.allocator)
}

// ---------------------------------------------------------------------------
// Entities
// ---------------------------------------------------------------------------

new_entity :: proc(w: ^World) -> Entity {
	id := dispenser_acquire(&w.dispenser)
	if id >= w.capacity {
		world_upsize(w, id + 1)
	}
	gen := w.gens[id]
	if gen & SLEEP_BIT != 0 {
		gen = (gen & GEN_MAX) + 1
		if gen > GEN_MAX {
			gen = 1
		}
	} else {
		gen = 1
	}
	w.gens[id] = gen
	w.comp_counts[id] = 0
	w.alive += 1
	w.version += 1
	return Entity(id)
}

// Marks the entity dead immediately (sleep bit) and buffers it for release.
// Pools are cleaned and the id recycled on the next world_release_del_buffer.
del_entity :: proc(w: ^World, e: Entity) {
	id := i32(e)
	if !is_alive(w, e) {
		return
	}
	w.gens[id] |= SLEEP_BIT
	append(&w.del_buffer, id)
	w.alive -= 1
	w.version += 1
}

// Actually recycles buffered entities: removes their components from all
// pools, clears their bitmap row, and returns ids to the dispenser.
// Called automatically by query() and world_entities().
world_release_del_buffer :: proc(w: ^World) {
	if len(w.del_buffer) == 0 {
		return
	}
	for id in w.del_buffer {
		for slot in &w.pools {
			if slot.data != nil && slot.has(slot.data, id) {
				slot.del(slot.data, id)
			}
		}
		row := id << w.mask_shift
		for i in 0 ..< mask_chunks(w) {
			w.masks[row + i] = 0
		}
		w.comp_counts[id] = 0
		dispenser_release(&w.dispenser, id)
	}
	// registered groups drop released entities automatically (EcsGroup parity)
	for g in w.groups {
		for id in w.del_buffer {
			group_remove(g, Entity(id))
		}
	}
	clear(&w.del_buffer)
	w.version += 1
}

world_register_group :: proc(w: ^World, g: ^Group) {
	for r in w.groups {
		if r == g {
			return
		}
	}
	append(&w.groups, g)
}

world_unregister_group :: proc(w: ^World, g: ^Group) {
	for r, i in w.groups {
		if r == g {
			unordered_remove(&w.groups, i)
			return
		}
	}
}

@(private)
mask_chunks :: proc "contextless" (w: ^World) -> i32 {
	return i32(1) << w.mask_shift
}

is_alive :: proc "contextless" (w: ^World, e: Entity) -> bool {
	id := i32(e)
	return id > 0 && id < w.capacity && w.gens[id] != 0 && w.gens[id] & SLEEP_BIT == 0
}

@(private)
world_alive_id :: proc "contextless" (w: ^World, id: i32) -> bool {
	return id > 0 && id < w.capacity && w.gens[id] != 0 && w.gens[id] & SLEEP_BIT == 0
}

// Long-lifetime handle for the entity; stays valid across entity id recycling
// because it carries the generation.
handle :: proc "contextless" (w: ^World, e: Entity) -> Entity_Long {
	id := i32(e)
	return Entity_Long{id = u32(id), gen = w.gens[id], world_id = u16(w.id)}
}

is_alive_handle :: proc "contextless" (w: ^World, h: Entity_Long) -> bool {
	if i16(h.world_id) != w.id {
		return false
	}
	id := i32(h.id)
	return id > 0 && id < w.capacity && h.gen != 0 && w.gens[id] == h.gen && h.gen & SLEEP_BIT == 0
}

// All used entity ids (excludes null, includes pending-deleted; those are
// filtered out by is_alive checks during iteration).
world_entities :: proc(w: ^World) -> []i32 {
	world_release_del_buffer(w)
	return dispenser_used(&w.dispenser)[1:]
}

@(private)
world_upsize :: proc(w: ^World, min_cap: i32) {
	new_cap := w.capacity
	for new_cap < min_cap {
		new_cap *= 2
	}
	if new_cap == w.capacity {
		return
	}
	resize(&w.gens, int(new_cap))
	resize(&w.comp_counts, int(new_cap))
	resize(&w.masks, int(new_cap) << w.mask_shift)
	for slot in &w.pools {
		if slot.data != nil {
			slot.upsize(slot.data, new_cap)
		}
	}
	w.capacity = new_cap
}

// Grows the per-entity bitmap stride when a component ID exceeds the current
// chunk range. Rare (log growth); rebuilds the masks array row-wise.
@(private)
world_ensure_cid :: proc(w: ^World, cid: i32) {
	need_chunks := (cid >> 5) + 1
	if need_chunks <= mask_chunks(w) {
		return
	}
	new_shift := w.mask_shift
	for (i32(1) << new_shift) < need_chunks {
		new_shift += 1
	}
	new_chunks := i32(1) << new_shift
	old_chunks := mask_chunks(w)
	new_masks := make([dynamic]i32, w.capacity << new_shift, w.capacity << new_shift, w.allocator)
	for e in 0 ..< int(w.capacity) {
		copy(
			new_masks[(i32(e) << new_shift):(i32(e) << new_shift) + new_chunks],
			w.masks[(i32(e) << w.mask_shift):(i32(e) << w.mask_shift) + old_chunks],
		)
	}
	delete(w.masks)
	w.masks = new_masks
	w.mask_shift = new_shift
}

@(private)
world_set_bit :: proc "contextless" (w: ^World, e: i32, cid: i32) {
	w.masks[(e << w.mask_shift) + (cid >> 5)] |= 1 << u32(cid & 31)
}

@(private)
world_clear_bit :: proc "contextless" (w: ^World, e: i32, cid: i32) {
	w.masks[(e << w.mask_shift) + (cid >> 5)] &= ~(1 << u32(cid & 31))
}

// Notification helpers called by both Pool and Tag_Pool on structural change.
@(private)
world_notify_add :: proc(w: ^World, id: i32, cid: i32) {
	world_set_bit(w, id, cid)
	w.comp_counts[id] += 1
	w.version += 1
}

// The DragonECS rule lives here: an entity that lost its last component is
// deleted. During world_release_del_buffer the entity is already
// sleep-marked, so the nested del_entity is a no-op there.
@(private)
world_notify_del :: proc(w: ^World, id: i32, cid: i32) {
	world_clear_bit(w, id, cid)
	w.comp_counts[id] -= 1
	w.version += 1
	if w.comp_counts[id] == 0 {
		del_entity(w, Entity(id))
	}
}

// ---------------------------------------------------------------------------
// Pools (typed API)
// ---------------------------------------------------------------------------

// Returns the world's pool for T, registering it on first use.
// Cache the returned pointer at system init; registration is not a hot path.
get_pool :: proc(w: ^World, $T: typeid) -> ^Pool(T) {
	cid := component_id(T)
	if int(cid) >= len(w.pools) {
		new_len := max(int(cid) + 1, len(w.pools) * 2)
		resize(&w.pools, new_len)
	}
	slot := &w.pools[cid]
	if slot.data == nil {
		p := pool_make(w, cid, w.allocator, T)
		pool_upsize(p, w.capacity)
		slot^ = any_pool_wrap(p)
		world_ensure_cid(w, cid)
		w.version += 1
	} else {
		assert(!slot.is_tag, "get_pool: T is a tag component (size 0); use get_tag_pool")
	}
	return (^Pool(T))(slot.data)
}

// Tag-pool counterpart for zero-size components.
get_tag_pool :: proc(w: ^World, $T: typeid) -> ^Tag_Pool(T) {
	cid := component_id(T)
	if int(cid) >= len(w.pools) {
		new_len := max(int(cid) + 1, len(w.pools) * 2)
		resize(&w.pools, new_len)
	}
	slot := &w.pools[cid]
	if slot.data == nil {
		p := tag_pool_make(w, cid, w.allocator, T)
		tag_pool_upsize(p, w.capacity)
		slot^ = tag_any_pool_wrap(p)
		world_ensure_cid(w, cid)
		w.version += 1
	} else {
		assert(slot.is_tag, "get_tag_pool: T is a data component; use get_pool")
	}
	return (^Tag_Pool(T))(slot.data)
}

// Registers T's pool in the world, picking Pool or Tag_Pool by size.
ensure_pool :: proc(w: ^World, $T: typeid) {
	when size_of(T) == 0 {
		get_tag_pool(w, T)
	} else {
		get_pool(w, T)
	}
}

// Adds a component T to the entity. For zero-size T this routes to the tag
// pool and returns nil; otherwise returns a pointer to the zero-initialized
// component. Pools keep the world bitmap/count in sync, so cached pool
// pointers can be used directly with identical semantics.
add :: proc(w: ^World, e: Entity, $T: typeid) -> ^T {
	dbg_assert(is_alive(w, e), "add: entity is not alive")
	when size_of(T) == 0 {
		tag_pool_add(get_tag_pool(w, T), e)
		return nil
	} else {
		return pool_add(get_pool(w, T), e)
	}
}

get :: proc(w: ^World, e: Entity, $T: typeid) -> ^T {
	when size_of(T) == 0 {
		return nil
	} else {
		p := get_pool(w, T)
		return pool_get(p, e)
	}
}

try_get :: proc(w: ^World, e: Entity, $T: typeid) -> (^T, bool) {
	when size_of(T) == 0 {
		return nil, has(w, e, T)
	} else {
		p := get_pool(w, T)
		return pool_try_get(p, e)
	}
}

has :: proc(w: ^World, e: Entity, $T: typeid) -> bool {
	id := i32(e)
	if id <= 0 || id >= w.capacity {
		return false
	}
	cid := component_id(T)
	if int(cid) >= len(w.pools) || w.pools[cid].data == nil {
		return false
	}
	// the world bitmap is the source of truth: one direct bit read, no
	// vtable indirection into the pool
	return w.masks[(id << w.mask_shift) + (cid >> 5)] & (1 << u32(cid & 31)) != 0
}

// Removes the component. If it was the entity's last component, the entity is
// automatically deleted (same rule as DragonECS).
del :: proc(w: ^World, e: Entity, $T: typeid) {
	cid := component_id(T)
	if int(cid) >= len(w.pools) || w.pools[cid].data == nil {
		return
	}
	w.pools[cid].del(w.pools[cid].data, i32(e))
}

// Copies all components of src onto dst (same world), overwriting existing
// ones. Port of DragonECS's CopyEntity.
copy_entity :: proc(w: ^World, dst, src: Entity) {
	assert(is_alive(w, dst) && is_alive(w, src), "copy_entity: dead entity")
	sid := i32(src)
	for &slot in &w.pools {
		if slot.data == nil || !slot.has(slot.data, sid) {
			continue
		}
		slot.copy(slot.data, slot.data, i32(dst), sid)
	}
}

// Cross-world variant of copy_entity. Only component types whose pools exist
// in the destination world are copied (type identity verified per pool).
copy_entity_cross :: proc(dst_w: ^World, dst: Entity, src_w: ^World, src: Entity) {
	assert(is_alive(dst_w, dst) && is_alive(src_w, src), "copy_entity_cross: dead entity")
	sid := i32(src)
	did := i32(dst)
	for &slot in &src_w.pools {
		if slot.data == nil || !slot.has(slot.data, sid) {
			continue
		}
		cid := slot.cid
		if int(cid) >= len(dst_w.pools) || dst_w.pools[cid].data == nil {
			continue
		}
		dslot := &dst_w.pools[cid]
		if dslot.ctype != slot.ctype {
			continue
		}
		dslot.copy(dslot.data, slot.data, did, sid)
	}
}

// Creates an entity and applies a mask as a template (inc -> empty components
// added, exc -> removed). Port of DragonECS's ITemplateNode flow.
new_entity_with :: proc(w: ^World, m: ^Mask) -> Entity {
	e := new_entity(w)
	mask_apply(w, e, m)
	return e
}

// ---------------------------------------------------------------------------
// World singleton components (port of EcsWorld.Get<T>)
// ---------------------------------------------------------------------------

// Returns the world singleton component for T, creating it zero-initialized
// on first use.
world_get :: proc(w: ^World, $T: typeid) -> ^T {
	if v, ok := w.world_comps[T]; ok {
		return (^T)(v)
	}
	v := new(T, w.allocator)
	w.world_comps[T] = rawptr(v)
	return v
}

world_has :: proc(w: ^World, $T: typeid) -> bool {
	_, ok := w.world_comps[T]
	return ok
}

world_del :: proc(w: ^World, $T: typeid) {
	if v, ok := w.world_comps[T]; ok {
		free(v, w.allocator)
		delete_key(&w.world_comps, T)
	}
}
