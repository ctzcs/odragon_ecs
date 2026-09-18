package odragon

import "core:mem"
import "core:slice"

// Query: iterator over entities matching a Mask.
// Source selection mirrors DragonECS's EcsMaskIterator strategy:
//   - single-inc masks with no exc/any iterate the pool's dense list directly
//     (zero bitmap checks),
//   - otherwise the smallest inc pool drives iteration and each candidate is
//     bitmap-checked,
//   - masks without inc constraints scan all world entities.

Query :: struct {
	world:     ^World,
	mask:      ^Mask,
	source:    []i32,
	cached:    []Entity, // set when iterating a cached result slice
	use_cache: bool,
	cursor:    int,
	fast:      bool, // single inc, no exc/any: skip mask_matches
}

// Default query: automatically cached. Repeated queries with an equal mask
// hit the world's versioned query cache and iterate the materialized result
// instead of rescanning (DragonECS's Where-executor behavior). Use
// query_uncached for a guaranteed fresh scan.
//
// Caveat (same as DragonECS): the cached result buffer belongs to the world;
// a structural change recomputes it on the next query with the same mask,
// which invalidates slices held by still-active iterators of that mask.
query :: proc(w: ^World, m: ^Mask) -> Query {
	entry := cached_query_entry(w, m)
	return Query{world = w, mask = m, cached = entry.result[:], use_cache = true}
}

// Uncached scan: always walks the driving pool / world entities and checks
// the bitmap, never touches the query cache.
query_uncached :: proc(w: ^World, m: ^Mask) -> Query {
	world_release_del_buffer(w)
	q := Query{world = w, mask = m}
	if len(m.inc) > 0 {
		best: ^Any_Pool
		best_count := max(i32)
		for cid in m.inc {
			slot := &w.pools[cid]
			if slot.data == nil {
				// pool never registered in this world: nothing can match
				q.source = nil
				return q
			}
			c := slot.count(slot.data)
			if c < best_count {
				best_count = c
				best = slot
			}
		}
		q.source = best.entities(best.data)
		q.fast = len(m.inc) == 1 && len(m.exc) == 0 && len(m.any) == 0
	} else {
		q.source = world_entities(w)
	}
	return q
}

query_mask_next :: proc(q: ^Query, e_out: ^Entity) -> bool {
	if q.use_cache {
		if q.cursor < len(q.cached) {
			e_out^ = q.cached[q.cursor]
			q.cursor += 1
			return true
		}
		return false
	}
	if q.fast {
		if q.cursor < len(q.source) {
			e_out^ = Entity(q.source[q.cursor])
			q.cursor += 1
			return true
		}
		return false
	}
	#no_bounds_check for q.cursor < len(q.source) {
		id := q.source[q.cursor]
		q.cursor += 1
		if !world_alive_id(q.world, id) {
			continue
		}
		if mask_matches(q.world, q.mask, id) {
			e_out^ = Entity(id)
			return true
		}
	}
	return false
}

// Convenience: collect all matches into a slice (caller owns the memory).
query_all :: proc(w: ^World, m: ^Mask, allocator := context.allocator) -> []Entity {
	out := make([dynamic]Entity, 0, 64, allocator)
	q := query(w, m)
	e: Entity
	for query_mask_next(&q, &e) {
		append(&out, e)
	}
	return out[:]
}

// ---------------------------------------------------------------------------
// Versioned query result cache (port of DragonECS's executor caching with
// WorldStateVersionsChecker).
//
// query_cached returns a result slice owned by the cache entry; it is reused
// and overwritten by the next query_cached call for the same mask. The result
// is recomputed only when the world version or any involved pool's version
// changed since the last call, making repeated identical queries O(1).
// ---------------------------------------------------------------------------

Cached_Query :: struct {
	key:           u64,
	inc:           []i32, // owned copies, for hash-collision verification
	exc:           []i32,
	any:           []i32,
	cids:          []i32, // union of all involved component ids
	pvers:         []u32, // pool versions parallel to cids
	result:        [dynamic]Entity,
	world_version: u32,
}

