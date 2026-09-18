package odragon

import "core:mem"
import "core:testing"

Pos :: struct {
	x, y: f32,
}
Vel :: struct {
	x, y: f32,
}
Dead :: struct {}

@(test)
test_entity_lifecycle :: proc(t: ^testing.T) {
	w := world_create()
	defer world_destroy(w)

	e := new_entity(w)
	testing.expect(t, is_alive(w, e))
	add(w, e, Pos)

	h := handle(w, e)
	testing.expect(t, is_alive_handle(w, h))

	del_entity(w, e)
	testing.expect(t, !is_alive(w, e))
	testing.expect(t, !is_alive_handle(w, h))

	world_release_del_buffer(w)

	e2 := new_entity(w)
	testing.expect(t, e2 == e, "id should be recycled")
	testing.expect(t, is_alive(w, e2))

	h2 := handle(w, e2)
	testing.expect(t, h2.gen != h.gen, "recycled id must bump generation")
	testing.expect(t, !is_alive_handle(w, h), "stale handle must be dead")
	testing.expect(t, is_alive_handle(w, h2))
}

@(test)
test_component_add_get_del :: proc(t: ^testing.T) {
	w := world_create()
	defer world_destroy(w)

	e := new_entity(w)
	p := add(w, e, Pos)
	p.x = 5
	p.y = 7
	testing.expect(t, has(w, e, Pos))
	testing.expect(t, get(w, e, Pos).x == 5)
	testing.expect(t, get(w, e, Pos).y == 7)

	v, ok := try_get(w, e, Pos)
	testing.expect(t, ok && v.x == 5)

	del(w, e, Pos)
	testing.expect(t, !has(w, e, Pos))
	// Pos was the last component: entity auto-deleted (DragonECS rule)
	testing.expect(t, !is_alive(w, e))
}

@(test)
test_query_inc_exc :: proc(t: ^testing.T) {
	w := world_create()
	defer world_destroy(w)

	// 10 x Pos+Vel, 5 x Pos only, 3 x Pos+Vel+Dead
	for i in 0 ..< 10 {
		e := new_entity(w)
		add(w, e, Pos)
		add(w, e, Vel)
	}
	for i in 0 ..< 5 {
		e := new_entity(w)
		add(w, e, Pos)
	}
	for i in 0 ..< 3 {
		e := new_entity(w)
		add(w, e, Pos)
		add(w, e, Vel)
		add(w, e, Dead)
	}

	mb := mask_new(w)
	mask_inc(&mb, Pos)
	mask_inc(&mb, Vel)
	mask_exc(&mb, Dead)
	m := mask_build(&mb)
	defer mask_destroy(&m)

	count := 0
	q := query(w, &m)
	e: Entity
	for query_next(&q, &e) {
		count += 1
		testing.expect(t, has(w, e, Pos))
		testing.expect(t, has(w, e, Vel))
		testing.expect(t, !has(w, e, Dead))
	}
	testing.expect(t, count == 10)
}

@(test)
test_query_any :: proc(t: ^testing.T) {
	w := world_create()
	defer world_destroy(w)

	a := new_entity(w)
	add(w, a, Pos)
	add(w, a, Vel)
	b := new_entity(w)
	add(w, b, Pos)
	add(w, b, Dead)
	c := new_entity(w)
	add(w, c, Pos)

	mb := mask_new(w)
	mask_inc(&mb, Pos)
	mask_any(&mb, Vel)
	mask_any(&mb, Dead)
	m := mask_build(&mb)
	defer mask_destroy(&m)

	matches := query_all(w, &m)
	defer delete(matches)
	testing.expect(t, len(matches) == 2, "any must match Vel-or-Dead holders")
}

@(test)
test_query_single_inc_fast_path :: proc(t: ^testing.T) {
	w := world_create()
	defer world_destroy(w)

	for i in 0 ..< 32 {
		e := new_entity(w)
		add(w, e, Pos)
		get(w, e, Pos).x = f32(i)
	}

	mb := mask_new(w)
	mask_inc(&mb, Pos)
	m := mask_build(&mb)
	defer mask_destroy(&m)

	sum: f32
	q := query(w, &m)
	testing.expect(t, q.fast, "single-inc mask must take the fast path")
	e: Entity
	for query_next(&q, &e) {
		sum += get(w, e, Pos).x
	}
	testing.expect(t, sum == f32(31 * 32 / 2))
}

