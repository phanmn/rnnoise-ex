/*
 * rnnoise_nif.c - Erlang/Elixir NIF bindings for xiph/rnnoise.
 *
 * Audio convention (matches examples/rnnoise_demo.c):
 *   - mono, 48000 Hz, signed 16-bit little-endian PCM
 *   - 480 samples (960 bytes) per frame
 *   - samples are fed to rnnoise as floats in the int16 range (no normalization)
 *
 * Model handling: the trained weights live in a binary blob that is fetched and
 * cached at runtime (see Rnnoise.Model). The blob is loaded into a *model*
 * resource via load_model/1; each denoiser *state* created from it keeps a
 * reference to that model resource so the blob memory stays valid for as long
 * as any state using it is alive.
 */

#include <stdio.h>
#include <string.h>
#include <math.h>
#include <stdint.h>

#include "erl_nif.h"
#include "rnnoise.h"

#define FRAME_SIZE 480
#define FRAME_BYTES (FRAME_SIZE * (int)sizeof(int16_t))

typedef struct {
    ErlNifResourceType *model_type;
    ErlNifResourceType *state_type;
} priv_t;

typedef struct {
    RNNModel *model;
} model_res_t;

typedef struct {
    DenoiseState *st;       /* owned, freed in dtor */
    model_res_t *model_res; /* kept reference, released in dtor */
} state_res_t;

static ERL_NIF_TERM atom_ok;
static ERL_NIF_TERM atom_error;
static ERL_NIF_TERM atom_open_failed;
static ERL_NIF_TERM atom_load_failed;

static void model_dtor(ErlNifEnv *env, void *obj) {
    (void)env;
    model_res_t *m = (model_res_t *)obj;
    if (m->model != NULL) {
        rnnoise_model_free(m->model);
        m->model = NULL;
    }
}

static void state_dtor(ErlNifEnv *env, void *obj) {
    state_res_t *s = (state_res_t *)obj;
    if (s->st != NULL) {
        rnnoise_destroy(s->st);
        s->st = NULL;
    }
    if (s->model_res != NULL) {
        enif_release_resource(s->model_res);
        s->model_res = NULL;
    }
    (void)env;
}

static int open_types(ErlNifEnv *env, priv_t *pd, ErlNifResourceFlags flags) {
    pd->model_type =
        enif_open_resource_type(env, NULL, "rnnoise_model", model_dtor, flags, NULL);
    pd->state_type =
        enif_open_resource_type(env, NULL, "rnnoise_state", state_dtor, flags, NULL);
    return pd->model_type != NULL && pd->state_type != NULL;
}

static int load(ErlNifEnv *env, void **priv_data, ERL_NIF_TERM load_info) {
    (void)load_info;
    priv_t *pd = enif_alloc(sizeof(priv_t));
    if (pd == NULL) return -1;
    if (!open_types(env, pd, ERL_NIF_RT_CREATE)) {
        enif_free(pd);
        return -1;
    }
    atom_ok = enif_make_atom(env, "ok");
    atom_error = enif_make_atom(env, "error");
    atom_open_failed = enif_make_atom(env, "open_failed");
    atom_load_failed = enif_make_atom(env, "load_failed");
    *priv_data = pd;
    return 0;
}

static int upgrade(ErlNifEnv *env, void **priv_data, void **old_priv_data,
                   ERL_NIF_TERM load_info) {
    (void)old_priv_data;
    (void)load_info;
    priv_t *pd = enif_alloc(sizeof(priv_t));
    if (pd == NULL) return -1;
    if (!open_types(env, pd, ERL_NIF_RT_TAKEOVER)) {
        enif_free(pd);
        return -1;
    }
    atom_ok = enif_make_atom(env, "ok");
    atom_error = enif_make_atom(env, "error");
    atom_open_failed = enif_make_atom(env, "open_failed");
    atom_load_failed = enif_make_atom(env, "load_failed");
    *priv_data = pd;
    return 0;
}

static void unload(ErlNifEnv *env, void *priv_data) {
    (void)env;
    if (priv_data != NULL) enif_free(priv_data);
}

static ERL_NIF_TERM make_error(ErlNifEnv *env, ERL_NIF_TERM reason) {
    return enif_make_tuple2(env, atom_error, reason);
}

/* load_model(path_binary) -> {:ok, model_ref} | {:error, reason}
 *
 * We open and null-check the file ourselves: rnnoise_model_from_filename
 * dereferences a NULL FILE* on a missing file. rnnoise_model_from_file copies
 * the blob into its own buffer, so we can close our handle right after. */
static ERL_NIF_TERM nif_load_model(ErlNifEnv *env, int argc,
                                   const ERL_NIF_TERM argv[]) {
    (void)argc;
    priv_t *pd = (priv_t *)enif_priv_data(env);
    ErlNifBinary pathb;
    char path[4096];

    if (!enif_inspect_binary(env, argv[0], &pathb) || pathb.size == 0 ||
        pathb.size >= sizeof(path))
        return enif_make_badarg(env);
    memcpy(path, pathb.data, pathb.size);
    path[pathb.size] = '\0';

    FILE *f = fopen(path, "rb");
    if (f == NULL) return make_error(env, atom_open_failed);
    RNNModel *model = rnnoise_model_from_file(f);
    fclose(f); /* rnnoise_model_from_file copied the blob into its own buffer */
    if (model == NULL) return make_error(env, atom_load_failed);

    model_res_t *m = enif_alloc_resource(pd->model_type, sizeof(model_res_t));
    if (m == NULL) {
        rnnoise_model_free(model);
        return enif_make_badarg(env);
    }
    m->model = model;
    ERL_NIF_TERM term = enif_make_resource(env, m);
    enif_release_resource(m);
    return enif_make_tuple2(env, atom_ok, term);
}

