/* XS bridge to pmat-core C ABI. Panic-safe: Rust never unwinds into Perl. */

#define PERL_NO_GET_CONTEXT
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

/* Declarations match rust/pmat-core/include/pmat_core.h */
typedef struct pmat_dump pmat_dump;

extern int pmat_load(const char *path, pmat_dump **out);
extern int pmat_load_full_parse(const char *path, pmat_dump **out);
extern int pmat_last_load_used_index(void);
extern int pmat_index_path(const char *dump_path, char *buf, size_t buflen);
extern void pmat_free(pmat_dump *dump);
extern uint32_t pmat_heap_count(const pmat_dump *dump);
extern uint32_t pmat_object_count(const pmat_dump *dump);
extern uint32_t pmat_format_minor(const pmat_dump *dump);
extern uint32_t pmat_perlver(const pmat_dump *dump);
extern int pmat_ithreads(const pmat_dump *dump);
extern uint64_t pmat_file_bytes(const pmat_dump *dump);
extern int pmat_type_counts(const pmat_dump *dump, uint64_t *counts, size_t len);
extern uint32_t pmat_root_count(const pmat_dump *dump);
extern int pmat_root_at(const pmat_dump *dump, uint32_t index,
                        char *name_buf, size_t name_buf_len, uint64_t *addr_out);
extern uint32_t pmat_id_for_addr(const pmat_dump *dump, uint64_t addr);
extern uint64_t pmat_addr_for_id(const pmat_dump *dump, uint32_t id);
extern uint8_t pmat_type_for_id(const pmat_dump *dump, uint32_t id);
extern uint32_t pmat_refcnt_for_id(const pmat_dump *dump, uint32_t id);
extern uint64_t pmat_size_for_id(const pmat_dump *dump, uint32_t id);
extern uint64_t pmat_blessed_for_id(const pmat_dump *dump, uint32_t id);
extern int pmat_owned_sizes(const pmat_dump *dump, uint64_t *out_sizes, size_t out_len);
extern int pmat_owned_topk(const pmat_dump *dump, uint32_t k,
    uint32_t *out_ids, uint64_t *out_addrs, uint64_t *out_scores, size_t *out_n);
extern int pmat_owned_largest_tree(const pmat_dump *dump,
    const uint32_t *counts, size_t n_counts,
    uint32_t *out_ids, uint64_t *out_addrs, uint64_t *out_scores,
    uint32_t *out_depths, int32_t *out_parents, size_t max_nodes, size_t *out_n);
extern int pmat_outrefs_batch(const pmat_dump *dump, uint32_t id,
                              uint32_t *target_ids, uint8_t *strengths,
                              size_t max_edges, size_t *out_n);
extern int pmat_inrefs_batch(const pmat_dump *dump, uint32_t id,
                             uint32_t *source_ids, uint8_t *strengths,
                             size_t max_edges, size_t *out_n);
extern uint64_t pmat_forward_edge_count(const pmat_dump *dump);
extern uint64_t pmat_reverse_edge_count(const pmat_dump *dump);
extern const char *pmat_last_error(void);
extern const char *pmat_core_version(void);

/* ---- Payload accessors (declared) ---- */
extern uint32_t pmat_stack_count(const pmat_dump *dump);
extern int pmat_stack_at(const pmat_dump *dump, uint32_t index, uint64_t *addr_out);
extern uint32_t pmat_mortal_count(const pmat_dump *dump);
extern int pmat_mortal_at(const pmat_dump *dump, uint32_t index, uint64_t *addr_out);
extern uint32_t pmat_obj_header_len(const pmat_dump *dump, uint32_t id);
extern int pmat_obj_header_copy(const pmat_dump *dump, uint32_t id, uint8_t *buf, size_t buflen);
extern uint32_t pmat_obj_n_ptrs(const pmat_dump *dump, uint32_t id);
extern uint64_t pmat_obj_ptr_at(const pmat_dump *dump, uint32_t id, uint32_t index);
extern uint32_t pmat_obj_n_strs(const pmat_dump *dump, uint32_t id);
extern uint32_t pmat_obj_str_len(const pmat_dump *dump, uint32_t id, uint32_t index);
extern int pmat_obj_str_copy(const pmat_dump *dump, uint32_t id, uint32_t index, uint8_t *buf, size_t buflen);
extern uint8_t pmat_obj_array_flags(const pmat_dump *dump, uint32_t id);
extern uint32_t pmat_obj_n_elems(const pmat_dump *dump, uint32_t id);
extern uint64_t pmat_obj_elem_at(const pmat_dump *dump, uint32_t id, uint32_t index);
extern uint32_t pmat_obj_n_hash(const pmat_dump *dump, uint32_t id);
extern uint32_t pmat_obj_hash_key_len(const pmat_dump *dump, uint32_t id, uint32_t index);
extern int pmat_obj_hash_key_copy(const pmat_dump *dump, uint32_t id, uint32_t index, uint8_t *buf, size_t buflen);
extern uint64_t pmat_obj_hash_hek(const pmat_dump *dump, uint32_t id, uint32_t index);
extern uint64_t pmat_obj_hash_val(const pmat_dump *dump, uint32_t id, uint32_t index);
extern uint64_t pmat_obj_code_padnames_at(const pmat_dump *dump, uint32_t id);
extern uint32_t pmat_obj_n_code_consts(const pmat_dump *dump, uint32_t id);
extern uint64_t pmat_obj_code_const_at(const pmat_dump *dump, uint32_t id, uint32_t index);
extern uint32_t pmat_obj_n_code_gvs(const pmat_dump *dump, uint32_t id);
extern uint64_t pmat_obj_code_gv_at(const pmat_dump *dump, uint32_t id, uint32_t index);
extern uint32_t pmat_obj_n_code_pads(const pmat_dump *dump, uint32_t id);
extern int pmat_obj_code_pad_at(const pmat_dump *dump, uint32_t id, uint32_t index, uint32_t *depth_out, uint64_t *addr_out);
extern uint32_t pmat_obj_n_code_padnames(const pmat_dump *dump, uint32_t id);
extern int pmat_obj_code_padname_at(const pmat_dump *dump, uint32_t id, uint32_t index,
  uint32_t *padix_out, uint16_t *flags_out, uint64_t *ourstash_out, uint64_t *fieldix_out,
  uint64_t *fieldstash_out, uint8_t *name_buf, size_t name_buflen, uint32_t *name_len_out);
