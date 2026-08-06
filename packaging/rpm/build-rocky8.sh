#!/usr/bin/env bash
# Build a Rocky/RHEL 8 (EL8) RPM of Devel::MAT + prebuilt Rust pmat-core.
#
# Run on Rocky 8 (CI container or host) from the repository root:
#   ./packaging/rpm/build-rocky8.sh
#
# Environment:
#   PMAT_VERSION   default 0.54.1
#   PMAT_RELEASE   default 1
#   PMAT_DIST      default .el8
#   PMAT_RPM_SKIP_TEST=1  skip ./Build test
#
# Output: dist/rpm/perl-Devel-MAT-*.rpm  (+ libpmat_core.so copy)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

VERSION="${PMAT_VERSION:-0.54.1}"
RELEASE="${PMAT_RELEASE:-1}"
DIST_TAG="${PMAT_DIST:-.el8}"
ARCH="$(uname -m)"
LIBDIR="/usr/lib64"

OUT_DIR="${PMAT_RPM_OUT:-$ROOT/dist/rpm}"
BUILDROOT="${ROOT}/dist/stage-root"
RPMBUILD_TOP="${ROOT}/dist/rpmbuild"

export PATH="${HOME}/.cargo/bin:${ROOT}/local/bin:${HOME}/perl5/bin:${PATH:-}"
export PERL5LIB="${ROOT}/local/lib/perl5${PERL5LIB:+:$PERL5LIB}"

