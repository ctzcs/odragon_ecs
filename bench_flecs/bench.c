// flecs benchmark mirroring odragon_ecs/examples/bench scenarios.
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include "flecs.h"

#define N 1000000
#define CHURN 100000
#define REPEATS 5

typedef struct { float x, y, z; } Pos;
typedef struct { float x, y, z; } Vel;
typedef struct { float hp; } Health;
typedef struct { float mp; } Mana;
typedef struct { float t; } Buff;

static ecs_id_t POS, VEL, HP, MP, BUFF;
static ecs_entity_t TAGA;
static float sink;
static int *order;
static ecs_entity_t *entities; // actual ids (flecs ids are not 1..N)

static double now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000.0 + ts.tv_nsec / 1e6;
}

static void register_components(ecs_world_t *w) {
    POS = ecs_component_init(w, &(ecs_component_desc_t){ .entity = ecs_entity(w, { .name = "Pos" }), .type = { .size = sizeof(Pos), .alignment = _Alignof(Pos) } });
    VEL = ecs_component_init(w, &(ecs_component_desc_t){ .entity = ecs_entity(w, { .name = "Vel" }), .type = { .size = sizeof(Vel), .alignment = _Alignof(Vel) } });
    HP  = ecs_component_init(w, &(ecs_component_desc_t){ .entity = ecs_entity(w, { .name = "Health" }), .type = { .size = sizeof(Health), .alignment = _Alignof(Health) } });
    MP  = ecs_component_init(w, &(ecs_component_desc_t){ .entity = ecs_entity(w, { .name = "Mana" }), .type = { .size = sizeof(Mana), .alignment = _Alignof(Mana) } });
    BUFF = ecs_component_init(w, &(ecs_component_desc_t){ .entity = ecs_entity(w, { .name = "Buff" }), .type = { .size = sizeof(Buff), .alignment = _Alignof(Buff) } });
    TAGA = ecs_entity(w, { .name = "TagA" });
}

static void populate(ecs_world_t *w) {
    for (int i = 0; i < N; i++) {
        ecs_entity_t e = ecs_new(w);
        ecs_set_id(w, e, POS, sizeof(Pos), &(Pos){1, 2, 3});
        ecs_set_id(w, e, VEL, sizeof(Vel), &(Vel){1, 1, 1});
        ecs_set_id(w, e, HP, sizeof(Health), &(Health){100});
        if (i % 10 == 0) {
            ecs_set_id(w, e, MP, sizeof(Mana), &(Mana){50});
            ecs_add_id(w, e, TAGA);
        }
        entities[i] = e;
    }
}

#define MEASURE(name, repeats, body) do { \
    double best = 1e30; \
    for (int r = 0; r < (repeats); r++) { \
        double t0 = now_ms(); \
        { body } \
        double d = now_ms() - t0; \
        if (d < best) best = d; \
    } \
    printf("  %-46s %9.3f ms\n", name, best); \
} while (0)

static void measure_create(int reserved) {
    double best = 1e30;
    for (int r = 0; r < 3; r++) {
        ecs_world_t *w = ecs_init();
        register_components(w);
        double t0 = now_ms();
        populate(w);
        double d = now_ms() - t0;
        if (d < best) best = d;
        ecs_fini(w);
    }
    printf("  %-46s %9.3f ms\n", reserved ? "create 1M (reserved)" : "create 1M entities (Pos+Vel+Health, 10% +Mana+Tag)", best);
}

