using System;
using System.Diagnostics;
using DCFApixels.DragonECS;

struct Pos : IEcsComponent { public float x, y, z; }
struct Vel : IEcsComponent { public float x, y, z; }
struct Health : IEcsComponent { public float hp; }
struct Mana : IEcsComponent { public float mp; }
struct Buff : IEcsComponent { public float t; }
struct TagA : IEcsComponent { public byte v; }

class AspPos : EcsAspect { public EcsPool<Pos> pos = Inc; }
class AspPosVel : EcsAspect { public EcsPool<Pos> pos = Inc; public EcsPool<Vel> vel = Inc; }
class AspPosVelHp : EcsAspect { public EcsPool<Pos> pos = Inc; public EcsPool<Vel> vel = Inc; public EcsPool<Health> hp = Inc; }
class AspSparse : EcsAspect { public EcsPool<Pos> pos = Inc; public EcsPool<Mana> mana = Inc; }
class AspExc : EcsAspect { public EcsPool<Pos> pos = Inc; public EcsPool<Vel> vel = Inc; public EcsPool<TagA> tag = Exc; }
class AspAny : EcsAspect { public EcsPool<Pos> pos = Inc; public EcsPool<Vel> vel = Any; public EcsPool<Mana> mana = Any; }

static class Program
{
    const int N = 1000000;
    const int CHURN = 100000;
    const int REPEATS = 5;

    static EcsWorld world;
    static int[] order;
    static float sink;
    static AspExc aspExc;
    static AspAny aspAny;
    static AspPos aspPos;
    static AspPosVel aspPosVel;
    static AspPosVelHp aspPosVelHp;
    static AspSparse aspSparse;

    static void Populate(EcsWorld w)
    {
        var poses = w.GetPool<Pos>();
        var vels = w.GetPool<Vel>();
        var hps = w.GetPool<Health>();
        var manas = w.GetPool<Mana>();
        var tags = w.GetPool<TagA>();
        for (int i = 0; i < N; i++)
        {
            int e = w.NewEntity();
            poses.Add(e) = new Pos { x = 1, y = 2, z = 3 };
            vels.Add(e) = new Vel { x = 1, y = 1, z = 1 };
            hps.Add(e) = new Health { hp = 100 };
            if (i % 10 == 0)
            {
                manas.Add(e) = new Mana { mp = 50 };
                tags.Add(e);
            }
        }
    }

    static void Measure(string name, int repeats, Action f, Action afterEach = null)
    {
        var first = TimeSpan.Zero;
        var best = TimeSpan.MaxValue;
        for (int i = 0; i < repeats; i++)
        {
            var t0 = Stopwatch.GetTimestamp();
            f();
            var d = Stopwatch.GetElapsedTime(t0);
            if (i == 0) first = d;
            if (d < best) best = d;
            afterEach?.Invoke();
        }
        Console.WriteLine("  " + name.PadRight(46)
            + "first " + first.TotalMilliseconds.ToString("F3").PadLeft(9) + " ms"
            + "   best " + best.TotalMilliseconds.ToString("F3").PadLeft(9) + " ms");
    }

    static void Main()
    {
        order = new int[N];
        {
            const int stride = 999983; // coprime with N
            int x = 0;
            for (int i = 0; i < N; i++) { order[i] = x + 1; x = (x + stride) % N; }
        }

        world = new EcsWorld();
        Measure("create 1M entities (Pos+Vel+Health, 10% +Mana+Tag)", 3,
            () => Populate(world),
            () => { world.Destroy(); world = new EcsWorld(); GC.Collect(); });

        Populate(world);
        aspExc = world.GetAspect<AspExc>();
        aspAny = world.GetAspect<AspAny>();
        aspPos = world.GetAspect<AspPos>();
        aspPosVel = world.GetAspect<AspPosVel>();
        aspPosVelHp = world.GetAspect<AspPosVelHp>();
        aspSparse = world.GetAspect<AspSparse>();

        Measure("iterate aspect (Pos) x1M", REPEATS, () =>
        {
            float sum = 0;
            foreach (var e in world.Where(out aspPos)) sum += aspPos.pos.Get(e).x;
            sink += sum;
        });

        Measure("iterate aspect (Pos+Vel, write) x1M", REPEATS, () =>
        {
            foreach (var e in world.Where(out aspPosVel))
            {
                ref var p = ref aspPosVel.pos.Get(e);
                ref var v = ref aspPosVel.vel.Get(e);
                p.x += v.x;
            }
        });

        Measure("iterate aspect (Pos+Vel+Health, write) x1M", REPEATS, () =>
        {
            foreach (var e in world.Where(out aspPosVelHp))
            {
                ref var p = ref aspPosVelHp.pos.Get(e);
                ref var v = ref aspPosVelHp.vel.Get(e);
                ref var h = ref aspPosVelHp.hp.Get(e);
                p.x += v.x * 0.0001f;
                h.hp -= 0.0001f;
            }
        });

        Measure("iterate sparse aspect (Pos+Mana) x100k", REPEATS, () =>
        {
            float sum = 0;
            foreach (var e in world.Where(out aspSparse))
                sum += aspSparse.pos.Get(e).x + aspSparse.mana.Get(e).mp;
            sink += sum;
        });

        Measure("mask query (Pos+Vel, exc Tag) x900k", REPEATS, () =>
        {
            int n = 0;
            foreach (var e in world.Where(out aspExc)) n++;
            sink += n;
        });

        Measure("mask query (Pos, any Vel|Mana) x1M", REPEATS, () =>
        {
            int n = 0;
            foreach (var e in world.Where(out aspAny)) n++;
            sink += n;
        });

        Measure("cached query repeat (exc Tag) x900k", REPEATS, () =>
        {
            int n = 0;
            foreach (var e in world.Where(out aspExc)) n += e; // sum ids: real pass
            sink += n;
        });

        var posPool = world.GetPool<Pos>();
        Measure("random access pool.Get x1M (permutation)", REPEATS, () =>
        {
            float sum = 0;
            foreach (var id in order) sum += posPool.Get(id).x;
            sink += sum;
        });

        var buffs = world.GetPool<Buff>();
        Measure("churn: add+del Buff on 100k entities", REPEATS, () =>
        {
            for (int i = 1; i <= CHURN; i++) buffs.Add(i) = new Buff { t = 0.5f };
            for (int i = 1; i <= CHURN; i++) buffs.Del(i);
        });

        Measure("delete 1M entities (+flush)", 3,
            () =>
            {
                foreach (var id in world.Entities) world.DelEntity(id);
                world.ReleaseDelEntityBufferAll();
            },
            () => Populate(world));

        Console.WriteLine("  (sink: " + sink + ")");
        world.Destroy();
    }
}
