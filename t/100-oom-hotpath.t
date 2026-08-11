#!/usr/bin/perl
# Order-of-magnitude large-dump cliffs: identify without full heap materialize;
# largest --owned without full proxy heap (native precompute + top-K materialize).

use v5.14;
use warnings;

use Test2::V0;
use FindBin;
use File::Spec;

use lib File::Spec->catdir( $FindBin::Bin, '..', 'blib', 'lib' );
use lib File::Spec->catdir( $FindBin::Bin, '..', 'blib', 'arch' );
use lib File::Spec->catdir( $FindBin::Bin, '..', 'local', 'lib', 'perl5' );
use lib File::Spec->catdir( $FindBin::Bin, '..', 'bench', 'lib' );

BEGIN {
   plan skip_all => "Devel::MAT not built"
      unless eval { require Devel::MAT; 1 };
}

require Devel::MAT::Backend;
require Devel::MAT::Cmd::Terminal;
require Commandable::Invocation;

my $have_rust = Devel::MAT::Backend->rust_available;

my $fixtures = File::Spec->catdir( $FindBin::Bin, '..', 'fixtures' );
my $path = File::Spec->catfile( $fixtures, 'micro-mixed-n200.pmat' );
if ( !-f $path ) {
   require PMAT::Bench::Tiers;
   require PMAT::Bench::Fixture;
   my ($tier) = PMAT::Bench::Tiers::resolve_tiers('micro');
   ($path) = PMAT::Bench::Fixture->ensure( $tier, dir => $fixtures, count_svs => 1 );
}

# ---- Identify under rust does not complete full heap ----
SKIP: {
   skip 'rust required', 5 unless $have_rust;
   local $ENV{PMAT_BACKEND} = 'rust';
   local $ENV{PMAT_IDX}     = '0';
   delete local $ENV{PMAT_INREFS_FULL};

   my $pmat = Devel::MAT->load($path);
   my $df   = $pmat->dumpfile;
   my $heap_n = $df->rust_core->heap_count;
   my $mat0   = $df->rust_materialized_count;
   ok( !$df->rust_heap_complete, 'heap incomplete after load' );

   my $sv = eval { $pmat->find_symbol('$0') };
   $sv //= do {
      my $row = $df->rust_core->object_at(50);
      $df->sv_at( $row->[0] );
   };
   ok( $sv, 'have identify target' );

   open my $out, '>', \( my $buf );
   my $old = select $out;
   $pmat->run_command(
      Commandable::Invocation->new( sprintf( 'identify %#x', $sv->addr ) ),
      progress => sub { },
   );
   select $old;

   like( $buf, qr/is:/, 'identify produces output' );
   ok( !$df->rust_heap_complete, 'heap still incomplete after identify' );
   cmp_ok( $df->rust_materialized_count, '<', $heap_n * 0.25,
      'materialize ≪ full heap after identify' )
      or diag( sprintf 'mat=%d heap=%d mat0=%d',
         $df->rust_materialized_count, $heap_n, $mat0 );
}

# ---- Identify command path on self-dump stays sparse and non-empty ----
SKIP: {
   skip 'rust required', 3 unless $have_rust;
   skip 'Dumper required', 3 unless eval { require Devel::MAT::Dumper; 1 };

   my $DUMPFILE = File::Spec->catfile( $FindBin::Bin, '100-oom-hotpath.pmat' );
   our %HASH = ( array => [ my $SCALAR = \"foobar" ] );
   Devel::MAT::Dumper::dump($DUMPFILE);
   END { unlink $DUMPFILE if defined $DUMPFILE && -f $DUMPFILE }

   local $ENV{PMAT_BACKEND} = 'rust';
   local $ENV{PMAT_IDX}     = '0';
   delete local $ENV{PMAT_INREFS_FULL};

   my $p  = Devel::MAT->load($DUMPFILE);
   my $df = $p->dumpfile;
   my $heap_n = $df->rust_core->heap_count;
   my $addr   = Scalar::Util::refaddr($SCALAR);

   open my $out, '>', \( my $buf );
   my $old = select $out;
   $p->run_command(
      Commandable::Invocation->new( sprintf( 'identify %#x', $addr ) ),
      progress => sub { },
   );
   select $old;

   like( $buf, qr/is:/, 'self-dump identify command output' );
   ok( !$df->rust_heap_complete, 'self-dump identify did not complete rust heap' );
   cmp_ok( $df->rust_materialized_count, '<', $heap_n * 0.5,
      'self-dump identify materialize below half heap' );
}