int main(void) {
    order = malloc(sizeof(int) * N);
    entities = malloc(sizeof(ecs_entity_t) * N);
    {
        const int stride = 999983;
        int x = 0;
        for (int i = 0; i < N; i++) { order[i] = x; x = (x + stride) % N; }
    }

    measure_create(0);

    ecs_world_t *w = ecs_init();
    register_components(w);
    populate(w);

    // iterate Pos
    MEASURE("iterate (Pos) x1M", REPEATS, {
        ecs_query_t *q = ecs_query(w, { .terms = {{ .id = POS }} });
        float sum = 0;
        ecs_iter_t it = ecs_query_iter(w, q);
        while (ecs_query_next(&it)) {
            Pos *p = ecs_field(&it, Pos, 0);
            for (int i = 0; i < it.count; i++) sum += p[i].x;
        }
        sink += sum;
        ecs_query_fini(q);
    });

    // iterate Pos+Vel write
    MEASURE("iterate (Pos+Vel, write) x1M", REPEATS, {
        ecs_query_t *q = ecs_query(w, { .terms = {{ .id = POS }, { .id = VEL }} });
        ecs_iter_t it = ecs_query_iter(w, q);
        while (ecs_query_next(&it)) {
            Pos *p = ecs_field(&it, Pos, 0);
            Vel *v = ecs_field(&it, Vel, 1);
            for (int i = 0; i < it.count; i++) p[i].x += v[i].x;
        }
        ecs_query_fini(q);
    });

    // iterate Pos+Vel+Health write
    MEASURE("iterate (Pos+Vel+Health, write) x1M", REPEATS, {
        ecs_query_t *q = ecs_query(w, { .terms = {{ .id = POS }, { .id = VEL }, { .id = HP }} });
        ecs_iter_t it = ecs_query_iter(w, q);
        while (ecs_query_next(&it)) {
            Pos *p = ecs_field(&it, Pos, 0);
            Vel *v = ecs_field(&it, Vel, 1);
            Health *h = ecs_field(&it, Health, 2);
            for (int i = 0; i < it.count; i++) { p[i].x += v[i].x * 0.0001f; h[i].hp -= 0.0001f; }
        }
        ecs_query_fini(q);
    });

    // sparse Pos+Mana (100k)
    MEASURE("iterate sparse (Pos+Mana) x100k", REPEATS, {
        ecs_query_t *q = ecs_query(w, { .terms = {{ .id = POS }, { .id = MP }} });
        float sum = 0;
        ecs_iter_t it = ecs_query_iter(w, q);
        while (ecs_query_next(&it)) {
            Pos *p = ecs_field(&it, Pos, 0);
            Mana *m = ecs_field(&it, Mana, 1);
            for (int i = 0; i < it.count; i++) sum += p[i].x + m[i].mp;
        }
        sink += sum;
        ecs_query_fini(q);
    });

    // mask Pos+Vel, exc Tag (900k) — sum entity ids to force a real pass
    MEASURE("query (Pos+Vel, exc Tag) x900k", REPEATS, {
        ecs_query_t *q = ecs_query(w, { .terms = {{ .id = POS }, { .id = VEL }, { .id = TAGA, .oper = EcsNot }} });
        long n = 0;
        ecs_iter_t it = ecs_query_iter(w, q);
        while (ecs_query_next(&it)) {
            for (int i = 0; i < it.count; i++) n += (long)it.entities[i];
        }
        sink += (float)n;
        ecs_query_fini(q);
    });

    // random access get x1M
    MEASURE("random access get x1M (permutation)", REPEATS, {
        float sum = 0;
        for (int i = 0; i < N; i++) {
            const Pos *p = ecs_get_id(w, entities[order[i]], POS);
            sum += p->x;
        }
        sink += sum;
    });

    // churn add+remove Buff x100k
    MEASURE("churn: add+remove Buff on 100k entities", REPEATS, {
        for (int i = 0; i < CHURN; i++) ecs_set_id(w, entities[i], BUFF, sizeof(Buff), &(Buff){0.5f});
        for (int i = 0; i < CHURN; i++) ecs_remove_id(w, entities[i], BUFF);
    });

    // delete 1M entities
    {
        double best = 1e30;
        for (int r = 0; r < 3; r++) {
            double t0 = now_ms();
            for (int i = 0; i < N; i++) ecs_delete(w, entities[i]);
            double d = now_ms() - t0;
            if (d < best) best = d;
            populate(w); // repopulate, untimed
        }
        printf("  %-46s %9.3f ms\n", "delete 1M entities", best);
    }

    printf("  (sink: %.1f)\n", sink);
    ecs_fini(w);
    free(order);
    free(entities);
    return 0;
}
