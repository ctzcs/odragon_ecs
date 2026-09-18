package odragon

import "core:mem"
import "core:slice"

// Pipeline: ordered system execution, replacing DragonECS's interface-based
// IEcsProcess/EcsRunner with an explicit proc table. Layer + sort_order
// semantics are kept (Pre_Begin -> Begin -> Basic -> End -> Post_End).

Layer :: enum i32 {
	Pre_Begin,
	Begin,
	Basic,
	End,
	Post_End,
}

System :: struct {
	name:    string,
	data:    rawptr,
	init:    proc(data: rawptr, p: ^Pipeline),
	run:     proc(data: rawptr, p: ^Pipeline),
	destroy: proc(data: rawptr, p: ^Pipeline),
}

system_make :: proc(
	name: string,
	data: rawptr,
	init: proc(data: rawptr, p: ^Pipeline) = nil,
	run: proc(data: rawptr, p: ^Pipeline) = nil,
	destroy: proc(data: rawptr, p: ^Pipeline) = nil,
) -> System {
	return System{name = name, data = data, init = init, run = run, destroy = destroy}
}

@(private)
System_Entry :: struct {
	system: System,
	layer:  Layer,
	order:  i32,
	seq:    i32,
}

Pipeline :: struct {
	world:     ^World,
	entries:   [dynamic]System_Entry,
	services:  map[typeid]rawptr,
	allocator: mem.Allocator,
	seq:       i32,
	inited:    bool,
}

pipeline_create :: proc(w: ^World, allocator := context.allocator) -> ^Pipeline {
	p := new(Pipeline, allocator)
	p.world = w
	p.allocator = allocator
	p.entries = make([dynamic]System_Entry, 0, 32, allocator)
	p.services = make(map[typeid]rawptr, 16, allocator)
	return p
}

pipeline_add :: proc(p: ^Pipeline, s: System, layer := Layer.Basic, order: i32 = 0) {
	append(&p.entries, System_Entry{system = s, layer = layer, order = order, seq = p.seq})
	p.seq += 1
}

// Service-locator DI-lite: inject a pointer by type, retrieve in system init.
pipeline_inject :: proc(p: ^Pipeline, ptr: ^$T) {
	p.services[T] = rawptr(ptr)
}

service :: proc(p: ^Pipeline, $T: typeid) -> ^T {
	if v, ok := p.services[T]; ok {
		return (^T)(v)
	}
	return nil
}

@(private)
sort_entries :: proc(p: ^Pipeline) {
	slice.stable_sort_by(p.entries[:], proc(a, b: System_Entry) -> bool {
		if a.layer != b.layer {
			return a.layer < b.layer
		}
		if a.order != b.order {
			return a.order < b.order
		}
		return a.seq < b.seq
	})
}

// Sorts systems, then runs init callbacks in order. Call once before run.
pipeline_init :: proc(p: ^Pipeline) {
	sort_entries(p)
	for e in &p.entries {
		if e.system.init != nil {
			e.system.init(e.system.data, p)
		}
	}
	p.inited = true
}

pipeline_run :: proc(p: ^Pipeline) {
	assert(p.inited, "pipeline_run before pipeline_init")
	for e in &p.entries {
		if e.system.run != nil {
			e.system.run(e.system.data, p)
		}
	}
}

pipeline_destroy :: proc(p: ^Pipeline) {
	for e in &p.entries {
		if e.system.destroy != nil {
			e.system.destroy(e.system.data, p)
		}
	}
	delete(p.entries)
	delete(p.services)
	free(p, p.allocator)
}