# ---- largest --owned does not force full heap complete under rust ----
SKIP: {
   skip 'rust required', 4 unless $have_rust;
   local $ENV{PMAT_BACKEND} = 'rust';
   local $ENV{PMAT_IDX}     = '0';
   delete local $ENV{PMAT_OWNED_FULL};

   my $pmat = Devel::MAT->load($path);
   my $df   = $pmat->dumpfile;
   my $heap_n = $df->rust_core->heap_count;
   my $mat0   = $df->rust_materialized_count;

   open my $out, '>', \( my $buf );
   my $old = select $out;
   $pmat->run_command(
      Commandable::Invocation->new('largest --owned 3 2 1'),
      progress => sub { },
   );
   select $old;

   like( $buf, qr/consumes:|KiB|bytes|at 0x/i, 'largest --owned produces output' );
   ok( !$df->rust_heap_complete, 'heap not complete after largest --owned' );
   cmp_ok( $df->rust_materialized_count, '<', $heap_n * 0.5,
      'largest --owned materialize well below full heap' )
      or diag( sprintf 'mat=%d heap=%d (was %d at load)',
         $df->rust_materialized_count, $heap_n, $mat0 );
}

# Static: Sizes has native owned path; Inrefs has lazy ensure
{
   open my $fh, '<', File::Spec->catfile( $FindBin::Bin, '..', 'lib', 'Devel', 'MAT', 'Tool', 'Sizes.pm' )
      or die $!;
   local $/;
   my $src = <$fh>;
   like( $src, qr/_native_owned_by_id/, 'Sizes defines native owned precompute' );
   like( $src, qr/_native_owned_topk_ids/, 'Sizes defines native top-K ids' );
}

# ---- Native owned top-K set matches classic owned_size ranking (0.54) ----
SKIP: {
   skip 'rust required', 2 unless $have_rust;
   local $ENV{PMAT_BACKEND} = 'rust';
   local $ENV{PMAT_IDX}     = '0';
   delete local $ENV{PMAT_OWNED_FULL};

   my $pmat = Devel::MAT->load($path);
   $pmat->load_tool('Sizes');
   my $df   = $pmat->dumpfile;
   my $core = $df->rust_core;
   my $n    = $core->heap_count;
   my $owned = $core->owned_sizes;
   ok( $owned && @$owned == $n, 'owned_sizes length == heap_count' );

   # Classic owned_size for every SV (micro fixture is bounded)
   my @classic;
   for my $id ( 0 .. $n - 1 ) {
      my $row = $core->object_at($id) or next;
      my $sv  = $df->sv_at( $row->[0] ) or next;
      delete $sv->{tool_sizes_owned};
      delete $sv->{tool_sizes_owned_chld};
      push @classic, [ $sv->owned_size, $row->[0], $id ];
   }
   @classic = sort { $b->[0] <=> $a->[0] || $a->[1] <=> $b->[1] } @classic;

   my @native_ids = sort {
      ( $owned->[$b] // 0 ) <=> ( $owned->[$a] // 0 )
         || ( $core->object_at($a)->[0] // 0 ) <=> ( $core->object_at($b)->[0] // 0 )
   } 0 .. $n - 1;

   my $k = 5;
   my %classic_top = map { $_->[1] => 1 } @classic[ 0 .. $k - 1 ];
   my %native_top  = map {
      my $row = $core->object_at( $native_ids[$_] );
      ( $row->[0] => 1 )
   } 0 .. $k - 1;

   my $missing = 0;
   for my $a ( keys %classic_top ) {
      $missing++ unless $native_top{$a};
   }
   is( $missing, 0, "native owned top-$k set matches classic owned_size top-$k" )
      or do {
         diag( "classic: "
            . join( " ", map { sprintf( "%#x", $_->[1] ) } @classic[ 0 .. $k - 1 ] ) );
         diag( "native:  "
            . join(
               " ",
               map {
                  sprintf( "%#x", $core->object_at( $native_ids[$_] )->[0] )
               } 0 .. $k - 1
            ) );
      };
}

done_testing;
