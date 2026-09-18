package odragon

// Debug-only assert, matching DragonECS's DEBUG-conditional checks: active in
// -debug builds, compiled out in release builds.
dbg_assert :: proc(cond: bool, msg := "", loc := #caller_location) {
	when ODIN_DEBUG {
		assert(cond, msg, loc)
	}
}
