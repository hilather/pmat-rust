#!/usr/bin/perl
# Direct Core API tests: load, type_counts batch, edge batch (no Dumpfile).

use v5.14;
use warnings;

use Test2::V0;
use FindBin;
use File::Spec;
use lib File::Spec->catdir( $FindBin::Bin, '..', 'blib', 'lib' );
use lib File::Spec->catdir( $FindBin::Bin, '..', 'blib', 'arch' );
use lib File::Spec->catdir( $FindBin::Bin, '..', 'local', 'lib', 'perl5' );
use lib File::Spec->catdir( $FindBin::Bin, '..', 'bench', 'lib' );

use PMAT::Bench::Tiers qw( resolve_tiers );
use PMAT::Bench::Fixture;

plan skip_all => 'Devel::MAT::Core not available'
   unless eval {
      require Devel::MAT::Core;
      Devel::MAT::Core->available;
   };

my $tmpdir = File::Spec->catdir( $FindBin::Bin, '..', 'fixtures' );
my ( $tier ) = resolve_tiers('micro');
my ( $path ) = PMAT::Bench::Fixture->ensure( $tier, dir => $tmpdir );

my $core = Devel::MAT::Core->load($path);
ok( $core, 'load via Core' );
my $heap = $core->heap_count;
cmp_ok( $heap, '>', 1000, "heap_count=$heap" );
is( $core->format_minor, 6, 'format minor 6' );

my $tc = $core->type_counts;
ok( ref $tc eq 'HASH', 'type_counts is hash' );
my $sum = 0;
$sum += $_ for values %$tc;
is( $sum, $heap, 'type_counts sum to heap' );

my $fwd = $core->forward_edge_count;
my $rev = $core->reverse_edge_count;
cmp_ok( $fwd, '>', 0, "forward edges $fwd" );
is( $fwd, $rev, 'forward and reverse edge counts equal' );

# Batch outrefs for first few objects — one FFI call per object (not per edge)
my $edges_seen = 0;
for my $id ( 0 .. 50 ) {
   my $batch = $core->outrefs_batch($id);
   ok( ref $batch eq 'ARRAY', "outrefs_batch($id) array" );
   $edges_seen += scalar @$batch;
}
cmp_ok( $edges_seen, '>=', 0, "batch edges from first 51 objects: $edges_seen" );

# roots
my $roots = $core->roots;
ok( @$roots > 0, 'roots non-empty' );
ok( ( grep { $_->{name} eq 'defstash' } @$roots ), 'has defstash root' );

done_testing;
