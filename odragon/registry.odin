package odragon

// Global component registry: typeid -> dense auto-increment component ID.
// The ID is used directly as the world pool-table index and bitmap bit index
// (single-level mapping, replaces DragonECS's two-level TypeCode/componentTypeID).

import "base:runtime"

@(private)
_component_registry: map[typeid]i32

@(private)
_component_counter: i32

@(private, init)
_registry_init :: proc "contextless" () {
	context = runtime.default_context()
	_component_registry = make(map[typeid]i32, 256, runtime.heap_allocator())
}

// Returns the global component ID for T, registering it on first use.
// Call once at system/pool init and cache the result; not a per-frame path.
component_id :: proc($T: typeid) -> i32 {
	if id, ok := _component_registry[T]; ok {
		return id
	}
	id := _component_counter
	_component_counter += 1
	_component_registry[T] = id
	return id
}
