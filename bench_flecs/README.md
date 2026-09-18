# bench_flecs

同场景 flecs(C, archetype 阵营代表）对照基准。oflecs 是 flecs 的 Odin 绑定，FFI 开销可忽略，故直接测 flecs C 库。

## 构建

```sh
git clone --depth 1 https://github.com/SanderMertens/flecs.git
# 注意：必须用完整版 flecs.c,flecs_no_addons.c 的查询引擎不支持 EcsNot
gcc -O2 -I flecs/distr bench.c flecs/distr/flecs.c -o bench_flecs.exe -ldbghelp -lws2_32
./bench_flecs.exe
```

场景与 `examples/bench/`（及 `bench_cs/`）逐行镜像。测得版本：flecs 4.1.6。
