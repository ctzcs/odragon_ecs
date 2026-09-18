package odragon

import "core:mem"

// Pool_Listener: add/del callbacks (port of DragonECS's IEcsPoolEventListener).
Pool_Listener :: struct {
	data:   rawptr,
	on_add: proc(data: rawptr, e: Entity),
	on_del: proc(data: rawptr, e: Entity),
}

// Pool(T): sparse-set component storage, the port of DragonECS's EcsPool<T>.
//
//	mapping[e] = item index (0 = absent)
//	items[item] = component data (items[0] is a dummy slot)
//	item_entities[item] = owning entity id (0 = dead slot)
//	recycle = stack of dead item indices reused by pool_add
//	dense[1..] = densified entity list for iteration (rebuilt by pool_densify)
//
// Deletion never swaps items, so a pointer returned by pool_get/pool_add is not
// invalidated by other deletions (same guarantee as DragonECS; note that growth
// of the items array may still reallocate, like DragonECS's managed arrays).
Pool :: struct($T: typeid) {
	cid:           i32,
	world:         ^World, // back-pointer: add/del keep the world bitmap in sync
	mapping:       [dynamic]i32,
	items:         [dynamic]T,
	item_entities: [dynamic]i32,
	dense:         [dynamic]i32,
	recycle:       [dynamic]i32,
	count:         i32,
	version:       u32, // bumped on every add/del; used by the query cache
	listeners:     [dynamic]Pool_Listener,
	is_densified:  bool,
	allocator:     mem.Allocator,
}

pool_make :: proc(w: ^World, cid: i32, allocator: mem.Allocator, $T: typeid) -> ^Pool(T) {
	p := new(Pool(T), allocator)
	p.cid = cid
	p.world = w
	p.allocator = allocator
	p.mapping = make([dynamic]i32, 0, 64, allocator)
	p.items = make([dynamic]T, 0, 64, allocator)
	append(&p.items, T{}) // dummy slot 0
	p.item_entities = make([dynamic]i32, 0, 64, allocator)
	append(&p.item_entities, 0)
	p.dense = make([dynamic]i32, 0, 64, allocator)
	append(&p.dense, 0)
	p.recycle = make([dynamic]i32, 0, 16, allocator)
	p.listeners = make([dynamic]Pool_Listener, 0, 4, allocator)
	p.is_densified = true
	return p
}

pool_destroy_typed :: proc(p: ^Pool($T)) {
	delete(p.mapping)
	delete(p.items)
	delete(p.item_entities)
	delete(p.dense)
	delete(p.recycle)
	delete(p.listeners)
	free(p, p.allocator)
}

pool_add_listener :: proc(
	p: ^Pool($T),
	on_add: proc(data: rawptr, e: Entity) = nil,
	on_del: proc(data: rawptr, e: Entity) = nil,
	data: rawptr = nil,
) {
	append(&p.listeners, Pool_Listener{data = data, on_add = on_add, on_del = on_del})
}

@(private)
pool_fire_add :: proc(p: ^Pool($T), e: Entity) {
	for l in p.listeners {
		if l.on_add != nil {
			l.on_add(l.data, e)
		}
	}
}

@(private)
pool_fire_del :: proc(p: ^Pool($T), e: Entity) {
	for l in p.listeners {
		if l.on_del != nil {
			l.on_del(l.data, e)
		}
	}
}

pool_upsize :: proc(p: ^Pool($T), cap: i32) {
	for i32(len(p.mapping)) < cap {
		append(&p.mapping, 0)
	}
}

pool_has :: proc(p: ^Pool($T), e: Entity) -> bool {
	id := i32(e)
	return id > 0 && id < i32(len(p.mapping)) && p.mapping[id] != 0
}

// Adds the component zero-initialized and returns a pointer to it.
// Debug-asserts if the entity already has it.
pool_add :: proc(p: ^Pool($T), e: Entity) -> ^T {
	id := i32(e)
	dbg_assert(id > 0 && id < i32(len(p.mapping)), "pool_add: entity out of range")
	dbg_assert(p.mapping[id] == 0, "pool_add: component already present")
	item: i32
	if len(p.recycle) > 0 {
		item = pop(&p.recycle)
	} else {
		item = i32(len(p.items))
		append(&p.items, T{})
		append(&p.item_entities, 0)
	}
	p.mapping[id] = item
	p.item_entities[item] = id
	p.items[item] = T{}
	p.count += 1
	p.version += 1
	p.is_densified = false
	if p.world != nil {
		world_notify_add(p.world, id, p.cid)
	}
	pool_fire_add(p, e)
	return &p.items[item]
}

