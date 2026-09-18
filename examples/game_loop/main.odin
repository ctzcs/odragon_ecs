package main

// A small but complete game loop demonstrating:
//   - the DragonECS event-world convention (events are components on entities
//     of a dedicated world, cleaned at the end of every frame),
//   - layered pipeline (director -> combat -> cleanup),
//   - Entity_Long handles for cross-frame/cross-world references,
//   - typed queries (query1) and pool pointer caching.

import "core:fmt"
import odon "odon:odragon"

Health :: struct {
	hp: f32,
}
Dead :: struct {}

DamageEvent :: struct {
	target: odon.Entity_Long,
	amount: f32,
}

Ctx :: struct {
	world:  ^odon.World,
	events: ^odon.World,
	frame:  int,
}

// Pre_Begin: the director spawns damage events on frame 2.
director_run :: proc(data: rawptr, p: ^odon.Pipeline) {
	ctx := (^Ctx)(data)
	if ctx.frame != 2 {
		return
	}
	q := odon.query1(ctx.world, Health)
	e: odon.Entity
	hp: ^Health
	for odon.query_next(&q, &e, &hp) {
		ev := odon.new_entity(ctx.events)
		odon.add(ctx.events, ev, DamageEvent)^ = {target = odon.handle(ctx.world, e), amount = 50}
	}
}

// Basic: apply damage events to main-world entities.
combat_run :: proc(data: rawptr, p: ^odon.Pipeline) {
	ctx := (^Ctx)(data)
	hp_pool := odon.get_pool(ctx.world, Health)
	q := odon.query1(ctx.events, DamageEvent)
	e: odon.Entity
	ev: ^DamageEvent
	for odon.query_next(&q, &e, &ev) {
		if !odon.is_alive_handle(ctx.world, ev.target) {
			continue // target already gone: stale handle safely rejected
		}
		t := odon.entity_of(ev.target)
		hp := odon.pool_get(hp_pool, t)
		hp.hp -= ev.amount
		fmt.printf("  entity %d takes %.0f damage, hp=%.0f\n", t, ev.amount, hp.hp)
		if hp.hp <= 0 && !odon.has(ctx.world, t, Dead) {
			odon.add(ctx.world, t, Dead)
		}
	}
}

// End: sweep dead entities, then clear the whole event world.
cleanup_run :: proc(data: rawptr, p: ^odon.Pipeline) {
	ctx := (^Ctx)(data)
	q := odon.query1(ctx.world, Dead)
	e: odon.Entity
	d: ^Dead
	for odon.query_next(&q, &e, &d) {
		fmt.println("  entity", e, "died")
		odon.del_entity(ctx.world, e)
	}
	for id in odon.world_entities(ctx.events) {
		odon.del_entity(ctx.events, odon.Entity(id))
	}
}

main :: proc() {
	world := odon.world_create()
	events := odon.world_create()
	defer odon.world_destroy(world)
	defer odon.world_destroy(events)

	for i in 0 ..< 3 {
		e := odon.new_entity(world)
		odon.add(world, e, Health)^ = {hp = 100 - f32(i) * 30}
	}

	ctx := Ctx{world = world, events = events}
	pipe := odon.pipeline_create(world)
	odon.pipeline_add(pipe, odon.system_make("director", &ctx, run = director_run), layer = .Pre_Begin)
	odon.pipeline_add(pipe, odon.system_make("combat", &ctx, run = combat_run), layer = .Basic)
	odon.pipeline_add(pipe, odon.system_make("cleanup", &ctx, run = cleanup_run), layer = .End)
	odon.pipeline_init(pipe)

	for frame in 1 ..= 3 {
		ctx.frame = frame
		fmt.println("--- frame", frame)
		odon.pipeline_run(pipe)
	}
	odon.pipeline_destroy(pipe)
}
