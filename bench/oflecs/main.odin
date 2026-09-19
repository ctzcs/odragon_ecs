package main

// Same scenarios as examples/bench, but driven through the oflecs binding
// (flecs 4.1.6, prebuilt static lib) — Odin-side, FFI-inclusive comparison.

import "core:fmt"
import "core:time"
import flecs "olib:oflecs"

Pos :: struct {
	x, y, z: f32,
}
Vel :: struct {
	x, y, z: f32,
}
Health :: struct {
	hp: f32,
}
Mana :: struct {
	mp: f32,
}
Buff :: struct {
	t: f32,
}

N :: 1_000_000
CHURN :: 100_000
REPEATS :: 5

State :: struct {
	w:        ^flecs.ecs_world_t,
	pos:      flecs.ecs_id_t,
	vel:      flecs.ecs_id_t,
	hp:       flecs.ecs_id_t,
	mp:       flecs.ecs_id_t,
	buff:     flecs.ecs_id_t,
	tag:      flecs.ecs_entity_t,
	entities: []flecs.ecs_entity_t,
	order:    []i32,
	sink:     f32,
	q_pos:    ^flecs.ecs_query_t,
	q_pv:     ^flecs.ecs_query_t,
	q_pvh:    ^flecs.ecs_query_t,
	q_sp:     ^flecs.ecs_query_t,
	q_exc:    ^flecs.ecs_query_t,
}

register_components :: proc(s: ^State) {
	w := s.w
	s.pos = flecs.ecs_component_init(w, &flecs.ecs_component_desc_t{
		entity = flecs.ecs_entity_init(w, &flecs.ecs_entity_desc_t{name = "Pos"}),
		type = {size = flecs.ecs_size_t(size_of(Pos)), alignment = flecs.ecs_size_t(align_of(Pos))},
	})
	s.vel = flecs.ecs_component_init(w, &flecs.ecs_component_desc_t{
		entity = flecs.ecs_entity_init(w, &flecs.ecs_entity_desc_t{name = "Vel"}),
		type = {size = flecs.ecs_size_t(size_of(Vel)), alignment = flecs.ecs_size_t(align_of(Vel))},
	})
	s.hp = flecs.ecs_component_init(w, &flecs.ecs_component_desc_t{
		entity = flecs.ecs_entity_init(w, &flecs.ecs_entity_desc_t{name = "Health"}),
		type = {size = flecs.ecs_size_t(size_of(Health)), alignment = flecs.ecs_size_t(align_of(Health))},
	})
	s.mp = flecs.ecs_component_init(w, &flecs.ecs_component_desc_t{
		entity = flecs.ecs_entity_init(w, &flecs.ecs_entity_desc_t{name = "Mana"}),
		type = {size = flecs.ecs_size_t(size_of(Mana)), alignment = flecs.ecs_size_t(align_of(Mana))},
	})
	s.buff = flecs.ecs_component_init(w, &flecs.ecs_component_desc_t{
		entity = flecs.ecs_entity_init(w, &flecs.ecs_entity_desc_t{name = "Buff"}),
		type = {size = flecs.ecs_size_t(size_of(Buff)), alignment = flecs.ecs_size_t(align_of(Buff))},
	})
	s.tag = flecs.ecs_entity_init(w, &flecs.ecs_entity_desc_t{name = "TagA"})
}

populate :: proc(s: ^State) {
	for i in 0 ..< N {
		e := flecs.ecs_new(s.w)
		p := Pos{1, 2, 3}
		flecs.ecs_set_id(s.w, e, s.pos, size_of(Pos), &p)
		v := Vel{1, 1, 1}
		flecs.ecs_set_id(s.w, e, s.vel, size_of(Vel), &v)
		h := Health{100}
		flecs.ecs_set_id(s.w, e, s.hp, size_of(Health), &h)
		if i % 10 == 0 {
			m := Mana{50}
			flecs.ecs_set_id(s.w, e, s.mp, size_of(Mana), &m)
			flecs.ecs_add_id(s.w, e, s.tag)
		}
		s.entities[i] = e
	}
}

measure :: proc(name: string, repeats: int, f: proc(), after_each: proc() = nil) {
	best := time.Duration(max(i64))
	for i in 0 ..< repeats {
		t0 := time.now()
		f()
		d := time.since(t0)
		if d < best {
			best = d
		}
		if after_each != nil {
			after_each()
		}
	}
	fmt.printf("  %-46s %9v\n", name, best)
}

