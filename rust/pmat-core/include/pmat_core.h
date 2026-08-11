/* C ABI for pmat-core (Rust). Panic-safe: functions return error codes, never unwind. */
#ifndef PMAT_CORE_H
#define PMAT_CORE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct pmat_dump pmat_dump;

/* Error codes */
#define PMAT_OK              0
#define PMAT_ERR_NULL       -1
#define PMAT_ERR_IO         -2
#define PMAT_ERR_FORMAT     -3
#define PMAT_ERR_VERSION    -4
#define PMAT_ERR_OOM        -5
#define PMAT_ERR_PANIC      -6
#define PMAT_ERR_BOUNDS     -7
#define PMAT_ERR_UNSUPPORTED -8

/* Strength bits (match Devel::MAT::SV constants conceptually) */
#define PMAT_STRENGTH_STRONG   1
#define PMAT_STRENGTH_WEAK     2
#define PMAT_STRENGTH_INDIRECT 4
#define PMAT_STRENGTH_INFERRED 8

/* Load a dump file. On success *out is non-NULL. Does not modify the file.
 * Prefers a validated .pmat.idx sidecar when PMAT_IDX is enabled (default). */
int pmat_load(const char *path, pmat_dump **out);
/* Full parse only; rewrites index when enabled. */
int pmat_load_full_parse(const char *path, pmat_dump **out);
/* 1 if last successful pmat_load used a validated index. */
int pmat_last_load_used_index(void);
/* Write sidecar path for dump into buf (NUL-terminated). */
int pmat_index_path(const char *dump_path, char *buf, size_t buflen);

/* Free a dump handle (NULL-safe). */
void pmat_free(pmat_dump *dump);

/* Metadata */
uint32_t pmat_heap_count(const pmat_dump *dump);
uint32_t pmat_format_minor(const pmat_dump *dump);
uint32_t pmat_perlver(const pmat_dump *dump);
int      pmat_ithreads(const pmat_dump *dump);
uint64_t pmat_file_bytes(const pmat_dump *dump);

/* Type histogram: type codes 0..255; writes min(256, len) entries into counts. */
int pmat_type_counts(const pmat_dump *dump, uint64_t *counts, size_t len);

/* Roots: n = pmat_root_count; call pmat_root_at for each index. */
uint32_t pmat_root_count(const pmat_dump *dump);
/* name_buf receives UTF-8/bytes name (not necessarily valid UTF-8); addr out. */
int pmat_root_at(const pmat_dump *dump, uint32_t index,
                 char *name_buf, size_t name_buf_len,
                 uint64_t *addr_out);

/* Object table */
/* File-heap SV count (excludes synthetic immortals). Same as pmat_heap_count. */
/* Total objects including synthetic immortals (for addr_for_id of immortal targets). */
uint32_t pmat_object_count(const pmat_dump *dump);
/* Returns 0-based ObjectId or UINT32_MAX if missing. */
uint32_t pmat_id_for_addr(const pmat_dump *dump, uint64_t addr);
uint64_t pmat_addr_for_id(const pmat_dump *dump, uint32_t id);
uint8_t  pmat_type_for_id(const pmat_dump *dump, uint32_t id);
uint32_t pmat_refcnt_for_id(const pmat_dump *dump, uint32_t id);
uint64_t pmat_size_for_id(const pmat_dump *dump, uint32_t id);
uint64_t pmat_blessed_for_id(const pmat_dump *dump, uint32_t id);

/*
 * Batch edges (CSR slice). For object id, write up to max_edges into arrays.
 * *out_n set to total edges (may be > max_edges). Returns PMAT_OK.
 * target_ids: ObjectId or UINT32_MAX if target not in heap map.
 * strengths: PMAT_STRENGTH_* bits (usually one bit set).
 */
int pmat_outrefs_batch(const pmat_dump *dump, uint32_t id,
                       uint32_t *target_ids, uint8_t *strengths,
                       size_t max_edges, size_t *out_n);

int pmat_inrefs_batch(const pmat_dump *dump, uint32_t id,
                      uint32_t *source_ids, uint8_t *strengths,
                      size_t max_edges, size_t *out_n);

/* Total reverse/forward edge counts for instrumentation. */
uint64_t pmat_forward_edge_count(const pmat_dump *dump);
uint64_t pmat_reverse_edge_count(const pmat_dump *dump);

/*
 * Classic owned_size (%%seen walk over strong exclusive children) for every
 * heap ObjectId. out_sizes must have room for pmat_heap_count entries.
 * Returns 0 on success. Scoring walks are parallelized (PMAT_OWNED_THREADS).
 */
int pmat_owned_sizes(const pmat_dump *dump, uint64_t *out_sizes, size_t out_len);

/*
 * Top-K by owned size (score desc, addr asc). Fills out_ids/out_addrs/out_scores
 * with up to k entries; *out_n written count. Avoids full score array to Perl.
 */
int pmat_owned_topk(const pmat_dump *dump, uint32_t k,
                    uint32_t *out_ids, uint64_t *out_addrs, uint64_t *out_scores,
                    size_t *out_n);

/*
 * Multi-level largest-owned tree for counts[0..n_counts) (e.g. 5,3,2).
 * Flat rows: id, addr, score, depth, parent_index (-1 for roots).
 * *out_n = rows written (capped by max_nodes).
 */
int pmat_owned_largest_tree(const pmat_dump *dump,
                            const uint32_t *counts, size_t n_counts,
                            uint32_t *out_ids, uint64_t *out_addrs,
                            uint64_t *out_scores, uint32_t *out_depths,
                            int32_t *out_parents, size_t max_nodes,
                            size_t *out_n);

/* Last error message (thread-local / static buffer). Valid until next call. */
const char *pmat_last_error(void);

/* Library version string */
const char *pmat_core_version(void);

#ifdef __cplusplus
}
#endif

#endif /* PMAT_CORE_H */