die() { echo "ERROR: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }

need perl
need gcc
need cargo
need rpmbuild
need curl

echo "==> Version ${VERSION}-${RELEASE}${DIST_TAG} arch=${ARCH}"

echo "==> cargo build --release (pmat-core)"
cargo build --release --manifest-path "$ROOT/rust/pmat-core/Cargo.toml"
CORE_SO="$ROOT/rust/pmat-core/target/release/libpmat_core.so"
[[ -f "$CORE_SO" ]] || die "missing $CORE_SO"

echo "==> Ensure cpanm + build deps"
if ! command -v cpanm >/dev/null 2>&1; then
  curl -sL https://cpanmin.us | perl - App::cpanminus --notest --local-lib-contained "$ROOT/local"
fi
CPANM="$(command -v cpanm)"
"$CPANM" --notest --local-lib-contained "$ROOT/local" \
  Module::Build ExtUtils::CBuilder ExtUtils::CChecker \
  Devel::MAT::Dumper Commandable Feature::Compat::Try File::ShareDir \
  Heap List::UtilsBy Module::Pluggable String::Tagged String::Tagged::Terminal \
  Struct::Dumb XS::Parse::Keyword Syntax::Keyword::Match Test2::V0 \
  Term::Table Convert::Color Convert::Color::XTerm

export PERL5LIB="${ROOT}/local/lib/perl5${PERL5LIB:+:$PERL5LIB}"

# Link against cargo output; embed system libdir as runtime rpath for the RPM.
export PMAT_CORE_LIBDIR="$ROOT/rust/pmat-core/target/release"
export PMAT_CORE_RPATH="$LIBDIR"

echo "==> Module::Build (vendor install layout)"
rm -rf "$ROOT/_build" "$ROOT/blib" "$ROOT/Build" "$ROOT/MYMETA.yml" "$ROOT/MYMETA.json" 2>/dev/null || true
perl Build.PL --installdirs=vendor
./Build
if [[ "${PMAT_RPM_SKIP_TEST:-0}" != "1" ]]; then
  ./Build test
fi

echo "==> Stage install tree at $BUILDROOT"
rm -rf "$BUILDROOT"
mkdir -p "$BUILDROOT"
./Build install --destdir="$BUILDROOT"

# Normalize bindir to /usr/bin (Module::Build vendor on some Perls uses /usr/bin already)
if [[ -d "$BUILDROOT/usr/local/bin" ]]; then
  mkdir -p "$BUILDROOT/usr/bin"
  for s in "$BUILDROOT"/usr/local/bin/*; do
    [[ -e "$s" ]] || continue
    mv -f "$s" "$BUILDROOT/usr/bin/"
  done
fi
chmod 0755 "$BUILDROOT"/usr/bin/pmat* 2>/dev/null || true

echo "==> Install libpmat_core.so -> $LIBDIR"
install -d "$BUILDROOT$LIBDIR"
install -m 0755 "$CORE_SO" "$BUILDROOT$LIBDIR/libpmat_core.so"

echo "==> Vendor CPAN runtime deps into vendor_perl (self-contained RPM)"
VENDOR_LOCAL="$ROOT/dist/vendor-local"
rm -rf "$VENDOR_LOCAL"
"$CPANM" --notest --local-lib-contained "$VENDOR_LOCAL" \
  Devel::MAT::Dumper \
  Commandable Commandable::Invocation \
  Feature::Compat::Try \
  File::ShareDir \
  Heap \
  List::UtilsBy \
  Module::Pluggable \
  String::Tagged String::Tagged::Terminal \
  Struct::Dumb \
  Syntax::Keyword::Match \
  XS::Parse::Keyword \
  Convert::Color Convert::Color::XTerm

VENDOR_LIB="$BUILDROOT/usr/share/perl5/vendor_perl"
VENDOR_ARCH="$BUILDROOT/usr/lib64/perl5/vendor_perl"
mkdir -p "$VENDOR_LIB" "$VENDOR_ARCH"

# Merge local::lib tree (pure-perl + arch-specific)
if [[ -d "$VENDOR_LOCAL/lib/perl5" ]]; then
  # Copy everything under lib/perl5 into vendorlib; arch dirs also copied to vendorarch
  cp -a "$VENDOR_LOCAL/lib/perl5/." "$VENDOR_LIB/"
  for archdir in "$VENDOR_LOCAL"/lib/perl5/*-linux* "$VENDOR_LOCAL"/lib/perl5/*-thread-multi; do
    [[ -d "$archdir" ]] || continue
    base="$(basename "$archdir")"
    # Move arch-specific out of vendorlib into vendorarch root if nested
    if [[ -d "$VENDOR_LIB/$base" ]]; then
      cp -a "$VENDOR_LIB/$base/." "$VENDOR_ARCH/"
      rm -rf "$VENDOR_LIB/$base"
    fi
  done
fi

# Docs
DOC="$BUILDROOT/usr/share/doc/perl-Devel-MAT-$VERSION"
install -d "$DOC"
for f in LICENSE README README.md Changes \
         docs/ORACLE-0.54.md docs/architecture-hybrid.md docs/parity/matrix.md; do
  [[ -f "$ROOT/$f" ]] && install -m 0644 "$ROOT/$f" "$DOC/"
done

# Drop man pages from the package payload. rpm's brp-compress renames
# Devel::MAT.3pm -> Devel::MAT.3pm.gz, which breaks a static %files list and
# also confuses GitHub Actions artifact paths (colon in filename). POD remains
# on the installed modules; user-facing docs are under /usr/share/doc.
rm -rf "$BUILDROOT"/usr/share/man "$BUILDROOT"/usr/local/share/man 2>/dev/null || true

echo "==> rpmbuild packaging"
rm -rf "$RPMBUILD_TOP"
mkdir -p "$RPMBUILD_TOP"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}
mkdir -p "$OUT_DIR"

# Snapshot staging tree as Source0
STAGE_TAR="$RPMBUILD_TOP/SOURCES/perl-Devel-MAT-stage.tar.gz"
(
  cd "$BUILDROOT"
  tar czf "$STAGE_TAR" .
)

SPEC="$RPMBUILD_TOP/SPECS/perl-Devel-MAT.spec"
cat > "$SPEC" <<EOF
Name:           perl-Devel-MAT
Version:        ${VERSION}
Release:        ${RELEASE}${DIST_TAG}
Summary:        Perl Memory Analysis Tool with Rust pmat-core backend
License:        GPL+ or Artistic
URL:            https://github.com/hilather/pmat-rust
Source0:        perl-Devel-MAT-stage.tar.gz
BuildArch:      ${ARCH}
AutoReqProv:    no

Requires:       perl-libs
Requires:       glibc
Requires:       libgcc

Provides:       perl(Devel::MAT) = ${VERSION}
Provides:       pmat = ${VERSION}

%description
Devel::MAT (PMAT) hybrid package for Rocky/RHEL 8:
Perl tools and XS plus libpmat_core.so (Rust dense dump core).

Default backend is perl (0.54 oracle). Use PMAT_BACKEND=rust for the
native path. Bundles common pure-Perl runtime dependencies under
vendor_perl so a single RPM is installable on EL8.

%prep
# no-op; payload is a prebuilt staging tree

%build
# prebuilt

%install
rm -rf %{buildroot}
mkdir -p %{buildroot}
tar -C %{buildroot} -xzf %{SOURCE0}

%files
%defattr(-,root,root,-)
EOF

# Generate %files from staged content
(
  cd "$BUILDROOT"
  find . \( -type f -o -type l \) | sed 's|^\./|/|' | sort | while read -r path; do
    if [[ "$path" == *"/LICENSE" ]]; then
      echo "%license $path"
    elif [[ "$path" == /usr/share/doc/* ]]; then
      echo "%doc $path"
    else
      echo "$path"
    fi
  done
) >> "$SPEC"

rpmbuild -bb \
  --define "_topdir $RPMBUILD_TOP" \
  "$SPEC"

find "$RPMBUILD_TOP/RPMS" -name '*.rpm' -exec cp -a {} "$OUT_DIR/" \;
cp -a "$CORE_SO" "$OUT_DIR/"

echo ""
echo "==> RPM(s) ready in $OUT_DIR"
ls -la "$OUT_DIR"/*.rpm
rpm -qip "$OUT_DIR"/perl-Devel-MAT-*.rpm | sed -n '1,25p'
echo "--- sample file list ---"
rpm -qlp "$OUT_DIR"/perl-Devel-MAT-*.rpm | head -50

echo "OK"