main :: proc() {
	s := State{}
	s.entities = make([]flecs.ecs_entity_t, N)
	defer delete(s.entities)
	s.order = make([]i32, N)
	defer delete(s.order)
	{
		stride :: 999_983
		x := 0
		for i in 0 ..< N {
			s.order[i] = i32(x)
			x = (x + stride) % N
		}
	}
	context.user_ptr = &s

	measure("create 1M entities (Pos+Vel+Health, 10% +Mana+Tag)", 3, proc() {
		s := (^State)(context.user_ptr)
		s.w = flecs.ecs_init()
		register_components(s)
		populate(s)
	})
	// note: create includes ecs_init + register (cheap) — final world kept for the rest

	// queries created once; iteration measured warm (flecs caches tables per query)
	q_pos_desc := flecs.ecs_query_desc_t{}
	q_pos_desc.terms[0] = {id = s.pos}
	s.q_pos = flecs.ecs_query_init(s.w, &q_pos_desc)

	q_pv_desc := flecs.ecs_query_desc_t{}
	q_pv_desc.terms[0] = {id = s.pos}
	q_pv_desc.terms[1] = {id = s.vel}
	s.q_pv = flecs.ecs_query_init(s.w, &q_pv_desc)

	q_pvh_desc := flecs.ecs_query_desc_t{}
	q_pvh_desc.terms[0] = {id = s.pos}
	q_pvh_desc.terms[1] = {id = s.vel}
	q_pvh_desc.terms[2] = {id = s.hp}
	s.q_pvh = flecs.ecs_query_init(s.w, &q_pvh_desc)

	q_sp_desc := flecs.ecs_query_desc_t{}
	q_sp_desc.terms[0] = {id = s.pos}
	q_sp_desc.terms[1] = {id = s.mp}
	s.q_sp = flecs.ecs_query_init(s.w, &q_sp_desc)

	q_exc_desc := flecs.ecs_query_desc_t{}
	q_exc_desc.terms[0] = {id = s.pos}
	q_exc_desc.terms[1] = {id = s.vel}
	q_exc_desc.terms[2] = {id = s.tag, oper = i16(flecs.ecs_oper_kind_t.Not)}
	s.q_exc = flecs.ecs_query_init(s.w, &q_exc_desc)

	measure("iterate (Pos) x1M", REPEATS, proc() {
		s := (^State)(context.user_ptr)
		sum: f32
		it := flecs.ecs_query_iter(s.w, s.q_pos)
		for flecs.ecs_query_next(&it) {
			poses := ([^]Pos)(flecs.ecs_field_w_size(&it, size_of(Pos), 0))
			for i in 0 ..< it.count {
				sum += poses[i].x
			}
		}
		s.sink += sum
	})

	measure("iterate (Pos+Vel, write) x1M", REPEATS, proc() {
		s := (^State)(context.user_ptr)
		it := flecs.ecs_query_iter(s.w, s.q_pv)
		for flecs.ecs_query_next(&it) {
			poses := ([^]Pos)(flecs.ecs_field_w_size(&it, size_of(Pos), 0))
			vels := ([^]Vel)(flecs.ecs_field_w_size(&it, size_of(Vel), 1))
			for i in 0 ..< it.count {
				poses[i].x += vels[i].x
			}
		}
	})

	measure("iterate (Pos+Vel+Health, write) x1M", REPEATS, proc() {
		s := (^State)(context.user_ptr)
		it := flecs.ecs_query_iter(s.w, s.q_pvh)
		for flecs.ecs_query_next(&it) {
			poses := ([^]Pos)(flecs.ecs_field_w_size(&it, size_of(Pos), 0))
			vels := ([^]Vel)(flecs.ecs_field_w_size(&it, size_of(Vel), 1))
			hps := ([^]Health)(flecs.ecs_field_w_size(&it, size_of(Health), 2))
			for i in 0 ..< it.count {
				poses[i].x += vels[i].x * 0.0001
				hps[i].hp -= 0.0001
			}
		}
	})

	measure("iterate sparse (Pos+Mana) x100k", REPEATS, proc() {
		s := (^State)(context.user_ptr)
		sum: f32
		it := flecs.ecs_query_iter(s.w, s.q_sp)
		for flecs.ecs_query_next(&it) {
			poses := ([^]Pos)(flecs.ecs_field_w_size(&it, size_of(Pos), 0))
			manas := ([^]Mana)(flecs.ecs_field_w_size(&it, size_of(Mana), 1))
			for i in 0 ..< it.count {
				sum += poses[i].x + manas[i].mp
			}
		}
		s.sink += sum
	})

	measure("query (Pos+Vel, exc Tag) x900k", REPEATS, proc() {
		s := (^State)(context.user_ptr)
		n: i64
		it := flecs.ecs_query_iter(s.w, s.q_exc)
		for flecs.ecs_query_next(&it) {
			ents := ([^]flecs.ecs_entity_t)(it.entities)
			for i in 0 ..< it.count {
				n += i64(ents[i])
			}
		}
		s.sink += f32(n)
	})

	measure("random access get x1M (permutation)", REPEATS, proc() {
		s := (^State)(context.user_ptr)
		sum: f32
		for i in 0 ..< N {
			p := (^Pos)(flecs.ecs_get_id(s.w, s.entities[s.order[i]], s.pos))
			sum += p.x
		}
		s.sink += sum
	})

	measure("churn: add+remove Buff on 100k entities", REPEATS, proc() {
		s := (^State)(context.user_ptr)
		b := Buff{0.5}
		for i in 0 ..< CHURN {
			flecs.ecs_set_id(s.w, s.entities[i], s.buff, size_of(Buff), &b)
		}
		for i in 0 ..< CHURN {
			flecs.ecs_remove_id(s.w, s.entities[i], s.buff)
		}
	})

	measure(
		"delete 1M entities",
		3,
		proc() {
			s := (^State)(context.user_ptr)
			for i in 0 ..< N {
				flecs.ecs_delete(s.w, s.entities[i])
			}
		},
		proc() {
			s := (^State)(context.user_ptr)
			populate(s)
		},
	)

	flecs.ecs_query_fini(s.q_pos)
	flecs.ecs_query_fini(s.q_pv)
	flecs.ecs_query_fini(s.q_pvh)
	flecs.ecs_query_fini(s.q_sp)
	flecs.ecs_query_fini(s.q_exc)
	flecs.ecs_fini(s.w)
	fmt.printf("  (sink: %.1f)\n", s.sink)
}
