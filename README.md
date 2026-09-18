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

## 基准对比

测试方法：两边跑**同一组场景**(100 万实体，组件 Pos/Vel/Health + 10% Mana/Tag),Odin 侧 `-o:speed`,C# 侧 .NET 10 Release 直接编译本机 `../DragonECS` 源码（benchmark 工程见 `bench_cs/`，场景逐行镜像 `examples/bench/`)。每项取 5 次运行最优值；"first" 为首次运行（DragonECS 的 Where 执行器首次调用含构建成本，之后自动缓存结果 span)。

| 场景 | ODragonECS | DragonECS (C#) 首次 | DragonECS (C#) 缓存后 |
|---|---|---|---|
| 创建 100 万实体（3~5 组件） | 64 ms | 75 ms | 51 ms |
| 创建 100 万实体（容量预留） | **26 ms** | – | 25 ms |
| 迭代 1 组件 ×100 万 | **1.25 ms** | 16.0 ms | 2.22 ms |
| 迭代 2 组件（写）×100 万 | 2.02 ms | 9.2 ms | **2.00 ms** |
| 迭代 3 组件（写）×100 万 | **2.19 ms** | 10.3 ms | 3.01 ms |
| 稀疏迭代（Pos+Mana)×10 万 | **0.66 ms** | 8.7 ms | 0.60 ms |
| 掩码查询 Pos+Vel exc Tag ×90 万 | **3.5 ms**(`query_uncached` 每次全扫) | 11.0 ms | 0.20 ms(遍历缓存 span) |
| 掩码查询 Pos, any Vel\|Mana ×100 万 | **2.9 ms**(每次全扫) | 8.2 ms | 0.03 ms(遍历缓存 span) |
| `query()` 自动缓存重复 ×90 万 | **1.25 ms**(逐元素迭代器) | 2.0 ms | 0.24 ms |
| `query_cached` 重复+遍历切片 ×90 万 | **0.06 ms** | – | 0.24 ms |
| 随机访问 pool_get ×100 万(全排列打乱) | **3.57 ms** | 7.2 ms | 4.53 ms |
| churn:增删 Buff ×10 万 | 0.67 ms | 3.5 ms | **0.69 ms** |
| 删除 100 万实体(+flush) | **42.3 ms** | 84.2 ms | 56.1 ms |

口径与结论说明:

- **缓存语义**:`query()` 现在与 DragonECS 的 `Where` 一样**自动走版本缓存**(首次扫描建缓存,之后命中直接迭代物化结果);需要保证实时全扫时用 `query_uncached`。极限吞吐用 `query_cached` 拿切片直接遍历(56µs/90 万,可向量化)。
- **创建**:DragonECS 默认路径略快(64 vs 51ms);两边都给容量预留后**打平**(26 vs 25ms)。Odin 侧预留 = `world_create(initial_capacity = N)` + `pool_reserve`(池用高水位计数直写,跳过 append)。
- **热路径写法**:系统应在 init 时缓存池指针,用 `pool_set/pool_add/pool_del` 直写(池自动同步世界位图);组件 ID 注册表带锁,是冷路径。
- Odin 列是**保留边界检查**的数字;`-no-bounds-check` 还能再省 10~15%。
- C# 侧 GC 影响:创建场景前加了 `GC.Collect()` 降噪;Odin 侧无预热效应。

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
- [x] `Group` 分页 sparse：64 实体/页、页空即释放（非零计数方案，替代 DragonECS 的空页共享+XOR 校验和），内存占用正比于实际成员而非世界容量
- [x] 全局世界注册表：`world_by_id` / `resolve_handle` 让裸 `Entity_Long` 可解析回世界（对应 DragonECS 的静态世界表 + entlong 解析）
- [x] 组件生命周期钩子 `pool_set_lifecycle(on_init/on_del)`（对应 `IEcsComponentLifecycle`):on_del 在移除前拿到组件指针，可释放自有资源；池销毁时对存活组件补跑
- [x] Group 自动剔除死实体：`group_create` 自动注册到世界，flush 时同步（对应 `EcsGroup.OnReleaseDelEntityBuffer_Internal`)
- [x] `has()` 直读世界位图（一次内存访问，不再走 vtable 进池）
- [x] 线程安全：全局组件注册表与世界注册表加互斥锁（修掉了并发首次注册的 map 数据竞争）；热循环标 `#no_bounds_check`

DragonECS 中尚未移植的部分：调试元数据/JSON 调试器（建议永不做，Odin 里应走编译期方案）、多线程 System 调度（DragonECS 主仓本身也不含，在扩展包中）。
