package odragon

// Typed query sugar: bypasses mask construction entirely and hands out direct
// pool pointers. Iteration is driven by the smallest involved pool.
// Zero-size tag components are supported: their pointer out-params are nil.
//
//	q := odon.query2(world, Pos, Vel)
//	e: odon.Entity
//	pos: ^Pos
//	vel: ^Vel
//	for odon.query_next(&q, &e, &pos, &vel) { ... }

Query1 :: struct($A: typeid) {
	slot:   ^Any_Pool,
	pa:     ^Pool(A), // nil when A is a zero-size tag
	source: []i32,
	cursor: int,
}

Query2 :: struct($A, $B: typeid) {
	sa, sb:  ^Any_Pool,
	pa:      ^Pool(A), // nil for tags
	pb:      ^Pool(B),
	source:  []i32,
	cursor:  int,
}

Query3 :: struct($A, $B, $C: typeid) {
	sa, sb, sc: ^Any_Pool,
	pa:         ^Pool(A), // nil for tags
	pb:         ^Pool(B),
	pc:         ^Pool(C),
	source:     []i32,
	cursor:     int,
}

@(private)
query_slot :: proc(w: ^World, $T: typeid) -> ^Any_Pool {
	ensure_pool(w, T)
	return &w.pools[component_id(T)]
}

query1 :: proc(w: ^World, $A: typeid) -> Query1(A) {
	world_release_del_buffer(w)
	sa := query_slot(w, A)
	q := Query1(A){slot = sa, source = sa.entities(sa.data)}
	when size_of(A) > 0 {
		q.pa = (^Pool(A))(sa.data)
	}
	return q
}

query2 :: proc(w: ^World, $A: typeid, $B: typeid) -> Query2(A, B) {
	world_release_del_buffer(w)
	sa := query_slot(w, A)
	sb := query_slot(w, B)
	q := Query2(A, B){sa = sa, sb = sb}
	when size_of(A) > 0 {
		q.pa = (^Pool(A))(sa.data)
	}
	when size_of(B) > 0 {
		q.pb = (^Pool(B))(sb.data)
	}
	ca := sa.count(sa.data)
	cb := sb.count(sb.data)
	q.source = sa.entities(sa.data) if ca <= cb else sb.entities(sb.data)
	return q
}

query3 :: proc(w: ^World, $A: typeid, $B: typeid, $C: typeid) -> Query3(A, B, C) {
	world_release_del_buffer(w)
	sa := query_slot(w, A)
	sb := query_slot(w, B)
	sc := query_slot(w, C)
	q := Query3(A, B, C){sa = sa, sb = sb, sc = sc}
	when size_of(A) > 0 {
		q.pa = (^Pool(A))(sa.data)
	}
	when size_of(B) > 0 {
		q.pb = (^Pool(B))(sb.data)
	}
	when size_of(C) > 0 {
		q.pc = (^Pool(C))(sc.data)
	}
	ca := sa.count(sa.data)
	cb := sb.count(sb.data)
	cc := sc.count(sc.data)
	q.source = sa.entities(sa.data)
	if cb < ca && cb <= cc {
		q.source = sb.entities(sb.data)
	} else if cc < ca {
		q.source = sc.entities(sc.data)
	}
	return q
}

@(private)
slot_has :: proc(s: ^Any_Pool, id: i32) -> bool {
	return s.has(s.data, id)
}

query1_next :: proc(q: ^Query1($A), e_out: ^Entity, a: ^^A) -> bool {
	if q.cursor >= len(q.source) {
		return false
	}
	id := q.source[q.cursor]
	q.cursor += 1
	e_out^ = Entity(id)
	when size_of(A) == 0 {
		a^ = nil
	} else {
		a^ = pool_get(q.pa, Entity(id))
	}
	return true
}

query2_next :: proc(q: ^Query2($A, $B), e_out: ^Entity, a: ^^A, b: ^^B) -> bool {
	for q.cursor < len(q.source) {
		id := q.source[q.cursor]
		q.cursor += 1
		e := Entity(id)
		when size_of(A) == 0 {
			if !slot_has(q.sa, id) { continue }
		} else {
			if !pool_has(q.pa, e) { continue }
		}
		when size_of(B) == 0 {
			if !slot_has(q.sb, id) { continue }
		} else {
			if !pool_has(q.pb, e) { continue }
		}
		e_out^ = e
		when size_of(A) == 0 {
			a^ = nil
		} else {
			a^ = pool_get(q.pa, e)
		}
		when size_of(B) == 0 {
			b^ = nil
		} else {
			b^ = pool_get(q.pb, e)
		}
		return true
	}
	return false
}

query3_next :: proc(q: ^Query3($A, $B, $C), e_out: ^Entity, a: ^^A, b: ^^B, c: ^^C) -> bool {
	for q.cursor < len(q.source) {
		id := q.source[q.cursor]
		q.cursor += 1
		e := Entity(id)
		when size_of(A) == 0 {
			if !slot_has(q.sa, id) { continue }
		} else {
			if !pool_has(q.pa, e) { continue }
		}
		when size_of(B) == 0 {
			if !slot_has(q.sb, id) { continue }
		} else {
			if !pool_has(q.pb, e) { continue }
		}
		when size_of(C) == 0 {
			if !slot_has(q.sc, id) { continue }
		} else {
			if !pool_has(q.pc, e) { continue }
		}
		e_out^ = e
		when size_of(A) == 0 {
			a^ = nil
		} else {
			a^ = pool_get(q.pa, e)
		}
		when size_of(B) == 0 {
			b^ = nil
		} else {
			b^ = pool_get(q.pb, e)
		}
		when size_of(C) == 0 {
			c^ = nil
		} else {
			c^ = pool_get(q.pc, e)
		}
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
