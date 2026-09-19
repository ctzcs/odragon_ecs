// Package odragon is an Odin-native ECS library ported from DragonECS
// (https://github.com/DCFApixels/DragonECS).
//
// Core concepts:
//
//   - World: entity container + component pools + query cache. Create with
//     world_create, always pair with world_destroy.
//   - Entity: dense i32 id; Entity_Long is the 64-bit generation-checked
//     long-lifetime handle (resolvable via resolve_handle).
//   - Components: any struct; zero-size structs automatically become tags
//     (stored in a Tag_Pool without data payload).
//   - Pools: sparse-set storage. Cache pool pointers at system init
//     (get_pool / get_tag_pool) and drive them directly (pool_set, pool_add,
//     pool_del) — pools keep the world bitmap in sync themselves.
//   - Queries: mask-based (mask_new/mask_inc/mask_exc/mask_any/mask_build)
//     iterated with query/query_next — automatically served from the world's
//     versioned cache; query_uncached forces a live scan, query_cached returns
//     the materialized slice. Typed sugar query1/query2/query3 hands out
//     direct component pointers.
//   - Pipeline: ordered systems (system_make + pipeline_add with layers),
//     service-locator DI via pipeline_inject/service.
//   - Group: paged sparse entity set with union/intersect/except ops,
//     auto-pruned when entities die.
//
// Minimal example:
//
//	world := odon.world_create()
//	defer odon.world_destroy(world)
//
//	e := odon.new_entity(world)
//	odon.add(world, e, Pos)^ = {0, 0}
//	odon.add(world, e, Vel)^ = {1, 2}
//
//	q := odon.query2(world, Pos, Vel)
//	pos: ^Pos
//	vel: ^Vel
//	for odon.query_next(&q, &e, &pos, &vel) {
//		pos.x += vel.x
//		pos.y += vel.y
//	}
//
// Performance notes:
//
//   - In hot iteration loops prefer `#force_inline` on query_next calls —
//     inlined iterator state vectorizes (~20x on cached queries).
//   - Mass spawning: world_create(initial_capacity = n) + pool_reserve.
//   - Structural changes during iteration of a cached query must be deferred
//     (collect into a Group or slice, apply after), same as DragonECS.
package odragon
