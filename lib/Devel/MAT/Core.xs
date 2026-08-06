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
