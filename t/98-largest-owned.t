#!/usr/bin/perl
# OPT-10 / owned memoization: shipped owned_size matches owned_set sum; largest
# --owned runs via real command path; top-K helper does not use Fibonacci heap.

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
   plan skip_all => "Devel::MAT::Dumper not installed"
      unless eval { require Devel::MAT::Dumper; 1 };
}

# --- Tiny self-dump: structure matches t/10tool-sizes.t owned arithmetic ----------
# Dump only when process RSS is modest; full-suite pollution can make self-dumps huge.
{
   my $DUMPFILE = File::Spec->catfile( $FindBin::Bin, '98-largest-owned.pmat' );
   our $EMPTY_SVIV = 123;
   our @EMPTY_AV   = ();
   our @ARRAY      = ( 123, 45, [ 6, 7 ] );

   Devel::MAT::Dumper::dump($DUMPFILE);
   END { unlink $DUMPFILE if defined $DUMPFILE && -f $DUMPFILE }

   my $dump_sz = -s $DUMPFILE;
   my $skip_self = $dump_sz && $dump_sz > 40 * 1024 * 1024;

   for my $be (qw( perl rust )) {
      SKIP: {
         skip "self-dump too large for suite ($dump_sz bytes); use fixture tests", 4
            if $skip_self;
         local $ENV{PMAT_BACKEND} = $be;
         local $ENV{PMAT_IDX}     = '0';
         if ( $be eq 'rust' ) {
            require Devel::MAT::Backend;
            skip 'rust unavailable', 4 unless Devel::MAT::Backend->rust_available;
         }

         my $pmat = Devel::MAT->load($DUMPFILE);
         $pmat->load_tool('Sizes');

         my $sviv_size = $pmat->find_symbol('$EMPTY_SVIV')->size;
         my $av        = $pmat->find_symbol('@ARRAY');
         my $av2       = $av->elem(2)->rv;

         delete $av->{tool_sizes_owned};
         my $from_set = 0;
         $from_set += $_->size for $av->owned_set;
         delete $av->{tool_sizes_owned};
         my $from_memo = $av->owned_size;

         is( $from_memo, $from_set, "owned_size == sum(owned_set) ($be)" );
         is(
            $from_memo,
            $av->size + 3 * $sviv_size + $av2->size + 2 * $sviv_size,
            "owned_size arithmetic ($be)"
         );
         ref_is( $av, $av, 'stable av' );
         is( $av->owned_size, $from_memo, "owned_size cached ($be)" );
      }
   }
}

# --- Top-K selection unit on shipped helper ---------------------------------
# Use bounded micro fixture (not process self-dump — suite pollution makes
# Dumper self-dumps multi-hundred-MB and can OOM under forced-rust).
{
   require Devel::MAT::Tool::Sizes;
   my $pkg = 'Devel::MAT::Tool::Sizes::_largest';
   ok( $pkg->can('_select_topk'), '_select_topk is defined (no Fibonacci path required)' );

   my $path = File::Spec->catfile( $FindBin::Bin, '..', 'fixtures', 'micro-mixed-n200.pmat' );
   if ( !-f $path ) {
      require PMAT::Bench::Tiers;
      require PMAT::Bench::Fixture;
      my ($tier) = PMAT::Bench::Tiers::resolve_tiers('micro');
      my $fixtures = File::Spec->catdir( $FindBin::Bin, '..', 'fixtures' );
      ($path) = PMAT::Bench::Fixture->ensure( $tier, dir => $fixtures, count_svs => 1 );
   }

   local $ENV{PMAT_BACKEND} = 'perl';
   local $ENV{PMAT_IDX}     = '0';
   my $pmat = Devel::MAT->load($path);
   $pmat->load_tool('Sizes');
   my $df   = $pmat->dumpfile;
   # Bounded sample of heap for top-K unit (full micro heap is fine but heavy)
   my @heap = ( $df->heap )[ 0 .. 499 ];
   @heap = grep { $_ } @heap;
   cmp_ok( scalar @heap, '>', 10, 'heap has SVs for topk' );

   my @top3 = $pkg->_select_topk( \@heap, 'size', 3 );
   is( scalar @top3, 3, 'top-K returns K items' )
      or diag "top3=", join( ",", map { $_ ? $_->addr : "undef" } @top3 );

   my @scores = map { $_->size } @top3;
   ok( $scores[0] >= $scores[1] && $scores[1] >= $scores[2], 'top-K sorted by size desc' );

   my @sorted = sort { $b->size <=> $a->size || $a->addr <=> $b->addr } @heap;
   is( $top3[0]->addr, $sorted[0]->addr, 'top1 addr matches full sort' );
   is( $top3[1]->addr, $sorted[1]->addr, 'top2 addr matches full sort' );
   is( $top3[2]->addr, $sorted[2]->addr, 'top3 addr matches full sort' );
}

# Helper: classic owned sum without reading tool_sizes_owned cache
sub _classic_owned_sum {
   my ( $sv ) = @_;
   my $total = 0;
   my %seen;
   my @stack = ($sv);
   while (@stack) {
      my $n = pop @stack;
      next if $seen{ $n->addr }++;
      $total += $n->size;
      # Prefer cached children lists if present (same as production walks)
      if ( $n->{tool_sizes_owned_chld} ) {
         push @stack, @{ $n->{tool_sizes_owned_chld} };
      }
      else {
         push @stack, $n->_owned_children;
      }
   }
   return $total;
}

