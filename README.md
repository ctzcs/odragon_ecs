# ODragonECS

DragonECS 的 Odin 原生移植。保留了 DragonECS 的核心语义——稀疏集组件池、32 位位图掩码、两阶段实体删除、代次校验的 64 位实体句柄、分层 Pipeline——同时把 C# 接口/反射驱动的上层建筑换成了 Odin 习惯的显式风格。

与 DragonECS 的关键差异：

- **单级组件 ID**：全局 `typeid → i32` 注册表给出的 ID 直接就是池表下标和位图位，没有"世界内重映射"层（换来每实体最多几十字节的位图余量）。
- **系统 = struct + 过程表**，不再是接口；层与排序语义保留。
- **Aspect DSL 由 Mask Builder 替代**(`mask_inc/mask_exc/mask_any`)。
- **DI 简化为服务定位器**(`pipeline_inject` / `service`)。
- **显式内存管理**：所有容器带 allocator，必须配对调用 `*_destroy`。

## 构建与测试

```sh
odin test odragon                                # 单元测试
odin run examples/minimal -collection:odon=.     # 最小示例：移动系统
odin run examples/game_loop -collection:odon=.   # 完整游戏循环：事件世界 + 分层 Pipeline
odin run examples/bench -collection:odon=. -o:speed   # 百万实体基准
```

## 基准对比（百万实体，Odin -o:speed vs C# DragonECS / .NET 10 Release，本机单次运行）

| 场景 | ODragonECS | DragonECS (C#) |
|---|---|---|
| 创建 100 万实体（2~3 组件） | ~72–95 ms | ~81–91 ms |
| 掩码查询迭代（Pos+Vel, exc Tag，匹配 90 万） | ~3.4–3.7 ms | ~12.8–13.1 ms(首次，含执行器构建） |
| 缓存查询重复执行 | ~1 µs（返回物化切片） | ~0.2 ms(foreach 迭代缓存 span) |
| 10 万实体删除+重建 | ~7.2–8.6 ms | ~18.1–18.4 ms |

注：缓存查询的测量口径不同——Odin 版返回已物化的切片，C# 版仍需 foreach 遍历缓存结果，两者都做到了零重扫。C# 基准工程在 `bench_cs/`，直接编译本机 `../DragonECS` 的源码。

## 快速上手

```odin
import odon "odon:odragon"

Pos :: struct { x, y: f32 }
Vel :: struct { x, y: f32 }

world := odon.world_create()
defer odon.world_destroy(world)

e := odon.new_entity(world)
odon.add(world, e, Pos)^ = {0, 0}
odon.add(world, e, Vel)^ = {1, 2}

mb := odon.mask_new(world)
odon.mask_inc(&mb, Pos)
odon.mask_inc(&mb, Vel)
mask := odon.mask_build(&mb)
defer odon.mask_destroy(&mask)

q := odon.query(world, &mask)
for odon.query_next(&q, &e) {
    pos := odon.get(world, e, Pos)
    vel := odon.get(world, e, Vel)
    pos.x += vel.x
    pos.y += vel.y
}
```

## 移植进度

- [x] M1 实体与池：Id_Dispenser 回收、代次睡眠位、两阶段删除、删到 0 组件自动删实体、Any_Pool vtable
- [x] M2 掩码与查询：inc/exc/any、最小池驱动、单 inc 零位检查快路径
- [x] M3 Pipeline:System 过程表、五层排序、DI-lite
- [x] M4 查询结果版本缓存（world.version 快速判定 + 按池版本细粒度失效，无关池变化不失效）、世界单例组件 `world_get/world_del`
- [x] M5 Group 稀疏集（union/intersect/except/prune)、`query1/query2/query3` 泛型糖（统一 `query_next` 过程组）、池监听器、`copy_entity`、`mask_apply` 模板

后续增补：

- [x] 池持有世界回指针：`pool_add/pool_del` 自动同步位图/组件计数/版本号，缓存池指针直用与世界 API 语义一致
- [x] 跨世界 `copy_entity_cross`、`new_entity_with` 模板创建
- [x] 基准对比工程 `bench_cs/`（对本机 DragonECS 源码）
- [x] `Tag_Pool`：零尺寸组件自动路由（`size_of(T) == 0` 即标签，无需标记接口）；无数据载荷，swap-remove 保持 dense 永远紧凑，无需 densify；支持 `tag_pool_set/toggle`；`query1/2/3` 与掩码查询对标签透明（指针出参为 nil)

DragonECS 中尚未移植的部分：`EcsGroup` 的分页非托管内存（当前是平坦 sparse 数组，语义一致仅内存布局不同）、调试元数据/JSON 调试器、多线程扩展。
