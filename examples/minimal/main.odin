package main

import "core:fmt"
import odon "odon:odragon"

Pos :: struct {
	x, y: f32,
}
Vel :: struct {
	x, y: f32,
}

Config :: struct {
	dt: f32,
}

Move_Sys :: struct {
	dummy: i32,
}

move_run :: proc(data: rawptr, p: ^odon.Pipeline) {
	cfg := odon.world_get(p.world, Config)
	q := odon.query2(p.world, Pos, Vel)
	e: odon.Entity
	pos: ^Pos
	vel: ^Vel
	for odon.query_next(&q, &e, &pos, &vel) {
		pos.x += vel.x * cfg.dt
		pos.y += vel.y * cfg.dt
	}
}

print_run :: proc(data: rawptr, p: ^odon.Pipeline) {
	mb := odon.mask_new(p.world)
	odon.mask_inc(&mb, Pos)
	m := odon.mask_build(&mb)
	defer odon.mask_destroy(&m)

	q := odon.query(p.world, &m)
	e: odon.Entity
	for odon.query_next(&q, &e) {
		fmt.println("entity", e, "pos:", odon.get(p.world, e, Pos)^)
	}
}

main :: proc() {
	world := odon.world_create()
	defer odon.world_destroy(world)

	odon.world_get(world, Config)^ = {dt = 0.5}

	for i in 0 ..< 5 {
		e := odon.new_entity(world)
		odon.add(world, e, Pos)^ = {f32(i), f32(i)}
		odon.add(world, e, Vel)^ = {1, 2}
	}

	pipe := odon.pipeline_create(world)
	odon.pipeline_add(pipe, odon.system_make("move", nil, run = move_run), layer = .Basic)
	odon.pipeline_add(pipe, odon.system_make("print", nil, run = print_run), layer = .End)
	odon.pipeline_init(pipe)
	odon.pipeline_run(pipe)
	odon.pipeline_destroy(pipe)
}
