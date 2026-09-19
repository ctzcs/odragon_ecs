# bench_oflecs

与 `examples/bench/` 同场景，但走本地 oflecs 绑定（flecs 4.1.6 静态库，含 FFI 开销）。

## 构建

```sh
odin run bench_oflecs -collection:olib=D:\MySpace\Github\olib -o:speed
```

依赖本机 `D:\MySpace\Github\olib\oflecs`（或其等效路径，改 collection 即可）。
