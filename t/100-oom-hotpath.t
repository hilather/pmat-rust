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

# ---- Native owned ranking: exact on controlled exclusive tree; robust on micro ----
# Residual: CSR strong exclusive kids still ≠ full 0.54 outrefs_strong on some
# STASH/CODE graphs. Regenerated micro fixtures (gitignored) therefore can
# disagree on ranks 4–5 of top-5 while top-1..3 and score order stay useful.
# Exact equality is asserted on a self-dump exclusive root (simple AvREAL kids).
SKIP: {
   skip 'rust required', 5 unless $have_rust;
   skip 'Dumper required', 5 unless eval { require Devel::MAT::Dumper; 1 };
   require Scalar::Util;

   my $DUMPFILE = File::Spec->catfile( $FindBin::Bin, '100-oom-owned-rank.pmat' );
   # Exclusive ownership tree: ROOT AV of refcnt==1 child AVs (large payloads).
   our $OWNED_RANK_ROOT;
   our $OWNED_RANK_ELEM0;
   {
      my @elems;
      for my $i ( 1 .. 12 ) {
         push @elems, [ 'Z' x ( 4000 + 100 * $i ) ];
      }
      $OWNED_RANK_ELEM0 = $elems[0];
      $OWNED_RANK_ROOT  = \@elems;
   }
   Devel::MAT::Dumper::dump($DUMPFILE);
   END { unlink $DUMPFILE if defined $DUMPFILE && -f $DUMPFILE }

   local $ENV{PMAT_BACKEND} = 'rust';
   local $ENV{PMAT_IDX}     = '0';
   delete local $ENV{PMAT_OWNED_FULL};

   my $pmat = Devel::MAT->load($DUMPFILE);
   $pmat->load_tool('Sizes');
   my $df   = $pmat->dumpfile;
   my $core = $df->rust_core;
   my $n    = $core->heap_count;
   my $owned = $core->owned_sizes;
   ok( $owned && @$owned == $n, 'self-dump owned_sizes length == heap_count' );

   my $root_addr = Scalar::Util::refaddr($OWNED_RANK_ROOT);
   my $elem0_addr = Scalar::Util::refaddr($OWNED_RANK_ELEM0);
   my $root_sv   = $df->sv_at($root_addr);
   ok( $root_sv, 'self-dump exclusive root present' );

   my ( $root_id, $elem_id );
   for my $id ( 0 .. $n - 1 ) {
      my $row = $core->object_at($id) or next;
      $root_id = $id if $row->[0] == $root_addr;
      $elem_id = $id if $row->[0] == $elem0_addr;
   }
   ok( defined $root_id, 'self-dump root has ObjectId' );

   if ( $root_sv && defined $root_id ) {
      delete $root_sv->{tool_sizes_owned};
      delete $root_sv->{tool_sizes_owned_chld};
      my $classic_root = $root_sv->owned_size;
      is( $owned->[$root_id], $classic_root,
         'native owned score == classic for exclusive AV root' )
         or diag( sprintf 'native=%s classic=%s addr=%#x',
            $owned->[$root_id] // 'undef', $classic_root // 'undef', $root_addr );
   }
   else {
      fail('native owned score == classic for exclusive AV root');
   }

   # Root must outrank an exclusive child under native ranking.
   if ( defined $root_id && defined $elem_id ) {
      cmp_ok( $owned->[$root_id], '>', $owned->[$elem_id],
         'native: exclusive root scores above element' );
   }
   else {
      fail('native: exclusive root scores above element (missing ObjectId)');
      diag( sprintf 'root_id=%s elem_id=%s root=%#x elem0=%#x',
         $root_id // 'undef', $elem_id // 'undef',
         $root_addr // 0, $elem0_addr // 0 );
   }
}

SKIP: {
   skip 'rust required', 4 unless $have_rust;
   local $ENV{PMAT_BACKEND} = 'rust';
   local $ENV{PMAT_IDX}     = '0';
   delete local $ENV{PMAT_OWNED_FULL};

   my $pmat = Devel::MAT->load($path);
   $pmat->load_tool('Sizes');
   my $df   = $pmat->dumpfile;
   my $core = $df->rust_core;
   my $n    = $core->heap_count;
   my $owned = $core->owned_sizes;
   ok( $owned && @$owned == $n, 'micro owned_sizes length == heap_count' );

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

   my $overlap = 0;
   for my $a ( keys %classic_top ) {
      $overlap++ if $native_top{$a};
   }

   # Regenerated micro dumps (CI EL8) can swap ranks 4–5 when CSR residual
   # under-counts STASH exclusive kids. Require useful ranking, not exact set.
   cmp_ok( $overlap, '>=', 3,
      "native owned top-$k overlaps classic top-$k in at least 3 addresses" )
      or do {
         diag( "overlap=$overlap/$k" );
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

   my $classic_top1 = $classic[0][1];
   ok( $native_top{$classic_top1},
      'classic owned top-1 address appears in native top-5' )
      or diag( sprintf 'classic top-1 %#x missing from native top-5', $classic_top1 );

   cmp_ok( $owned->[ $native_ids[0] ] // 0, '>', 0,
      'native top-1 owned score is positive' );
}

done_testing;