extern uint32_t pmat_obj_n_magic(const pmat_dump *dump, uint32_t id);
extern int pmat_obj_magic_at(const pmat_dump *dump, uint32_t id, uint32_t index,
  uint8_t *type_out, uint8_t *flags_out, uint64_t *obj_out, uint64_t *ptr_out, uint64_t *vtbl_out);
extern uint32_t pmat_obj_stash_name_len(const pmat_dump *dump, uint32_t id);
extern int pmat_obj_stash_name_copy(const pmat_dump *dump, uint32_t id, uint8_t *buf, size_t buflen);
extern uint32_t pmat_obj_n_mro(const pmat_dump *dump, uint32_t id);
extern uint64_t pmat_obj_mro_at(const pmat_dump *dump, uint32_t id, uint32_t index);
extern uint32_t pmat_obj_n_annotations(const pmat_dump *dump, uint32_t id);
extern int pmat_obj_annotation_at(const pmat_dump *dump, uint32_t id, uint32_t index,
  uint64_t *addr_out, uint8_t *name_buf, size_t name_buflen, uint32_t *name_len_out);
extern uint32_t pmat_obj_n_saved(const pmat_dump *dump, uint32_t id);
extern int pmat_obj_saved_at(const pmat_dump *dump, uint32_t id, uint32_t index,
  uint8_t *kind_out, uint64_t *idx_out, uint64_t *addr_out);
extern uint32_t pmat_obj_n_code_constix(const pmat_dump *dump, uint32_t id);
extern uint64_t pmat_obj_code_constix_at(const pmat_dump *dump, uint32_t id, uint32_t index);
extern uint32_t pmat_obj_n_code_gvix(const pmat_dump *dump, uint32_t id);
extern uint64_t pmat_obj_code_gvix_at(const pmat_dump *dump, uint32_t id, uint32_t index);

extern uint32_t pmat_context_count(const pmat_dump *dump);
extern uint8_t pmat_context_type(const pmat_dump *dump, uint32_t index);
extern uint32_t pmat_context_common_header_len(const pmat_dump *dump, uint32_t index);
extern int pmat_context_common_header_copy(const pmat_dump *dump, uint32_t index, uint8_t *buf, size_t buflen);
extern uint32_t pmat_context_n_common_strs(const pmat_dump *dump, uint32_t index);
extern uint32_t pmat_context_common_str_len(const pmat_dump *dump, uint32_t index, uint32_t sidx);
extern int pmat_context_common_str_copy(const pmat_dump *dump, uint32_t index, uint32_t sidx, uint8_t *buf, size_t buflen);
extern uint32_t pmat_context_n_type_ptrs(const pmat_dump *dump, uint32_t index);
extern uint64_t pmat_context_type_ptr_at(const pmat_dump *dump, uint32_t index, uint32_t pidx);
extern uint32_t pmat_context_type_header_len(const pmat_dump *dump, uint32_t index);
extern int pmat_context_type_header_copy(const pmat_dump *dump, uint32_t index, uint8_t *buf, size_t buflen);
extern uint32_t pmat_obj_n_class_fields(const pmat_dump *dump, uint32_t id);
extern int pmat_obj_class_field_at(const pmat_dump *dump, uint32_t id, uint32_t index,
  uint64_t *fieldix_out, uint8_t *name_buf, size_t name_buflen, uint32_t *name_len_out);




typedef struct {
  pmat_dump *dump;
} pmat_handle;

static void free_handle(pmat_handle *h) {
  if (!h) return;
  if (h->dump) pmat_free(h->dump);
  Safefree(h);
}

MODULE = Devel::MAT::Core          PACKAGE = Devel::MAT::Core

int
_xs_available()
  CODE:
    RETVAL = 1;
  OUTPUT:
    RETVAL

