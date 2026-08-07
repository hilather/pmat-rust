#!/usr/bin/perl
# PAR-001: backend selection; forced modes never mis-attribute fallback as Rust.

use v5.14;
use warnings;

use Test2::V0;
use FindBin;
use File::Spec;
use lib File::Spec->catdir( $FindBin::Bin, '..', 'blib', 'lib' );
use lib File::Spec->catdir( $FindBin::Bin, '..', 'blib', 'arch' );
use lib File::Spec->catdir( $FindBin::Bin, '..', 'local', 'lib', 'perl5' );

require Devel::MAT::Backend;

# Invalid value croaks
{
   local $ENV{PMAT_BACKEND} = 'nope';
   like(
      dies { Devel::MAT::Backend->mode },
      qr/Invalid PMAT_BACKEND/,
      'invalid PMAT_BACKEND rejected'
   );
}

# Forced perl always resolves to perl
{
   local $ENV{PMAT_BACKEND} = 'perl';
   is( Devel::MAT::Backend->mode, 'perl', 'mode perl' );
   is( Devel::MAT::Backend->resolve, 'perl', 'resolve perl' );
   ok( !Devel::MAT::Backend->used_rust, 'not used_rust' );
   ok( !Devel::MAT::Backend->fell_back, 'no fallback on forced perl' );
}

# Forced rust: either succeeds or hard-fails (never silent perl success)
{
   local $ENV{PMAT_BACKEND} = 'rust';
   is( Devel::MAT::Backend->mode, 'rust', 'mode rust' );
   if ( Devel::MAT::Backend->rust_available ) {
      is( Devel::MAT::Backend->resolve, 'rust', 'resolve rust when available' );
      ok( Devel::MAT::Backend->used_rust, 'used_rust true' );
      ok( !Devel::MAT::Backend->fell_back, 'no fallback on forced rust success' );
   }
   else {
      like(
         dies { Devel::MAT::Backend->resolve },
         qr/PMAT_BACKEND=rust/,
         'forced rust croaks when core unavailable (no silent perl)'
      );
   }
}

# Auto may fall back, and must record it
{
   local $ENV{PMAT_BACKEND} = 'auto';
   my $resolved = Devel::MAT::Backend->resolve;
   ok( $resolved eq 'perl' || $resolved eq 'rust', "auto resolves to $resolved" );
   if ( $resolved eq 'perl' && !Devel::MAT::Backend->rust_available ) {
      ok( Devel::MAT::Backend->fell_back, 'auto fallback recorded' );
      ok( !Devel::MAT::Backend->used_rust, 'fallback is not used_rust' );
   }
   if ( $resolved eq 'rust' ) {
      ok( Devel::MAT::Backend->used_rust, 'auto chose rust' );
      ok( !Devel::MAT::Backend->fell_back, 'no fallback when rust used' );
   }
}

# Default without env is rust (post-parity promotion)
{
   delete local $ENV{PMAT_BACKEND};
   is( Devel::MAT::Backend->mode, 'rust', 'default mode is rust' );
}

done_testing;