/* create(model_ref) -> state_ref */
static ERL_NIF_TERM nif_create(ErlNifEnv *env, int argc,
                               const ERL_NIF_TERM argv[]) {
    (void)argc;
    priv_t *pd = (priv_t *)enif_priv_data(env);
    model_res_t *m;

    if (!enif_get_resource(env, argv[0], pd->model_type, (void **)&m))
        return enif_make_badarg(env);

    state_res_t *s = enif_alloc_resource(pd->state_type, sizeof(state_res_t));
    if (s == NULL) return enif_make_badarg(env);
    s->st = NULL;
    s->model_res = NULL;

    s->st = rnnoise_create(m->model);
    if (s->st == NULL) {
        enif_release_resource(s); /* dtor is safe with NULL fields */
        return enif_make_badarg(env);
    }
    enif_keep_resource(m);
    s->model_res = m;

    ERL_NIF_TERM term = enif_make_resource(env, s);
    enif_release_resource(s);
    return term;
}

/* frame_size() -> 480 */
static ERL_NIF_TERM nif_frame_size(ErlNifEnv *env, int argc,
                                   const ERL_NIF_TERM argv[]) {
    (void)argc;
    (void)argv;
    return enif_make_int(env, rnnoise_get_frame_size());
}

static inline int16_t clamp_to_s16(float v) {
    long r = lrintf(v);
    if (r > 32767) return 32767;
    if (r < -32768) return -32768;
    return (int16_t)r;
}

/* process_frame(state, pcm_960_bytes) -> {vad_prob :: float, denoised_pcm} */
static ERL_NIF_TERM nif_process_frame(ErlNifEnv *env, int argc,
                                      const ERL_NIF_TERM argv[]) {
    (void)argc;
    priv_t *pd = (priv_t *)enif_priv_data(env);
    state_res_t *s;
    ErlNifBinary in;

    if (!enif_get_resource(env, argv[0], pd->state_type, (void **)&s))
        return enif_make_badarg(env);
    if (!enif_inspect_binary(env, argv[1], &in) || in.size != (size_t)FRAME_BYTES)
        return enif_make_badarg(env);

    const int16_t *pin = (const int16_t *)in.data;
    float x[FRAME_SIZE];
    for (int i = 0; i < FRAME_SIZE; i++) x[i] = (float)pin[i];

    float vad = rnnoise_process_frame(s->st, x, x);

    ERL_NIF_TERM out_term;
    unsigned char *out = enif_make_new_binary(env, FRAME_BYTES, &out_term);
    int16_t *pout = (int16_t *)out;
    for (int i = 0; i < FRAME_SIZE; i++) pout[i] = clamp_to_s16(x[i]);

    return enif_make_tuple2(env, enif_make_double(env, (double)vad), out_term);
}

/* process_buffer(state, pcm) -> denoised_pcm  (size must be a multiple of 960)
 * Runs on a dirty CPU scheduler so large buffers don't block the VM. */
static ERL_NIF_TERM nif_process_buffer(ErlNifEnv *env, int argc,
                                       const ERL_NIF_TERM argv[]) {
    (void)argc;
    priv_t *pd = (priv_t *)enif_priv_data(env);
    state_res_t *s;
    ErlNifBinary in;

    if (!enif_get_resource(env, argv[0], pd->state_type, (void **)&s))
        return enif_make_badarg(env);
    if (!enif_inspect_binary(env, argv[1], &in) || (in.size % FRAME_BYTES) != 0)
        return enif_make_badarg(env);

    size_t nframes = in.size / FRAME_BYTES;
    ERL_NIF_TERM out_term;
    unsigned char *out = enif_make_new_binary(env, in.size, &out_term);
    const int16_t *pin = (const int16_t *)in.data;
    int16_t *pout = (int16_t *)out;

    float x[FRAME_SIZE];
    for (size_t fr = 0; fr < nframes; fr++) {
        const int16_t *src = pin + fr * FRAME_SIZE;
        int16_t *dst = pout + fr * FRAME_SIZE;
        for (int i = 0; i < FRAME_SIZE; i++) x[i] = (float)src[i];
        rnnoise_process_frame(s->st, x, x);
        for (int i = 0; i < FRAME_SIZE; i++) dst[i] = clamp_to_s16(x[i]);
    }
    return out_term;
}

static ErlNifFunc nif_funcs[] = {
    {"load_model", 1, nif_load_model, 0},
    {"create", 1, nif_create, 0},
    {"frame_size", 0, nif_frame_size, 0},
    {"process_frame", 2, nif_process_frame, 0},
    {"process_buffer", 2, nif_process_buffer, ERL_NIF_DIRTY_JOB_CPU_BOUND},
};

ERL_NIF_INIT(Elixir.Rnnoise.Nif, nif_funcs, load, NULL, upgrade, unload)