SV *
_xs_load(path)
    const char *path
  PREINIT:
    pmat_dump *dump = NULL;
    pmat_handle *h;
    int rc;
  CODE:
    rc = pmat_load(path, &dump);
    if (rc != 0 || !dump) {
      const char *err = pmat_last_error();
      croak("pmat_load failed (%d): %s", rc, err ? err : "unknown");
    }
    Newx(h, 1, pmat_handle);
    h->dump = dump;
    RETVAL = newSV(0);
    sv_setref_pv(RETVAL, "Devel::MAT::Core::Handle", (void *)h);
  OUTPUT:
    RETVAL

SV *
_xs_load_full_parse(path)
    const char *path
  PREINIT:
    pmat_dump *dump = NULL;
    pmat_handle *h;
    int rc;
  CODE:
    rc = pmat_load_full_parse(path, &dump);
    if (rc != 0 || !dump) {
      const char *err = pmat_last_error();
      croak("pmat_load_full_parse failed (%d): %s", rc, err ? err : "unknown");
    }
    Newx(h, 1, pmat_handle);
    h->dump = dump;
    RETVAL = newSV(0);
    sv_setref_pv(RETVAL, "Devel::MAT::Core::Handle", (void *)h);
  OUTPUT:
    RETVAL

int
last_load_used_index()
  CODE:
    RETVAL = pmat_last_load_used_index();
  OUTPUT:
    RETVAL

SV *
index_path_for(path)
    const char *path
  PREINIT:
    char buf[4096];
    int rc;
  CODE:
    rc = pmat_index_path(path, buf, sizeof(buf));
    if (rc != 0)
      croak("pmat_index_path failed: %s", pmat_last_error());
    RETVAL = newSVpv(buf, 0);
  OUTPUT:
    RETVAL

void
DESTROY(self)
    SV *self
  PREINIT:
    pmat_handle *h;
  CODE:
    /* Method may be called as Devel::MAT::Core::Handle::DESTROY */
    if (!SvROK(self)) XSRETURN_EMPTY;
    h = INT2PTR(pmat_handle *, SvIV((SV *)SvRV(self)));
    if (h) free_handle(h);
    sv_setiv((SV *)SvRV(self), 0);

UV
heap_count(self)
    SV *self
  PREINIT:
    pmat_handle *h;
  CODE:
    h = INT2PTR(pmat_handle *, SvIV((SV *)SvRV(self)));
    RETVAL = pmat_heap_count(h->dump);
  OUTPUT:
    RETVAL

UV
object_count(self)
    SV *self
  PREINIT:
    pmat_handle *h;
  CODE:
    h = INT2PTR(pmat_handle *, SvIV((SV *)SvRV(self)));
    RETVAL = pmat_object_count(h->dump);
  OUTPUT:
    RETVAL

UV
addr_for_id(self, id)
    SV *self
    UV id
  PREINIT:
    pmat_handle *h;
  CODE:
    h = INT2PTR(pmat_handle *, SvIV((SV *)SvRV(self)));
    RETVAL = (UV)pmat_addr_for_id(h->dump, (uint32_t)id);
  OUTPUT:
    RETVAL

UV
format_minor(self)
    SV *self
  PREINIT:
    pmat_handle *h;
  CODE:
    h = INT2PTR(pmat_handle *, SvIV((SV *)SvRV(self)));
    RETVAL = pmat_format_minor(h->dump);
  OUTPUT:
    RETVAL

UV
perlver(self)
    SV *self
  PREINIT:
    pmat_handle *h;
  CODE:
    h = INT2PTR(pmat_handle *, SvIV((SV *)SvRV(self)));
    RETVAL = pmat_perlver(h->dump);
  OUTPUT:
    RETVAL

bool
ithreads(self)
    SV *self
  PREINIT:
    pmat_handle *h;
  CODE:
    h = INT2PTR(pmat_handle *, SvIV((SV *)SvRV(self)));
    RETVAL = pmat_ithreads(h->dump) ? 1 : 0;
  OUTPUT:
    RETVAL

UV
file_bytes(self)
    SV *self
  PREINIT:
    pmat_handle *h;
  CODE:
    h = INT2PTR(pmat_handle *, SvIV((SV *)SvRV(self)));
    RETVAL = (UV)pmat_file_bytes(h->dump);
  OUTPUT:
    RETVAL

UV
forward_edge_count(self)
    SV *self
  PREINIT:
    pmat_handle *h;
  CODE:
    h = INT2PTR(pmat_handle *, SvIV((SV *)SvRV(self)));
    RETVAL = (UV)pmat_forward_edge_count(h->dump);
  OUTPUT:
    RETVAL

UV
reverse_edge_count(self)
    SV *self
  PREINIT:
    pmat_handle *h;
  CODE:
    h = INT2PTR(pmat_handle *, SvIV((SV *)SvRV(self)));
    RETVAL = (UV)pmat_reverse_edge_count(h->dump);
  OUTPUT:
    RETVAL

