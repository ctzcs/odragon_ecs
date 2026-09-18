package odragon

// Entity is the internal dense identifier. ID 0 is reserved as null.
Entity :: distinct i32

NULL_ENTITY :: Entity(0)

// Entity_Long is the 64-bit long-lifetime handle:
// [ id: u32 (low 32) | gen: u16 | world_id: u16 (high 16) ]
// Equivalent of DragonECS's entlong.
Entity_Long :: bit_field u64 {
	id:       u32 | 32,
	gen:      u16 | 16,
	world_id: u16 | 16,
}

entity_of :: proc "contextless" (h: Entity_Long) -> Entity {
	return Entity(i32(h.id))
}

entity_long_to_u64 :: proc "contextless" (h: Entity_Long) -> u64 {
	return transmute(u64)h
}

entity_long_from_u64 :: proc "contextless" (v: u64) -> Entity_Long {
	return transmute(Entity_Long)v
}

// Id_Dispenser: dense/sparse id allocator with recycling.
// dense[0 ..< count)    = ids in use
// dense[count ..< count+free_count) = recycled ids available for reuse
// dense[0] is permanently the null id.
Id_Dispenser :: struct {
	dense:      [dynamic]i32,
	sparse:     [dynamic]i32,
	count:      i32,
	free_count: i32,
}

dispenser_init :: proc(d: ^Id_Dispenser, capacity: i32, allocator := context.allocator) {
	d.dense = make([dynamic]i32, 0, capacity, allocator)
	d.sparse = make([dynamic]i32, 0, capacity, allocator)
	append(&d.dense, 0)
	append(&d.sparse, 0)
	d.count = 1
}

dispenser_destroy :: proc(d: ^Id_Dispenser) {
	delete(d.dense)
	delete(d.sparse)
}

dispenser_acquire :: proc(d: ^Id_Dispenser) -> i32 {
	if d.free_count > 0 {
		id := d.dense[d.count]
		d.count += 1
		d.free_count -= 1
		return id
	}
	id := i32(len(d.dense))
	append(&d.dense, id)
	append(&d.sparse, id)
	d.count += 1
	return id
}

dispenser_release :: proc(d: ^Id_Dispenser, id: i32) {
	dbg_assert(id > 0, "cannot release null entity id")
	di := d.sparse[id]
	last := d.count - 1
	last_id := d.dense[last]
	d.dense[di] = last_id
	d.sparse[last_id] = di
	d.dense[last] = id
	d.sparse[id] = last
	d.count -= 1
	d.free_count += 1
}

// Used ids (includes the null slot at index 0; callers skip it).
dispenser_used :: proc(d: ^Id_Dispenser) -> []i32 {
	return d.dense[:d.count]
}
