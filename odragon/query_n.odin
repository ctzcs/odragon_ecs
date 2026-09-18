package odragon

// Typed query sugar: bypasses mask construction entirely and hands out direct
// pool pointers. Iteration is driven by the smallest involved pool.
//
//	q := odon.query2(world, Pos, Vel)
//	e: odon.Entity
//	pos: ^Pos
//	vel: ^Vel
//	for odon.query_next(&q, &e, &pos, &vel) { ... }

Query1 :: struct($A: typeid) {
	pa:     ^Pool(A),
	source: []i32,
	cursor: int,
}

Query2 :: struct($A, $B: typeid) {
	pa:     ^Pool(A),
	pb:     ^Pool(B),
	source: []i32,
	cursor: int,
}

Query3 :: struct($A, $B, $C: typeid) {
	pa:     ^Pool(A),
	pb:     ^Pool(B),
	pc:     ^Pool(C),
	source: []i32,
	cursor: int,
}

query1 :: proc(w: ^World, $A: typeid) -> Query1(A) {
	world_release_del_buffer(w)
	pa := get_pool(w, A)
	return Query1(A){pa = pa, source = pool_entities(pa)}
}

query2 :: proc(w: ^World, $A: typeid, $B: typeid) -> Query2(A, B) {
	world_release_del_buffer(w)
	pa := get_pool(w, A)
	pb := get_pool(w, B)
	q := Query2(A, B){pa = pa, pb = pb}
	if pa.count <= pb.count {
		q.source = pool_entities(pa)
	} else {
		q.source = pool_entities(pb)
	}
	return q
}

query3 :: proc(w: ^World, $A: typeid, $B: typeid, $C: typeid) -> Query3(A, B, C) {
	world_release_del_buffer(w)
	pa := get_pool(w, A)
	pb := get_pool(w, B)
	pc := get_pool(w, C)
	q := Query3(A, B, C){pa = pa, pb = pb, pc = pc}
	q.source = pool_entities(pa)
	if pb.count < pa.count {
		q.source = pool_entities(pb)
	}
	if pc.count < min(pa.count, pb.count) {
		q.source = pool_entities(pc)
	}
	return q
}

query1_next :: proc(q: ^Query1($A), e_out: ^Entity, a: ^^A) -> bool {
	if q.cursor >= len(q.source) {
		return false
	}
	id := q.source[q.cursor]
	q.cursor += 1
	e_out^ = Entity(id)
	a^ = pool_get(q.pa, Entity(id))
	return true
}

query2_next :: proc(q: ^Query2($A, $B), e_out: ^Entity, a: ^^A, b: ^^B) -> bool {
	for q.cursor < len(q.source) {
		id := q.source[q.cursor]
		q.cursor += 1
		e := Entity(id)
		if !pool_has(q.pa, e) || !pool_has(q.pb, e) {
			continue
		}
		e_out^ = e
		a^ = pool_get(q.pa, e)
		b^ = pool_get(q.pb, e)
		return true
	}
	return false
}

query3_next :: proc(q: ^Query3($A, $B, $C), e_out: ^Entity, a: ^^A, b: ^^B, c: ^^C) -> bool {
	for q.cursor < len(q.source) {
		id := q.source[q.cursor]
		q.cursor += 1
		e := Entity(id)
		if !pool_has(q.pa, e) || !pool_has(q.pb, e) || !pool_has(q.pc, e) {
			continue
		}
		e_out^ = e
		a^ = pool_get(q.pa, e)
		b^ = pool_get(q.pb, e)
		c^ = pool_get(q.pc, e)
		return true
	}
	return false
}

// Unified iteration entry point: works with mask queries and typed queries.
query_next :: proc {
	query_mask_next,
	query1_next,
	query2_next,
	query3_next,
}