void
type_counts(self)
    SV *self
  PREINIT:
    pmat_handle *h;
    uint64_t counts[256];
    int i;
    HV *hv;
  PPCODE:
    h = INT2PTR(pmat_handle *, SvIV((SV *)SvRV(self)));
    memset(counts, 0, sizeof(counts));
    if (pmat_type_counts(h->dump, counts, 256) != 0)
      croak("pmat_type_counts failed: %s", pmat_last_error());
    hv = newHV();
    for (i = 0; i < 256; i++) {
      if (counts[i]) {
        char key[16];
        int klen = snprintf(key, sizeof(key), "%d", i);
        hv_store(hv, key, klen, newSVuv((UV)counts[i]), 0);
      }
    }
    PUSHs(sv_2mortal(newRV_noinc((SV *)hv)));

void
roots(self)
    SV *self
  PREINIT:
    pmat_handle *h;
    uint32_t n, i;
    AV *av;
  PPCODE:
    h = INT2PTR(pmat_handle *, SvIV((SV *)SvRV(self)));
    n = pmat_root_count(h->dump);
    av = newAV();
    for (i = 0; i < n; i++) {
      char name[512];
      uint64_t addr = 0;
      HV *rh;
      if (pmat_root_at(h->dump, i, name, sizeof(name), &addr) != 0)
        croak("pmat_root_at failed: %s", pmat_last_error());
      rh = newHV();
      hv_stores(rh, "name", newSVpv(name, 0));
      hv_stores(rh, "addr", newSVuv((UV)addr));
      av_push(av, newRV_noinc((SV *)rh));
    }
    PUSHs(sv_2mortal(newRV_noinc((SV *)av)));

void
object_at(self, id)
    SV *self
    UV id
  PREINIT:
    pmat_handle *h;
    AV *row;
  PPCODE:
    /* Single object meta: [addr, type, refcnt, size, blessed]
     * Accepts synthetic immortal ids (id < object_count). */
    h = INT2PTR(pmat_handle *, SvIV((SV *)SvRV(self)));
    if (id >= pmat_object_count(h->dump))
      XSRETURN_UNDEF;
    row = newAV();
    av_push(row, newSVuv((UV)pmat_addr_for_id(h->dump, (uint32_t)id)));
    av_push(row, newSVuv((UV)pmat_type_for_id(h->dump, (uint32_t)id)));
    av_push(row, newSVuv((UV)pmat_refcnt_for_id(h->dump, (uint32_t)id)));
    av_push(row, newSVuv((UV)pmat_size_for_id(h->dump, (uint32_t)id)));
    av_push(row, newSVuv((UV)pmat_blessed_for_id(h->dump, (uint32_t)id)));
    PUSHs(sv_2mortal(newRV_noinc((SV *)row)));

void
outrefs_batch(self, id)
    SV *self
    UV id
  PREINIT:
    pmat_handle *h;
    size_t n = 0, i;
    uint32_t *targets = NULL;
    uint8_t *strengths = NULL;
    AV *av;
  PPCODE:
    h = INT2PTR(pmat_handle *, SvIV((SV *)SvRV(self)));
    if (pmat_outrefs_batch(h->dump, (uint32_t)id, NULL, NULL, 0, &n) != 0)
      croak("pmat_outrefs_batch size failed: %s", pmat_last_error());
    av = newAV();
    if (n) {
      Newx(targets, n, uint32_t);
      Newx(strengths, n, uint8_t);
      if (pmat_outrefs_batch(h->dump, (uint32_t)id, targets, strengths, n, &n) != 0) {
        Safefree(targets);
        Safefree(strengths);
        croak("pmat_outrefs_batch failed: %s", pmat_last_error());
      }
      for (i = 0; i < n; i++) {
        AV *row = newAV();
        av_push(row, newSVuv((UV)targets[i]));
        av_push(row, newSVuv((UV)strengths[i]));
        av_push(av, newRV_noinc((SV *)row));
      }
      Safefree(targets);
      Safefree(strengths);
    }
    PUSHs(sv_2mortal(newRV_noinc((SV *)av)));

void
inrefs_batch(self, id)
    SV *self
    UV id
  PREINIT:
    pmat_handle *h;
    size_t n = 0, i;
    uint32_t *sources = NULL;
    uint8_t *strengths = NULL;
    AV *av;
  PPCODE:
    h = INT2PTR(pmat_handle *, SvIV((SV *)SvRV(self)));
    if (pmat_inrefs_batch(h->dump, (uint32_t)id, NULL, NULL, 0, &n) != 0)
      croak("pmat_inrefs_batch size failed: %s", pmat_last_error());
    av = newAV();
    if (n) {
      Newx(sources, n, uint32_t);
      Newx(strengths, n, uint8_t);
      if (pmat_inrefs_batch(h->dump, (uint32_t)id, sources, strengths, n, &n) != 0) {
        Safefree(sources);
        Safefree(strengths);
        croak("pmat_inrefs_batch failed: %s", pmat_last_error());
      }
      for (i = 0; i < n; i++) {
        AV *row = newAV();
        av_push(row, newSVuv((UV)sources[i]));
        av_push(row, newSVuv((UV)strengths[i]));
        av_push(av, newRV_noinc((SV *)row));
      }
      Safefree(sources);
      Safefree(strengths);
    }
    PUSHs(sv_2mortal(newRV_noinc((SV *)av)));

