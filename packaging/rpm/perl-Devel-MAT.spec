# RPM for Devel::MAT hybrid (Perl shell + Rust pmat-core) on Rocky/RHEL 8 (EL8).
# Built by packaging/rpm/build-rocky8.sh (not a pure %setup-from-tarball flow).

Name:           perl-Devel-MAT
Version:        %{_pmat_version}
Release:        %{_pmat_release}%{?dist}
Summary:        Perl Memory Analysis Tool with Rust pmat-core backend
License:        GPL+ or Artistic
URL:            https://github.com/hilather/pmat-rust
Source0:        pmat-rust-%{version}.tar.gz
BuildArch:      x86_64

# Runtime: base interpreter; pure-Perl CPAN deps are vendored under vendor_perl
# by the build script so the RPM is usable without a separate cpanm step.
Requires:       perl(:MODULE_COMPAT_%(eval "`%{__perl} -V:version`"; echo $version))
Requires:       perl-libs
Requires:       glibc
Requires:       libgcc
Requires:       libstdc++

Provides:       perl(Devel::MAT) = %{version}
Provides:       perl(Devel::MAT::Core) = %{version}
Provides:       pmat = %{version}
Obsoletes:      pmat < %{version}

%description
Devel::MAT (PMAT) analyzes Perl process heap dump files (.pmat).

This hybrid package includes:
  * the 0.54-compatible Perl command shell, tools, and XS
  * the Rust pmat-core dense dump parser/graph library (libpmat_core.so)
  * the Devel::MAT::Core XS bridge

Default dump backend remains the Perl oracle (PMAT_BACKEND=perl).
Force the Rust path with PMAT_BACKEND=rust (or auto when preferred).

%prep
# Tree is prepared by build-rocky8.sh into %%{_builddir}/pmat-build
# This section is a no-op when invoked via that script's rpmbuild -bb.

%build
# Performed by packaging/rpm/build-rocky8.sh before rpmbuild packages the staging tree.

%install
# Staging tree is already under %%{buildroot} when using build-rocky8.sh.

%files
%license LICENSE
%doc README.md README Changes docs/ORACLE-0.54.md docs/architecture-hybrid.md
%doc docs/parity/matrix.md docs/performance.md
%{_bindir}/pmat
%{_bindir}/pmat-cat-svpv
%{_bindir}/pmat-counts
%{_bindir}/pmat-diff
%{_bindir}/pmat-leakreport
%{_bindir}/pmat-list-orphans
%{_libdir}/libpmat_core.so*
%{perl_vendorlib}/Devel
%{perl_vendorarch}/auto/Devel
%{perl_vendorarch}/Devel
%{_datadir}/perl5/vendor_perl/auto/share
# Module::Build share_dir may land under vendorlib auto/share
%{perl_vendorlib}/auto/share
%exclude %{_localstatedir}
%exclude /usr/local

%changelog
* Wed Aug 06 2026 hilather <hilather@users.noreply.github.com> - 0.54.1-1
- Hybrid forced-Rust feature parity release (except deferred .pmat.idx)
- Package libpmat_core.so + Perl/XS + companion scripts for Rocky 8