# --- Full-heap precompute + multi-parent on fixture (bounded size, real GLOB/CODE) -
# Process self-dumps from Dumper are huge (entire interpreter); use bench fixtures.
{
   require Devel::MAT::Tool::Sizes;

   # Prefer micro fixture (full-heap oracle without multi-minute runtime).
   my $path = File::Spec->catfile( $FindBin::Bin, '..', 'fixtures', 'micro-mixed-n200.pmat' );
   if ( !-f $path ) {
      require PMAT::Bench::Tiers;
      require PMAT::Bench::Fixture;
      my ($tier) = PMAT::Bench::Tiers::resolve_tiers('micro');
      my $fixtures = File::Spec->catdir( $FindBin::Bin, '..', 'fixtures' );
      ($path) = PMAT::Bench::Fixture->ensure( $tier, dir => $fixtures, count_svs => 1 );
   }

   local $ENV{PMAT_BACKEND} = 'perl';
   my $pmat = Devel::MAT->load($path);
   $pmat->load_tool('Sizes');
   my @heap = $pmat->dumpfile->heap;
   cmp_ok( scalar @heap, '>', 100, 'fixture heap non-trivial' );

   # Discover multi-parent exclusive claims (GLOB→CODE diamonds)
   my %claimants;
   for my $sv (@heap) {
      for my $c ( $sv->_owned_children ) {
         push @{ $claimants{ $c->addr } }, $sv;
      }
   }
   my @multi_addrs = grep { @{ $claimants{$_} } > 1 } keys %claimants;
   cmp_ok( scalar @multi_addrs, '>', 0,
      'fixture has multi-parent exclusive claims' )
      or diag "heap=", scalar(@heap);

   delete $_->{tool_sizes_owned} for @heap;
   delete $_->{tool_sizes_owned_chld} for @heap;
   Devel::MAT::Tool::Sizes::_largest::_precompute_owned_sizes( \@heap );

   # Oracle set: ALL multi-parent claimants + every 7th SV (covers full heap densely)
   my %check;
   for my $addr (@multi_addrs) {
      $check{ $_->addr } = $_ for @{ $claimants{$addr} };
   }
   for ( my $i = 0; $i < @heap; $i += 7 ) {
      $check{ $heap[$i]->addr } = $heap[$i];
   }

   my $bad = 0;
   my @sample;
   for my $sv ( values %check ) {
      my $memo    = $sv->{tool_sizes_owned};
      my $classic = _classic_owned_sum($sv);
      if ( !defined $memo || $memo != $classic ) {
         $bad++;
         push @sample,
            sprintf( "%s 0x%x memo=%s classic=%d",
               eval { $sv->desc } // $sv->type,
               $sv->addr, $memo // 'undef', $classic )
            if @sample < 8;
      }
   }
   is( $bad, 0,
      'precompute == classic for multi-parent claimants + strided full-heap sample' )
      or diag join( "\n", @sample );

   # Explicit multi-parent count assertion (skeptic: GLOB/CODE diamonds present)
   cmp_ok( scalar @multi_addrs, '>', 0, 'multi-parent exclusive claims present' );
}

# --- Real largest --owned command path (tiny dumper dump is OK for command) --
{
   require Commandable::Invocation;
   require Devel::MAT::Cmd::Terminal;

   # Use fixture if present (faster / bounded); else tiny self-dump
   my $path = File::Spec->catfile( $FindBin::Bin, '..', 'fixtures', 'tiny.pmat' );
   if ( !-f $path ) {
      $path = File::Spec->catfile( $FindBin::Bin, '98-largest-cmd.pmat' );
      our @CMD_ARRAY = ( 1 .. 20 );
      Devel::MAT::Dumper::dump($path);
      END { unlink $path if defined $path && -f $path && $path =~ /98-largest-cmd/ }
   }

   local $ENV{PMAT_BACKEND} = 'perl';
   my $pmat = Devel::MAT->load($path);
   ok(
      lives {
         open my $out, '>', \( my $buf );
         my $old = select $out;
         $pmat->run_command(
            Commandable::Invocation->new('largest --owned'),
            progress => sub { },
         );
         select $old;
         close $out;
         die "empty largest output" unless length( $buf // '' );
      },
      'largest --owned command path lives'
   );
}

# Static: Fibonacci heap no longer used by Sizes largest path
{
   open my $fh, '<', File::Spec->catfile( $FindBin::Bin, '..', 'lib', 'Devel', 'MAT', 'Tool', 'Sizes.pm' )
      or die $!;
   local $/;
   my $src = <$fh>;
   unlike( $src, qr/Heap::Fibonacci/, 'Sizes.pm no longer uses Heap::Fibonacci' );
   like( $src, qr/_select_topk/, 'Sizes.pm defines _select_topk' );
   like( $src, qr/_precompute_owned_sizes/, 'Sizes.pm has SCC owned precompute' );
   like( $src, qr/_owned_children/, 'Sizes.pm has exclusive-child helper' );
}

done_testing;