void
owned_sizes(self)
    SV *self
  PREINIT:
    pmat_handle *h;
    uint32_t n, i;
    uint64_t *sizes = NULL;
    AV *av;
  PPCODE:
    h = INT2PTR(pmat_handle *, SvIV((SV *)SvRV(self)));
    n = pmat_heap_count(h->dump);
    av = newAV();
    if (n) {
      Newx(sizes, n, uint64_t);
      if (pmat_owned_sizes(h->dump, sizes, (size_t)n) != 0) {
        Safefree(sizes);
        croak("pmat_owned_sizes failed: %s", pmat_last_error());
      }
      av_extend(av, n - 1);
      for (i = 0; i < n; i++)
        av_store(av, i, newSVuv((UV)sizes[i]));
      Safefree(sizes);
    }
    PUSHs(sv_2mortal(newRV_noinc((SV *)av)));

void
owned_topk(self, k)
    SV *self
    UV k
  PREINIT:
    pmat_handle *h;
    uint32_t *ids = NULL;
    uint64_t *addrs = NULL;
    uint64_t *scores = NULL;
    size_t got = 0;
    size_t i;
    UV kk;
  PPCODE:
    h = INT2PTR(pmat_handle *, SvIV((SV *)SvRV(self)));
    kk = k;
    if (kk == 0)
      XSRETURN_EMPTY;
    Newx(ids, kk, uint32_t);
    Newx(addrs, kk, uint64_t);
    Newx(scores, kk, uint64_t);
    if (pmat_owned_topk(h->dump, (uint32_t)kk, ids, addrs, scores, &got) != 0) {
      Safefree(ids);
      Safefree(addrs);
      Safefree(scores);
      croak("pmat_owned_topk failed: %s", pmat_last_error());
    }
    EXTEND(SP, (IV)got);
    for (i = 0; i < got; i++) {
      AV *row = newAV();
      av_push(row, newSVuv((UV)ids[i]));
      av_push(row, newSVuv((UV)addrs[i]));
      av_push(row, newSVuv((UV)scores[i]));
      PUSHs(sv_2mortal(newRV_noinc((SV *)row)));
    }
    Safefree(ids);
    Safefree(addrs);
    Safefree(scores);

void
owned_largest_tree(self, counts_ref)
    SV *self
    SV *counts_ref
  PREINIT:
    pmat_handle *h;
    AV *cav;
    uint32_t *counts = NULL;
    uint32_t *ids = NULL;
    uint64_t *addrs = NULL;
    uint64_t *scores = NULL;
    uint32_t *depths = NULL;
    int32_t *parents = NULL;
    size_t n_counts = 0;
    size_t max_nodes = 0;
    size_t got = 0;
    size_t i;
    size_t prod;
    SSize_t ai;
    SSize_t alen;
  PPCODE:
    h = INT2PTR(pmat_handle *, SvIV((SV *)SvRV(self)));
    if (!SvROK(counts_ref) || SvTYPE(SvRV(counts_ref)) != SVt_PVAV)
      croak("owned_largest_tree: counts must be arrayref");
    cav = (AV *)SvRV(counts_ref);
    alen = av_len(cav) + 1;
    if (alen <= 0)
      XSRETURN_EMPTY;
    n_counts = (size_t)alen;
    Newx(counts, n_counts, uint32_t);
    prod = 1;
    max_nodes = 0;
    for (ai = 0; ai < alen; ai++) {
      SV **svp = av_fetch(cav, ai, 0);
      UV c = svp && *svp ? SvUV(*svp) : 0;
      counts[ai] = (uint32_t)c;
      if (c == 0)
        break;
      if (prod > 100000 / (size_t)c)
        prod = 100000;
      else
        prod *= (size_t)c;
      max_nodes += prod;
    }
    if (max_nodes < 16)
      max_nodes = 16;
    if (max_nodes > 100000)
      max_nodes = 100000;
    Newx(ids, max_nodes, uint32_t);
    Newx(addrs, max_nodes, uint64_t);
    Newx(scores, max_nodes, uint64_t);
    Newx(depths, max_nodes, uint32_t);
    Newx(parents, max_nodes, int32_t);
    if (pmat_owned_largest_tree(h->dump, counts, n_counts,
          ids, addrs, scores, depths, parents, max_nodes, &got) != 0) {
      Safefree(counts);
      Safefree(ids);
      Safefree(addrs);
      Safefree(scores);
      Safefree(depths);
      Safefree(parents);
      croak("pmat_owned_largest_tree failed: %s", pmat_last_error());
    }
    EXTEND(SP, (IV)got);
    for (i = 0; i < got; i++) {
      AV *row = newAV();
      av_push(row, newSVuv((UV)ids[i]));
      av_push(row, newSVuv((UV)addrs[i]));
      av_push(row, newSVuv((UV)scores[i]));
      av_push(row, newSVuv((UV)depths[i]));
      av_push(row, newSViv((IV)parents[i]));
      PUSHs(sv_2mortal(newRV_noinc((SV *)row)));
    }
    Safefree(counts);
    Safefree(ids);
    Safefree(addrs);
    Safefree(scores);
    Safefree(depths);
    Safefree(parents);