@(test)
test_deferred_deletion :: proc(t: ^testing.T) {
	w := world_create()
	defer world_destroy(w)

	e := new_entity(w)
	add(w, e, Pos)
	del_entity(w, e)

	// Before release the pool still holds the component (two-phase delete)
	testing.expect(t, w.pools[component_id(Pos)].count(w.pools[component_id(Pos)].data) == 1)

	// query() auto-releases the buffer
	mb := mask_new(w)
	mask_inc(&mb, Pos)
	m := mask_build(&mb)
	defer mask_destroy(&m)
	q := query(w, &m)
	out: Entity
	testing.expect(t, !query_next(&q, &out))
	testing.expect(t, w.pools[component_id(Pos)].count(w.pools[component_id(Pos)].data) == 0)
}

Sys_Ctx :: struct {
	id:  i32,
	log: ^[dynamic]i32,
}

@(private)
sys_run :: proc(data: rawptr, p: ^Pipeline) {
	ctx := (^Sys_Ctx)(data)
	append(ctx.log, ctx.id)
}

Cfg :: struct {
	value: i32,
}

@(private)
sys_init_read_cfg :: proc(data: rawptr, p: ^Pipeline) {
	ctx := (^Sys_Ctx)(data)
	cfg := service(p, Cfg)
	if cfg != nil {
		append(ctx.log, cfg.value)
	}
}

@(test)
test_pipeline_order_and_inject :: proc(t: ^testing.T) {
	w := world_create()
	defer world_destroy(w)

	log := make([dynamic]i32, 0, 8, context.allocator)
	defer delete(log)

	ctxs: [4]Sys_Ctx
	for i in 0 ..< 4 {
		ctxs[i] = Sys_Ctx{id = i32(i + 1), log = &log}
	}

	pipe := pipeline_create(w)
	cfg := Cfg{value = 99}
	pipeline_inject(pipe, &cfg)
	pipeline_add(pipe, system_make("s3", &ctxs[2], run = sys_run), layer = .Basic, order = 1)
	pipeline_add(pipe, system_make("s4", &ctxs[3], run = sys_run), layer = .Post_End)
	pipeline_add(pipe, system_make("s1", &ctxs[0], run = sys_run), layer = .Pre_Begin)
	pipeline_add(pipe, system_make("s2", &ctxs[1], run = sys_run), layer = .Basic, order = 0)
	pipeline_add(pipe, system_make("cfg", &ctxs[0], init = sys_init_read_cfg), layer = .Pre_Begin)
	pipeline_init(pipe)
	pipeline_run(pipe)
	pipeline_destroy(pipe)

	testing.expect(t, len(log) == 5)
	if len(log) == 5 {
		testing.expect(t, log[0] == 99, "init injection must deliver Cfg")
		testing.expect(t, log[1] == 1, "Pre_Begin first")
		testing.expect(t, log[2] == 2, "Basic order=0 before order=1")
		testing.expect(t, log[3] == 3)
		testing.expect(t, log[4] == 4, "Post_End last")
	}
}

@(test)
test_no_leaks :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)

	{
		w := world_create()
		for i in 0 ..< 1000 {
			e := new_entity(w)
			add(w, e, Pos)
			if i % 3 == 0 {
				add(w, e, Vel)
			}
			if i % 10 == 0 {
				del_entity(w, e)
			}
		}
		mb := mask_new(w)
		mask_inc(&mb, Pos)
		m := mask_build(&mb)
		matches := query_all(w, &m)
		delete(matches)
		mask_destroy(&m)
		world_destroy(w)
	}

	for _, leak in track.allocation_map {
		testing.fail(t)
		_ = leak
		break
	}
	for bf in track.bad_free_array {
		testing.fail(t)
		_ = bf
		break
	}
}
