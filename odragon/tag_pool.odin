package odragon

import "core:mem"

// Tag_Pool(T): storage for zero-size "tag" components, the port of
// DragonECS's EcsTagPool<T>. Selected automatically by add()/ensure_pool()
// whenever size_of(T) == 0.
//
// Tags carry no data and therefore hand out no pointers, so unlike Pool(T)
// deletion here is swap-remove: the dense list is ALWAYS dense (no densify
// pass), and the item_entities/recycle ledgers of Pool(T) are eliminated.
//
//	mapping[e] = dense index (1-based; 0 = absent)
//	dense[1..] = entity ids, always compact

Tag_Pool :: struct($T: typeid) {
	cid:       i32,
	world:     ^World,
	mapping:   [dynamic]i32,
	dense:     [dynamic]i32,
	count:     i32,
	version:   u32,
	listeners: [dynamic]Pool_Listener,
	allocator: mem.Allocator,
}

tag_pool_make :: proc(w: ^World, cid: i32, allocator: mem.Allocator, $T: typeid) -> ^Tag_Pool(T) {
	p := new(Tag_Pool(T), allocator)
	p.cid = cid
	p.world = w
	p.allocator = allocator
	p.mapping = make([dynamic]i32, 0, 64, allocator)
	p.dense = make([dynamic]i32, 0, 64, allocator)
	append(&p.dense, 0)
	p.listeners = make([dynamic]Pool_Listener, 0, 4, allocator)
	return p
}

tag_pool_destroy_typed :: proc(p: ^Tag_Pool($T)) {
	delete(p.mapping)
	delete(p.dense)
	delete(p.listeners)
	free(p, p.allocator)
}

tag_pool_upsize :: proc(p: ^Tag_Pool($T), cap: i32) {
	for i32(len(p.mapping)) < cap {
		append(&p.mapping, 0)
	}
}

tag_pool_has :: proc(p: ^Tag_Pool($T), e: Entity) -> bool {
	id := i32(e)
	return id > 0 && id < i32(len(p.mapping)) && p.mapping[id] != 0
}

tag_pool_add :: proc(p: ^Tag_Pool($T), e: Entity) {
	id := i32(e)
	assert(id > 0 && id < i32(len(p.mapping)), "tag_pool_add: entity out of range")
	assert(p.mapping[id] == 0, "tag_pool_add: tag already present")
	append(&p.dense, id)
	p.mapping[id] = i32(len(p.dense)) - 1
	p.count += 1
	p.version += 1
	if p.world != nil {
		world_notify_add(p.world, id, p.cid)
	}
	for l in p.listeners {
		if l.on_add != nil {
			l.on_add(l.data, e)
		}
	}
}

tag_pool_del :: proc(p: ^Tag_Pool($T), e: Entity) {
	id := i32(e)
	if id <= 0 || id >= i32(len(p.mapping)) {
		return
	}
	di := p.mapping[id]
	if di == 0 {
		return
	}
	last := i32(len(p.dense)) - 1
	last_id := p.dense[last]
	p.dense[di] = last_id
	p.mapping[last_id] = di
	pop(&p.dense)
	p.mapping[id] = 0
	p.count -= 1
	p.version += 1
	if p.world != nil {
		world_notify_del(p.world, id, p.cid)
	}
	for l in p.listeners {
		if l.on_del != nil {
			l.on_del(l.data, e)
		}
	}
}

// EcsTagPool parity helpers.
tag_pool_set :: proc(p: ^Tag_Pool($T), e: Entity, present: bool) {
	if present {
		if !tag_pool_has(p, e) {
			tag_pool_add(p, e)
		}
	} else {
		tag_pool_del(p, e)
	}
}

tag_pool_toggle :: proc(p: ^Tag_Pool($T), e: Entity) {
	tag_pool_set(p, e, !tag_pool_has(p, e))
}

// Always-dense entity list; no densify step needed.
tag_pool_entities :: proc(p: ^Tag_Pool($T)) -> []i32 {
	return p.dense[1:]
}

@(private)
tag_any_pool_wrap :: proc(p: ^Tag_Pool($T)) -> Any_Pool {
	has :: proc(data: rawptr, e: i32) -> bool {
		return tag_pool_has((^Tag_Pool(T))(data), Entity(e))
	}
	add_empty :: proc(data: rawptr, e: i32) {
		tag_pool_add((^Tag_Pool(T))(data), Entity(e))
	}
	del :: proc(data: rawptr, e: i32) {
		tag_pool_del((^Tag_Pool(T))(data), Entity(e))
	}
	copy :: proc(dst_data, src_data: rawptr, dst_e, src_e: i32) {
		dp := (^Tag_Pool(T))(dst_data)
		sp := (^Tag_Pool(T))(src_data)
		if tag_pool_has(sp, Entity(src_e)) && !tag_pool_has(dp, Entity(dst_e)) {
			tag_pool_add(dp, Entity(dst_e))
		}
	}
	upsize :: proc(data: rawptr, cap: i32) {
		tag_pool_upsize((^Tag_Pool(T))(data), cap)
	}
	densify :: proc(data: rawptr) {}
	count :: proc(data: rawptr) -> i32 {
		return ((^Tag_Pool(T))(data)).count
	}
	version :: proc(data: rawptr) -> u32 {
		return ((^Tag_Pool(T))(data)).version
	}
	entities :: proc(data: rawptr) -> []i32 {
		return tag_pool_entities((^Tag_Pool(T))(data))
	}
	destroy :: proc(data: rawptr) {
		tag_pool_destroy_typed((^Tag_Pool(T))(data))
	}
	return Any_Pool {
		data = rawptr(p),
		cid = p.cid,
		ctype = T,
		is_tag = true,
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