UV
id_for_addr(self, addr)
    SV *self
    UV addr
  PREINIT:
    pmat_handle *h;
  CODE:
    h = INT2PTR(pmat_handle *, SvIV((SV *)SvRV(self)));
    RETVAL = pmat_id_for_addr(h->dump, (uint64_t)addr);
  OUTPUT:
    RETVAL

const char *
core_version()
  CODE:
    RETVAL = pmat_core_version();
  OUTPUT:
    RETVAL

void
stack(self)
    SV *self
  PREINIT:
    pmat_handle *h;
    uint32_t n, i;
    AV *av;
  PPCODE:
    h = INT2PTR(pmat_handle *, SvIV((SV *)SvRV(self)));
    n = pmat_stack_count(h->dump);
    av = newAV();
    for (i = 0; i < n; i++) {
      uint64_t addr = 0;
      if (pmat_stack_at(h->dump, i, &addr) == 0)
        av_push(av, newSVuv((UV)addr));
    }
    PUSHs(sv_2mortal(newRV_noinc((SV *)av)));

void
mortals(self)
    SV *self
  PREINIT:
    pmat_handle *h;
    uint32_t n, i;
    AV *av;
  PPCODE:
    h = INT2PTR(pmat_handle *, SvIV((SV *)SvRV(self)));
    n = pmat_mortal_count(h->dump);
    av = newAV();
    for (i = 0; i < n; i++) {
      uint64_t addr = 0;
      if (pmat_mortal_at(h->dump, i, &addr) == 0)
        av_push(av, newSVuv((UV)addr));
    }
    PUSHs(sv_2mortal(newRV_noinc((SV *)av)));

