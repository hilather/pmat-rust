#!/usr/bin/perl
# OPT-01: forced-Rust load must not eagerly materialize every heap proxy;
# sv_at / rust_proxy_for_id create one cached proxy per ObjectId; heap() completes.

use v5.14;
use warnings;

use Test2::V0;
use FindBin;
use File::Spec;
use Scalar::Util qw( refaddr );

use lib File::Spec->catdir( $FindBin::Bin, '..', 'blib', 'lib' );
use lib File::Spec->catdir( $FindBin::Bin, '..', 'blib', 'arch' );
use lib File::Spec->catdir( $FindBin::Bin, '..', 'local', 'lib', 'perl5' );
use lib File::Spec->catdir( $FindBin::Bin, '..', 'bench', 'lib' );

BEGIN {
   plan skip_all => "Devel::MAT not built (run perl Build.PL && ./Build)"
      unless eval { require Devel::MAT; 1 };
   require Devel::MAT::Backend;
   plan skip_all => "pmat-core not available"
      unless Devel::MAT::Backend->rust_available;
}

use PMAT::Bench::Tiers qw( resolve_tiers );
use PMAT::Bench::Fixture;

my $fixtures = File::Spec->catdir( $FindBin::Bin, '..', 'fixtures' );
my ( $tier ) = resolve_tiers('micro');
my ( $path, $meta ) = PMAT::Bench::Fixture->ensure(
   $tier,
   dir       => $fixtures,
   count_svs => 1,
);

# Real forced-Rust load path (not a reimplementation of the parser).
local $ENV{PMAT_BACKEND} = 'rust';

my $pmat = Devel::MAT->load($path);
my $df   = $pmat->dumpfile;

is( $df->backend, 'rust', 'backend is rust' );
ok( $df->rust_core, 'rust_core present' );

my $heap_total = $df->rust_core->heap_count;
cmp_ok( $heap_total, '>', 100, 'non-trivial heap_count from core' );

# (a) Load completes without filling the full heap map
my $after_load = $df->rust_materialized_count;
cmp_ok( $after_load, '<', $heap_total,
   "load materializes fewer than all heap SVs ($after_load < $heap_total)" );
ok( !$df->rust_heap_complete, 'heap not marked complete after load' );

# Roots / defstash are available without full materialize
ok( $df->defstash, 'defstash root resolves' );

my $mid = int( $heap_total / 2 );
my $addr = $df->rust_core->addr_for_id($mid);
ok( $addr, 'sample addr from core' );

# (b) first sv_at materializes one proxy
my $before = $df->rust_materialized_count;
my $sv1 = $df->sv_at($addr);
ok( $sv1, 'sv_at materializes sample SV' );
my $after_one = $df->rust_materialized_count;
cmp_ok( $after_one, '>=', $before, 'materialized count did not shrink' );
# May materialize more than one (fixup pulls related SVs); must still be sparse.
cmp_ok( $after_one, '<', $heap_total, 'still not full heap after one sv_at' );

# (c) second access same addr is same object identity
my $sv2 = $df->sv_at($addr);
ref_is( $sv2, $sv1, 'second sv_at returns same proxy object' );

my $by_id = $df->rust_proxy_for_id($mid);
ref_is( $by_id, $sv1, 'rust_proxy_for_id returns same proxy as sv_at' );

# (d) heap() yields full set
my @all = $df->heap;
is( scalar @all, $heap_total, 'heap() returns heap_count SVs' );
ok( $df->rust_heap_complete, 'heap marked complete after heap()' );
cmp_ok( $df->rust_materialized_count, '>=', $heap_total,
   'materialized count covers full heap' );

# Identity preserved after full materialize
ref_is( $df->sv_at($addr), $sv1, 'identity stable after heap()' );

# Forced-perl still works on same fixture (oracle path)
{
   local $ENV{PMAT_BACKEND} = 'perl';
   my $pmat_p = Devel::MAT->load($path);
   my $df_p   = $pmat_p->dumpfile;
   is( $df_p->backend, 'perl', 'perl backend' );
   my $n_p = scalar $df_p->heap;
   is( $n_p, $heap_total, 'perl heap count matches rust core heap_count' );
}

done_testing;
