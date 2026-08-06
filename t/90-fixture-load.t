#!/usr/bin/perl
# Functional tests against generated micro fixtures: load, tools, markers.

use v5.14;
use warnings;

use Test2::V0;

use FindBin;
use File::Spec;
use File::Temp qw( tempdir );

use lib File::Spec->catdir( $FindBin::Bin, '..', 'bench', 'lib' );
use lib File::Spec->catdir( $FindBin::Bin, '..', 'blib', 'lib' );
use lib File::Spec->catdir( $FindBin::Bin, '..', 'blib', 'arch' );
use lib File::Spec->catdir( $FindBin::Bin, '..', 'local', 'lib', 'perl5' );

BEGIN {
   plan skip_all => "Devel::MAT::Dumper not installed"
      unless eval { require Devel::MAT::Dumper; 1 };
   plan skip_all => "Devel::MAT not built (run perl Build.PL && ./Build)"
      unless eval { require Devel::MAT; 1 };
}

use PMAT::Bench::Tiers qw( resolve_tiers );
use PMAT::Bench::Fixture;
use PMAT::Bench::Runner;

my $tmpdir = tempdir( CLEANUP => 1 );
my ( $tier ) = resolve_tiers('micro');

my ( $path, $meta );
ok(
   lives {
      ( $path, $meta ) = PMAT::Bench::Fixture->ensure(
         $tier,
         dir       => $tmpdir,
         force     => 1,
         count_svs => 1,
      );
   },
   'generate micro fixture'
) or diag $@;

ok( -f $path, "fixture exists at $path" );
cmp_ok( $meta->{bytes}, '>', 100_000, 'fixture is non-trivial size' );
cmp_ok( $meta->{heap_svs} // 0, '>=', $tier->{expect_svs_min} // 1,
   'heap SV count meets micro floor' );

my $pmat;
ok(
   lives { $pmat = Devel::MAT->load($path) },
   'load fixture'
) or diag $@;

my $df = $pmat->dumpfile;
my $heap_n = scalar $df->heap;
cmp_ok( $heap_n, '>', 0, 'heap has SVs' );
ok( $df->defstash, 'has defstash root' ) if $df->can('defstash');

# Fixture marker: package global built by generator
{
   my $root = eval { $pmat->find_symbol('$PMAT_BENCH_ROOT') };
   # Dumper captures our $PMAT_BENCH_ROOT as a package scalar REF or the
   # array itself depending on how it was stored; also try via stash.
   if ( !$root ) {
      $root = eval { $pmat->find_symbol('@PMAT_BENCH_ROOT') };
   }
   # Generator stores `our $PMAT_BENCH_ROOT = \@root` — a REF SV.
   ok( $root, 'fixture marker $PMAT_BENCH_ROOT present' )
      or diag "symbols may differ; heap_svs=$heap_n";
}

# Core tools initialise without dying
ok( lives { $pmat->load_tool('Inrefs') }, 'Inrefs tool' ) or diag $@;
ok( lives { $pmat->load_tool('Count') },  'Count tool' )  or diag $@;
ok( lives { $pmat->load_tool('Sizes') },  'Sizes tool' )  or diag $@;

# structure_size on a few SVs
{
   my $checked = 0;
   for my $sv ( $df->heap ) {
      next if $sv->immortal;
      my $sz = $sv->structure_size;
      cmp_ok( $sz, '>', 0, 'structure_size > 0' );
      last if ++$checked >= 5;
   }
   ok( $checked > 0, 'checked structure_size on some SVs' );
}

# Runner smoke on the same fixture
{
   my $results;
   ok(
      lives {
         $results = PMAT::Bench::Runner->run(
            $path,
            phases => [qw( load inrefs heap_walk count )],
         );
      },
      'Runner completes on micro fixture'
   ) or diag $@;

   ok( $results->{phases}{load}{seconds} >= 0, 'load timed' );
   ok( $results->{phases}{inrefs}{seconds} >= 0, 'inrefs timed' );
   cmp_ok( $results->{heap_svs}, '==', $heap_n, 'runner heap_svs matches' );
}

# Synthetic bulk (tiny) load test — exercises streaming generator
{
   my ( $huge_tier ) = resolve_tiers( 'huge', target_bytes => 1 * 1024 * 1024 );
   my ( $spath, $smeta );
   ok(
      lives {
         ( $spath, $smeta ) = PMAT::Bench::Fixture->ensure(
            $huge_tier,
            dir   => $tmpdir,
            force => 1,
         );
      },
      'generate 1 MiB synthetic bulk fixture'
   ) or diag $@;

   ok( -f $spath, 'synthetic fixture exists' );
   cmp_ok( $smeta->{bytes}, '>', 100_000, 'synthetic has content' );

   my $spmat;
   ok(
      lives { $spmat = Devel::MAT->load($spath) },
      'load synthetic fixture'
   ) or diag $@;

   my $sn = scalar $spmat->dumpfile->heap;
   cmp_ok( $sn, '>', 10, "synthetic heap has SVs ($sn)" );

   ok( lives { $spmat->load_tool('Inrefs') }, 'Inrefs on synthetic' )
      or diag $@;
}

done_testing;