void
object_detail(self, id)
    SV *self
    UV id
  PREINIT:
    pmat_handle *h;
    HV *hv;
    AV *av;
    uint32_t n, i;
    uint32_t hlen;
  PPCODE:
    h = INT2PTR(pmat_handle *, SvIV((SV *)SvRV(self)));
    if (id >= pmat_object_count(h->dump))
      XSRETURN_UNDEF;
    hv = newHV();
    hv_stores(hv, "type", newSVuv((UV)pmat_type_for_id(h->dump, (uint32_t)id)));
    hv_stores(hv, "addr", newSVuv((UV)pmat_addr_for_id(h->dump, (uint32_t)id)));
    hv_stores(hv, "refcnt", newSVuv((UV)pmat_refcnt_for_id(h->dump, (uint32_t)id)));
    hv_stores(hv, "size", newSVuv((UV)pmat_size_for_id(h->dump, (uint32_t)id)));
    hv_stores(hv, "blessed", newSVuv((UV)pmat_blessed_for_id(h->dump, (uint32_t)id)));

    hlen = pmat_obj_header_len(h->dump, (uint32_t)id);
    if (hlen) {
      SV *hdr = newSV(hlen);
      SvPOK_on(hdr);
      SvCUR_set(hdr, hlen);
      pmat_obj_header_copy(h->dump, (uint32_t)id, (uint8_t *)SvPVX(hdr), hlen);
      hv_stores(hv, "header", hdr);
    } else {
      hv_stores(hv, "header", newSVpvn("", 0));
    }

    n = pmat_obj_n_ptrs(h->dump, (uint32_t)id);
    av = newAV();
    for (i = 0; i < n; i++)
      av_push(av, newSVuv((UV)pmat_obj_ptr_at(h->dump, (uint32_t)id, i)));
    hv_stores(hv, "ptrs", newRV_noinc((SV *)av));

    n = pmat_obj_n_strs(h->dump, (uint32_t)id);
    av = newAV();
    for (i = 0; i < n; i++) {
      uint32_t sl = pmat_obj_str_len(h->dump, (uint32_t)id, i);
      SV *s = newSV(sl ? sl : 1);
      SvPOK_on(s);
      SvCUR_set(s, sl);
      if (sl)
        pmat_obj_str_copy(h->dump, (uint32_t)id, i, (uint8_t *)SvPVX(s), sl);
      av_push(av, s);
    }
    hv_stores(hv, "strs", newRV_noinc((SV *)av));

    hv_stores(hv, "array_flags", newSVuv((UV)pmat_obj_array_flags(h->dump, (uint32_t)id)));
    n = pmat_obj_n_elems(h->dump, (uint32_t)id);
    av = newAV();
    for (i = 0; i < n; i++)
      av_push(av, newSVuv((UV)pmat_obj_elem_at(h->dump, (uint32_t)id, i)));
    hv_stores(hv, "elems", newRV_noinc((SV *)av));

    n = pmat_obj_n_hash(h->dump, (uint32_t)id);
    {
      HV *hh = newHV();
      for (i = 0; i < n; i++) {
        uint32_t kl = pmat_obj_hash_key_len(h->dump, (uint32_t)id, i);
        char *kbuf;
        Newx(kbuf, kl ? kl : 1, char);
        if (kl)
          pmat_obj_hash_key_copy(h->dump, (uint32_t)id, i, (uint8_t *)kbuf, kl);
        {
          AV *row = newAV();
          av_push(row, newSVuv((UV)pmat_obj_hash_hek(h->dump, (uint32_t)id, i)));
          av_push(row, newSVuv((UV)pmat_obj_hash_val(h->dump, (uint32_t)id, i)));
          hv_store(hh, kbuf, (I32)kl, newRV_noinc((SV *)row), 0);
        }
        Safefree(kbuf);
      }
      hv_stores(hv, "hash_values", newRV_noinc((SV *)hh));
    }

    hv_stores(hv, "code_padnames_at", newSVuv((UV)pmat_obj_code_padnames_at(h->dump, (uint32_t)id)));
    n = pmat_obj_n_code_consts(h->dump, (uint32_t)id);
    av = newAV();
    for (i = 0; i < n; i++)
      av_push(av, newSVuv((UV)pmat_obj_code_const_at(h->dump, (uint32_t)id, i)));
    hv_stores(hv, "code_consts", newRV_noinc((SV *)av));

    n = pmat_obj_n_code_gvs(h->dump, (uint32_t)id);
    av = newAV();
    for (i = 0; i < n; i++)
      av_push(av, newSVuv((UV)pmat_obj_code_gv_at(h->dump, (uint32_t)id, i)));
    hv_stores(hv, "code_gvs", newRV_noinc((SV *)av));

    n = pmat_obj_n_code_pads(h->dump, (uint32_t)id);
    av = newAV();
    for (i = 0; i < n; i++) {
      uint32_t depth = 0;
      uint64_t addr = 0;
      AV *row = newAV();
      pmat_obj_code_pad_at(h->dump, (uint32_t)id, i, &depth, &addr);
      av_push(row, newSVuv((UV)depth));
      av_push(row, newSVuv((UV)addr));
      av_push(av, newRV_noinc((SV *)row));
    }
    hv_stores(hv, "code_pads", newRV_noinc((SV *)av));

    n = pmat_obj_n_code_padnames(h->dump, (uint32_t)id);
    av = newAV();
    for (i = 0; i < n; i++) {
      uint32_t padix = 0, nlen = 0;
      uint16_t flags = 0;
      uint64_t ourstash = 0, fieldix = 0, fieldstash = 0;
      char namebuf[4096];
      HV *pn = newHV();
      pmat_obj_code_padname_at(h->dump, (uint32_t)id, i, &padix, &flags, &ourstash,
        &fieldix, &fieldstash, (uint8_t *)namebuf, sizeof(namebuf), &nlen);
      if (nlen > sizeof(namebuf)) nlen = sizeof(namebuf);
      hv_stores(pn, "padix", newSVuv(padix));
      hv_stores(pn, "flags", newSVuv(flags));
      hv_stores(pn, "ourstash", newSVuv((UV)ourstash));
      hv_stores(pn, "fieldix", newSVuv((UV)fieldix));
      hv_stores(pn, "fieldstash", newSVuv((UV)fieldstash));
      hv_stores(pn, "name", newSVpvn(namebuf, nlen));
      av_push(av, newRV_noinc((SV *)pn));
    }
    hv_stores(hv, "code_padnames", newRV_noinc((SV *)av));

    n = pmat_obj_n_magic(h->dump, (uint32_t)id);
    av = newAV();
    for (i = 0; i < n; i++) {
      uint8_t t = 0, f = 0;
      uint64_t o = 0, p = 0, v = 0;
      AV *row = newAV();
      pmat_obj_magic_at(h->dump, (uint32_t)id, i, &t, &f, &o, &p, &v);
      av_push(row, newSVuv(t));
      av_push(row, newSVuv(f));
      av_push(row, newSVuv((UV)o));
      av_push(row, newSVuv((UV)p));
      av_push(row, newSVuv((UV)v));
      av_push(av, newRV_noinc((SV *)row));
    }
    hv_stores(hv, "magic", newRV_noinc((SV *)av));

    {
      uint32_t sn = pmat_obj_stash_name_len(h->dump, (uint32_t)id);
      if (sn) {
        SV *s = newSV(sn);
        SvPOK_on(s);
        SvCUR_set(s, sn);
        pmat_obj_stash_name_copy(h->dump, (uint32_t)id, (uint8_t *)SvPVX(s), sn);
        hv_stores(hv, "stash_name", s);
      }
    }

    n = pmat_obj_n_mro(h->dump, (uint32_t)id);
    av = newAV();
    for (i = 0; i < n; i++)
      av_push(av, newSVuv((UV)pmat_obj_mro_at(h->dump, (uint32_t)id, i)));
    hv_stores(hv, "mro_ptrs", newRV_noinc((SV *)av));

    n = pmat_obj_n_annotations(h->dump, (uint32_t)id);
    av = newAV();
    for (i = 0; i < n; i++) {
      uint64_t addr = 0;
      uint32_t nlen = 0;
      char namebuf[1024];
      AV *row = newAV();
      pmat_obj_annotation_at(h->dump, (uint32_t)id, i, &addr, (uint8_t *)namebuf, sizeof(namebuf), &nlen);
      if (nlen > sizeof(namebuf)) nlen = sizeof(namebuf);
      av_push(row, newSVuv((UV)addr));
      av_push(row, newSVpvn(namebuf, nlen));
      av_push(av, newRV_noinc((SV *)row));
    }
    hv_stores(hv, "annotations", newRV_noinc((SV *)av));

    n = pmat_obj_n_saved(h->dump, (uint32_t)id);
    av = newAV();
    for (i = 0; i < n; i++) {
      uint8_t kind = 0;
      uint64_t idx = 0, addr = 0;
      AV *row = newAV();
      pmat_obj_saved_at(h->dump, (uint32_t)id, i, &kind, &idx, &addr);
      av_push(row, newSVuv(kind));
      av_push(row, newSVuv((UV)idx));
      av_push(row, newSVuv((UV)addr));
      av_push(av, newRV_noinc((SV *)row));
    }
    hv_stores(hv, "saved", newRV_noinc((SV *)av));

    n = pmat_obj_n_code_constix(h->dump, (uint32_t)id);
    av = newAV();
    for (i = 0; i < n; i++)
      av_push(av, newSVuv((UV)pmat_obj_code_constix_at(h->dump, (uint32_t)id, i)));
    hv_stores(hv, "code_constix", newRV_noinc((SV *)av));

    n = pmat_obj_n_code_gvix(h->dump, (uint32_t)id);
    av = newAV();
    for (i = 0; i < n; i++)
      av_push(av, newSVuv((UV)pmat_obj_code_gvix_at(h->dump, (uint32_t)id, i)));
    hv_stores(hv, "code_gvix", newRV_noinc((SV *)av));

    n = pmat_obj_n_class_fields(h->dump, (uint32_t)id);
    av = newAV();
    for (i = 0; i < n; i++) {
      uint64_t fieldix = 0;
      uint32_t nlen = 0;
      char namebuf[1024];
      AV *row = newAV();
      pmat_obj_class_field_at(h->dump, (uint32_t)id, i, &fieldix, (uint8_t *)namebuf, sizeof(namebuf), &nlen);
      if (nlen > sizeof(namebuf)) nlen = sizeof(namebuf);
      av_push(row, newSVuv((UV)fieldix));
      av_push(row, newSVpvn(namebuf, nlen));
      av_push(av, newRV_noinc((SV *)row));
    }
    hv_stores(hv, "class_fields", newRV_noinc((SV *)av));

    PUSHs(sv_2mortal(newRV_noinc((SV *)hv)));