pool_get :: proc(p: ^Pool($T), e: Entity) -> ^T {
	id := i32(e)
	dbg_assert(id > 0 && id < i32(len(p.mapping)) && p.mapping[id] != 0, "pool_get: component absent")
	return &p.items[p.mapping[id]]
}

pool_try_get :: proc(p: ^Pool($T), e: Entity) -> (^T, bool) {
	if !pool_has(p, e) {
		return nil, false
	}
	return &p.items[p.mapping[i32(e)]], true
}

// Removes the component without swapping; the slot goes to the recycle stack.
pool_del :: proc(p: ^Pool($T), e: Entity) {
	id := i32(e)
	if id <= 0 || id >= i32(len(p.mapping)) {
		return
	}
	item := p.mapping[id]
	if item == 0 {
		return
	}
	p.mapping[id] = 0
	p.item_entities[item] = 0
	append(&p.recycle, item)
	p.count -= 1
	p.version += 1
	p.is_densified = false
	if p.world != nil {
		world_notify_del(p.world, id, p.cid)
	}
	pool_fire_del(p, e)
}

pool_densify :: proc(p: ^Pool($T)) {
	if p.is_densified {
		return
	}
	clear(&p.dense)
	append(&p.dense, 0)
	for item in 1 ..< len(p.item_entities) {
		if ent := p.item_entities[item]; ent != 0 {
			append(&p.dense, ent)
		}
	}
	p.is_densified = true
}

// Entity ids of all live components; valid until the next add/del.
pool_entities :: proc(p: ^Pool($T)) -> []i32 {
	pool_densify(p)
	return p.dense[1:]
}

// ---------------------------------------------------------------------------
// Any_Pool: type-erased vtable so World can hold heterogeneous pools,
// replacing DragonECS's IEcsPoolImplementation[].
// ---------------------------------------------------------------------------

Any_Pool :: struct {
	data:      rawptr,
	cid:       i32,
	ctype:     typeid,
	is_tag:    bool,
	has:       proc(data: rawptr, e: i32) -> bool,
	add_empty: proc(data: rawptr, e: i32),
	del:       proc(data: rawptr, e: i32),
	copy:      proc(dst_data, src_data: rawptr, dst_e, src_e: i32),
	upsize:    proc(data: rawptr, cap: i32),
	densify:   proc(data: rawptr),
	count:     proc(data: rawptr) -> i32,
	version:   proc(data: rawptr) -> u32,
	entities:  proc(data: rawptr) -> []i32,
	destroy:   proc(data: rawptr),
}

any_pool_wrap :: proc(p: ^Pool($T)) -> Any_Pool {
	has :: proc(data: rawptr, e: i32) -> bool {
		return pool_has((^Pool(T))(data), Entity(e))
	}
	add_empty :: proc(data: rawptr, e: i32) {
		pool_add((^Pool(T))(data), Entity(e))
	}
	del :: proc(data: rawptr, e: i32) {
		pool_del((^Pool(T))(data), Entity(e))
	}
	upsize :: proc(data: rawptr, cap: i32) {
		pool_upsize((^Pool(T))(data), cap)
	}
	densify :: proc(data: rawptr) {
		pool_densify((^Pool(T))(data))
	}
	count :: proc(data: rawptr) -> i32 {
		return ((^Pool(T))(data)).count
	}
	version :: proc(data: rawptr) -> u32 {
		return ((^Pool(T))(data)).version
	}
	copy :: proc(dst_data, src_data: rawptr, dst_e, src_e: i32) {
		dp := (^Pool(T))(dst_data)
		sp := (^Pool(T))(src_data)
		v := pool_get(sp, Entity(src_e))^
		if pool_has(dp, Entity(dst_e)) {
			pool_get(dp, Entity(dst_e))^ = v
		} else {
			pool_add(dp, Entity(dst_e))^ = v
		}
	}
	entities :: proc(data: rawptr) -> []i32 {
		return pool_entities((^Pool(T))(data))
	}
	destroy :: proc(data: rawptr) {
		pool_destroy_typed((^Pool(T))(data))
	}
	return Any_Pool {
		data = rawptr(p),
		cid = p.cid,
		ctype = T,
		has = has,
		add_empty = add_empty,
		del = del,
		copy = copy,
		upsize = upsize,
		densify = densify,
		count = count,
		version = version,
		entities = entities,
		destroy = destroy,
	}
}