@(private)
mask_key :: proc "contextless" (m: ^Mask) -> u64 {
	FNV_OFFSET :: u64(14695981039346656037)
	FNV_PRIME :: u64(1099511628211)
	h := FNV_OFFSET
	for id in m.inc {h = (h ~ u64(id)) * FNV_PRIME}
	h = (h ~ 0xFF) * FNV_PRIME
	for id in m.exc {h = (h ~ u64(id)) * FNV_PRIME}
	h = (h ~ 0xFF) * FNV_PRIME
	for id in m.any {h = (h ~ u64(id)) * FNV_PRIME}
	return h
}

@(private)
cached_query_valid :: proc(w: ^World, entry: ^Cached_Query) -> bool {
	if entry.world_version == w.version {
		return true
	}
	// Something changed globally; hit only if every involved pool is untouched.
	for cid, i in entry.cids {
		if int(cid) >= len(w.pools) || w.pools[cid].data == nil {
			return false
		}
		if w.pools[cid].version(w.pools[cid].data) != entry.pvers[i] {
			return false
		}
	}
	entry.world_version = w.version
	return true
}

@(private)
cached_query_recompute :: proc(w: ^World, entry: ^Cached_Query, m: ^Mask, key: u64) {
	entry.key = key
	delete(entry.inc, w.allocator)
	delete(entry.exc, w.allocator)
	delete(entry.any, w.allocator)
	delete(entry.cids, w.allocator)
	delete(entry.pvers, w.allocator)
	entry.inc = slice.clone(m.inc, w.allocator)
	entry.exc = slice.clone(m.exc, w.allocator)
	entry.any = slice.clone(m.any, w.allocator)

	cids := make([dynamic]i32, 0, len(m.inc) + len(m.exc) + len(m.any), w.allocator)
	append(&cids, ..m.inc)
	append(&cids, ..m.exc)
	append(&cids, ..m.any)
	slice.sort(cids[:])
	entry.cids = slice.unique(cids[:])
	entry.pvers = make([]u32, len(entry.cids), w.allocator)
	for cid, i in entry.cids {
		if int(cid) < len(w.pools) && w.pools[cid].data != nil {
			entry.pvers[i] = w.pools[cid].version(w.pools[cid].data)
		}
	}

	clear(&entry.result)
	q := query_uncached(w, m)
	e: Entity
	for query_mask_next(&q, &e) {
		append(&entry.result, e)
	}
	entry.world_version = w.version
}

@(private)
cached_query_free :: proc(entry: ^Cached_Query, allocator: mem.Allocator) {
	delete(entry.inc, allocator)
	delete(entry.exc, allocator)
	delete(entry.any, allocator)
	delete(entry.cids, allocator)
	delete(entry.pvers, allocator)
	delete(entry.result)
	free(entry, allocator)
}

// Returns the cache entry for a mask, creating/recomputing as needed.
@(private)
cached_query_entry :: proc(w: ^World, m: ^Mask) -> ^Cached_Query {
	world_release_del_buffer(w)
	key := mask_key(m)
	entry, ok := w.query_cache[key]
	if ok {
		ids_match :=
			slice.equal(entry.inc, m.inc) &&
			slice.equal(entry.exc, m.exc) &&
			slice.equal(entry.any, m.any)
		if ids_match {
			if cached_query_valid(w, entry) {
				return entry
			}
			cached_query_recompute(w, entry, m, key)
			return entry
		}
		// hash collision with a different mask: overwrite the entry
	}
	if !ok {
		entry = new(Cached_Query, w.allocator)
		entry.result = make([dynamic]Entity, 0, 64, w.allocator)
		w.query_cache[key] = entry
	}
	cached_query_recompute(w, entry, m, key)
	return entry
}

// Cached query as a plain slice. WARNING: the returned slice belongs to the
// cache entry and is overwritten by the next query with an equal mask (same
// rule as DragonECS's Where executors).
query_cached :: proc(w: ^World, m: ^Mask) -> []Entity {
	return cached_query_entry(w, m).result[:]
}