void
contexts_raw(self)
    SV *self
  PREINIT:
    pmat_handle *h;
    uint32_t n, i, j;
    AV *av;
  PPCODE:
    h = INT2PTR(pmat_handle *, SvIV((SV *)SvRV(self)));
    n = pmat_context_count(h->dump);
    av = newAV();
    for (i = 0; i < n; i++) {
      HV *ch = newHV();
      uint32_t hlen, sn, pn, thlen;
      AV *strs, *ptrs;
      hv_stores(ch, "type", newSVuv((UV)pmat_context_type(h->dump, i)));
      hlen = pmat_context_common_header_len(h->dump, i);
      if (hlen) {
        SV *hdr = newSV(hlen);
        SvPOK_on(hdr); SvCUR_set(hdr, hlen);
        pmat_context_common_header_copy(h->dump, i, (uint8_t *)SvPVX(hdr), hlen);
        hv_stores(ch, "common_header", hdr);
      } else {
        hv_stores(ch, "common_header", newSVpvn("", 0));
      }
      sn = pmat_context_n_common_strs(h->dump, i);
      strs = newAV();
      for (j = 0; j < sn; j++) {
        uint32_t sl = pmat_context_common_str_len(h->dump, i, j);
        SV *s = newSV(sl ? sl : 1);
        SvPOK_on(s); SvCUR_set(s, sl);
        if (sl) pmat_context_common_str_copy(h->dump, i, j, (uint8_t *)SvPVX(s), sl);
        av_push(strs, s);
      }
      hv_stores(ch, "common_strs", newRV_noinc((SV *)strs));
      thlen = pmat_context_type_header_len(h->dump, i);
      if (thlen) {
        SV *th = newSV(thlen);
        SvPOK_on(th); SvCUR_set(th, thlen);
        pmat_context_type_header_copy(h->dump, i, (uint8_t *)SvPVX(th), thlen);
        hv_stores(ch, "type_header", th);
      } else {
        hv_stores(ch, "type_header", newSVpvn("", 0));
      }
      pn = pmat_context_n_type_ptrs(h->dump, i);
      ptrs = newAV();
      for (j = 0; j < pn; j++)
        av_push(ptrs, newSVuv((UV)pmat_context_type_ptr_at(h->dump, i, j)));
      hv_stores(ch, "type_ptrs", newRV_noinc((SV *)ptrs));
      av_push(av, newRV_noinc((SV *)ch));
    }
    PUSHs(sv_2mortal(newRV_noinc((SV *)av)));
