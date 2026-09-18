using System;
using System.Diagnostics;
using DCFApixels.DragonECS;

struct Pos : IEcsComponent { public float x, y, z; }
struct Vel : IEcsComponent { public float x, y, z; }
struct TagA : IEcsComponent { public byte v; }

class Aspect : EcsAspect
{
    public EcsPool<Pos> poses = Inc;
    public EcsPool<Vel> vels = Inc;
    public EcsPool<TagA> tagAs = Exc;
}

static class Program
{
    static void Main()
    {
        const int N = 1000000;
        var world = new EcsWorld();
        var poses = world.GetPool<Pos>();
        var vels = world.GetPool<Vel>();
        var tags = world.GetPool<TagA>();

        var sw = Stopwatch.StartNew();
        for (int i = 0; i < N; i++)
        {
            int e = world.NewEntity();
            poses.Add(e) = new Pos { x = 1, y = 2, z = 3 };
            vels.Add(e) = new Vel { x = 1, y = 1, z = 1 };
            if (i % 10 == 0) tags.Add(e);
        }
        Console.WriteLine("create 1000000 entities (2-3 comps each): " + sw.Elapsed);

        var aspect = world.GetAspect<Aspect>();
        sw.Restart();
        float sum = 0;
        foreach (var e in world.Where(out aspect))
        {
            ref var p = ref poses.Get(e);
            ref var v = ref vels.Get(e);
            sum += p.x * v.x;
        }
        Console.WriteLine("query iterate (Pos+Vel, exc TagA): " + sw.Elapsed + " (sum=" + sum + ")");

        sw.Restart();
        int n = 0;
        foreach (var e in world.Where(out aspect)) { n++; }
        Console.WriteLine("cached repeat query: " + sw.Elapsed + " (n=" + n + ")");

        sw.Restart();
        for (int i = 0; i < 100000; i++) world.DelEntity((i * 7) % N + 1);
        world.ReleaseDelEntityBufferAll();
        for (int i = 0; i < 100000; i++)
        {
            int e = world.NewEntity();
            poses.Add(e) = new Pos { x = 1, y = 2, z = 3 };
            vels.Add(e) = new Vel { x = 1, y = 1, z = 1 };
        }
        Console.WriteLine("churn 100k delete + recreate: " + sw.Elapsed);
    }
}
