#!/usr/bin/perl
# Smoke-test the bench CLIs end-to-end on the smallest tiers.

use v5.14;
use warnings;

use Test2::V0;

use FindBin;
use File::Spec;
use File::Temp qw( tempdir );

my $root = File::Spec->catdir( $FindBin::Bin, '..' );
my $gen  = File::Spec->catfile( $root, 'bench', 'gen-fixture' );
my $run  = File::Spec->catfile( $root, 'bench', 'run-bench' );

plan skip_all => 'bench scripts missing' unless -x $gen || -f $gen;
plan skip_all => "Devel::MAT::Dumper not installed"
   unless eval { require Devel::MAT::Dumper; 1 };
plan skip_all => "Devel::MAT not built"
   unless -e File::Spec->catfile( $root, 'blib', 'arch', 'auto', 'Devel', 'MAT', 'MAT.so' )
       || -e File::Spec->catfile( $root, 'blib', 'arch', 'auto', 'Devel', 'MAT', 'MAT.bs' )
       || eval {
            require lib;
            lib->import(
               File::Spec->catdir( $root, 'blib', 'lib' ),
               File::Spec->catdir( $root, 'blib', 'arch' ),
               File::Spec->catdir( $root, 'local', 'lib', 'perl5' ),
            );
            require Devel::MAT;
            1;
          };

my $tmpdir = tempdir( CLEANUP => 1 );
my $perl   = $^X;

# gen-fixture --list
{
   my $out = qx{$perl \Q$gen\E --list 2>&1};
   is( $? >> 8, 0, 'gen-fixture --list exits 0' ) or diag $out;
   like( $out, qr/micro/, 'lists micro tier' );
   like( $out, qr/huge/,  'lists huge tier' );
}

# Generate micro only into temp dir
{
   my $out = qx{$perl \Q$gen\E --size=micro --dir=\Q$tmpdir\E --force 2>&1};
   is( $? >> 8, 0, 'gen-fixture micro exits 0' ) or diag $out;
   my @pmats = glob File::Spec->catfile( $tmpdir, 'micro-*.pmat' );
   ok( @pmats, 'created micro-*.pmat' ) or diag $out;
}

# run-bench on that dir
{
   my $json = File::Spec->catfile( $tmpdir, 'out.json' );
   my $out = qx{$perl \Q$run\E --size=micro --dir=\Q$tmpdir\E --json=\Q$json\E --phases=load,inrefs,count 2>&1};
   is( $? >> 8, 0, 'run-bench micro exits 0' ) or diag $out;
   ok( -f $json, 'wrote JSON results' );
   like( $out, qr/phase/i, 'prints report header' );
   like( $out, qr/load/i,  'mentions load phase' );
}

# largest / largest --owned command path phases
{
   my $json = File::Spec->catfile( $tmpdir, 'largest.json' );
   my $out = qx{$perl \Q$run\E --size=micro --dir=\Q$tmpdir\E --json=\Q$json\E --phases=load,largest,largest_owned --largest-counts=3,2,1 2>&1};
   is( $? >> 8, 0, 'run-bench largest phases exit 0' ) or diag $out;
   like( $out, qr/largest_owned/i, 'reports largest_owned phase' );
   ok( -f $json, 'wrote largest JSON' );
   if ( open my $fh, '<', $json ) {
      local $/;
      my $raw = <$fh>;
      like( $raw, qr/"largest_owned"/, 'JSON includes largest_owned' );
      like( $raw, qr/"largest"/, 'JSON includes largest' );
   }
}

# Synthetic tiny huge tier via size token
{
   my $out = qx{$perl \Q$gen\E --size=huge --target-bytes=512K --dir=\Q$tmpdir\E --force 2>&1};
   is( $? >> 8, 0, 'gen-fixture huge 512K exits 0' ) or diag $out;
}

done_testing;
