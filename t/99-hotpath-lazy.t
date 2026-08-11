#!/usr/bin/perl
# High-ROI large-dump path: summary/count without full heap materialize;
# inrefs classic outref walk (CSR residual); index size policy.

use v5.14;
use warnings;

use Test2::V0;
use FindBin;
use File::Spec;
use File::Temp qw( tempdir );

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

# ---- Summary does not force full materialize under rust ----
SKIP: {
   skip 'rust required', 4 unless $have_rust;
   local $ENV{PMAT_BACKEND} = 'rust';
   local $ENV{PMAT_IDX} = '0';

   my $pmat = Devel::MAT->load($path);
   my $df   = $pmat->dumpfile;
   my $heap_n = $df->rust_core->heap_count;
   my $mat0 = $df->rust_materialized_count;
   ok( !$df->rust_heap_complete, 'heap not complete after load' );
   cmp_ok( $mat0, '<', $heap_n, 'materialized ≪ heap after load' );

   open my $out, '>', \( my $buf );
   my $old = select $out;
   $pmat->run_command( Commandable::Invocation->new('summary'), progress => sub { } );
   select $old;

   like( $buf, qr/Heap contains $heap_n objects/, 'summary prints core heap_count' );
   ok( !$df->rust_heap_complete, 'heap still not complete after summary' );
   cmp_ok( $df->rust_materialized_count, '<', $heap_n * 0.5,
      'materialize count stays well below full heap after summary' );
}

# ---- Default count without full materialize; parity with perl major kinds ----
SKIP: {
   skip 'rust required', 3 unless $have_rust;

   my %perl_counts;
   {
      local $ENV{PMAT_BACKEND} = 'perl';
      my $p = Devel::MAT->load($path);
      $p->load_tool('Count');
      # Drive count_svs via tool, capture kinds by walking heap (oracle)
      for my $sv ( $p->dumpfile->heap ) {
         $perl_counts{ $sv->type }++;
      }
   }

   local $ENV{PMAT_BACKEND} = 'rust';
   local $ENV{PMAT_IDX} = '0';
   my $pmat = Devel::MAT->load($path);
   my $df   = $pmat->dumpfile;
   my $heap_n = $df->rust_core->heap_count;
   my $mat0 = $df->rust_materialized_count;

   open my $out, '>', \( my $buf );
   my $old = select $out;
   $pmat->run_command( Commandable::Invocation->new('count'), progress => sub { } );
   select $old;

   ok( !$df->rust_heap_complete, 'count default does not complete heap' );
   cmp_ok( $df->rust_materialized_count, '<=', $mat0 + 100,
      'count default does not mass-materialize proxies' );

   # Parse total line from table
   like( $buf, qr/\(total\)/, 'count emits total row' );

   # Kind parity for major types (allow PAD/ARRAY split already applied on both)
   my %rust_from_output;
   for my $line ( split /\n/, $buf ) {
      next unless $line =~ /^\s+(\S+)\s+(\d+)/;
      my ( $k, $n ) = ( $1, $2 );
      next if $k eq 'Kind' || $k eq '(total)' || $k =~ /^\(/;
      $rust_from_output{$k} = $n + 0;
   }
   for my $k (qw( GLOB CODE HASH STASH REF )) {
      next unless exists $perl_counts{$k};
      is( $rust_from_output{$k}, $perl_counts{$k}, "count kind $k matches perl walk" );
   }
   # Totals must match (file heap)
   my $ptot = 0; $ptot += $_ for values %perl_counts;
   my $rtot = 0; $rtot += $_ for values %rust_from_output;
   is( $rtot, $ptot, 'count total SVs match' );
   # PAD reclass: rust path should report PAD if perl does
   if ( $perl_counts{PAD} ) {
      cmp_ok( $rust_from_output{PAD} // 0, '>', 0, 'PAD reclass present on rust count' );
      # ARRAY + PAD (+ PADLIST/PADNAMES) should cover raw arrays + pads
      my $perl_arrish = ( $perl_counts{ARRAY} // 0 ) + ( $perl_counts{PAD} // 0 )
         + ( $perl_counts{PADLIST} // 0 ) + ( $perl_counts{PADNAMES} // 0 );
      my $rust_arrish = ( $rust_from_output{ARRAY} // 0 ) + ( $rust_from_output{PAD} // 0 )
         + ( $rust_from_output{PADLIST} // 0 ) + ( $rust_from_output{PADNAMES} // 0 );
      is( $rust_arrish, $perl_arrish, 'ARRAY+PAD* family totals match' );
   }
}

# ---- Inrefs: classic outref walk under rust; scalar==list; parity ----
# (CSR reverse graph is a structural subset — e.g. CODE "the glob" — so pure-CSR
# cannot match 0.54 strengths/edges. Classic walk is the oracle path.)
#
# Cross-backend outref multisets for CODE "the glob" are sensitive to Perl hash
# key perturbation (protosub/glob linking). Compare perl vs rust in a child with
# fixed PERL_HASH_SEED + PERL_PERTURB_KEYS=0 so the oracle is deterministic.
SKIP: {
   skip 'rust required', 6 unless $have_rust;

   local $ENV{PMAT_BACKEND} = 'rust';
   local $ENV{PMAT_IDX} = '0';

   my $pmat = Devel::MAT->load($path);
   my $df   = $pmat->dumpfile;
   ok( lives { $pmat->load_tool( 'Inrefs', progress => sub { } ) }, 'inrefs init lives under rust' );

   # Self-consistency: classic inrefs must match a reverse rebuild from outrefs
   # in the same load (catches CSR strength/just_count bugs without hash noise).
   my %rev_strong;
   my %rev_weak;
   for my $sv ( $df->heap ) {
      for my $o ( $sv->outrefs ) {
         my $t = $o->sv or next;
         next if $t->immortal;
         my $a = $t->addr;
         if ( $o->strength eq 'strong' ) {
            $rev_strong{$a}++;
         }
         elsif ( $o->strength eq 'weak' ) {
            $rev_weak{$a}++;
         }
      }
   }

   my ( $bad_sc, $bad_rev_s, $bad_rev_w, $n ) = ( 0, 0, 0, 0 );
   my @sample;
   my $i = 0;
   for my $sv ( $df->heap ) {
      push @sample, $sv if ( $i++ % 11 == 0 ) || ( $sv->type eq 'GLOB' );
   }
   for my $sv (@sample) {
      $n++;
      my $a  = $sv->addr;
      my $sc = 0 + scalar $sv->inrefs_strong;
      my $lc = () = $sv->inrefs_strong;
      $bad_sc++ if $sc != $lc;
      # list-context inrefs re-filters via outrefs; compare to reverse multiset
      # of non-root strong/weak heap edges (roots/stack are extra on inrefs).
      my $is = () = $sv->inrefs_strong;
      my $iw = () = $sv->inrefs_weak;
      # Subtract root annotations that reverse rebuild does not include
      my $ti = $sv->{tool_inrefs} // [];
      my $root_s = $ti->[4] // 0;  # IDX_ROOTS_STRONG
      my $root_w = ( $ti->[5] // 0 ) + ( $ti->[6] // 0 );  # roots_weak + stack
      my $expect_s = $rev_strong{$a} // 0;
      my $expect_w = $rev_weak{$a} // 0;
      $bad_rev_s++ if $is - $root_s != $expect_s;
      $bad_rev_w++ if $iw - $root_w != $expect_w;
   }
   is( $bad_sc, 0, "rust scalar==list inrefs_strong (sample n=$n)" );
   is( $bad_rev_s, 0, 'rust inrefs_strong matches same-load outref reverse (sample)' );
   is( $bad_rev_w, 0, 'rust inrefs_weak matches same-load outref reverse (sample)' );

   # Cross-backend parity in a child with fixed hash seed (deterministic oracle).
   my $helper = File::Spec->catfile( $FindBin::Bin, '..', 't', '99-hotpath-lazy.t' );
   # Inline one-shot compare script via perl -e
   my $cmp = <<'CMP';
use lib @ARGV[0..3];
use Devel::MAT;
my $path = $ARGV[4];
sub counts {
  my $be = shift;
  local $ENV{PMAT_BACKEND} = $be;
  local $ENV{PMAT_IDX} = "0";
  my $p = Devel::MAT->load($path);
  $p->load_tool("Inrefs", progress => sub {});
  my %h;
  for my $sv ($p->dumpfile->heap) {
    $h{$sv->addr} = join(",",
      0+scalar $sv->inrefs_strong,
      0+scalar $sv->inrefs_weak,
      0+scalar $sv->inrefs_direct);
  }
  return \%h;
}
my $p = counts("perl");
my $r = counts("rust");
my $bad = 0;
for my $a (keys %$p) {
  $bad++ if ($p->{$a} // "") ne ($r->{$a} // "");
}
print "bad=$bad n=", scalar(keys %$p), "\n";
exit($bad ? 1 : 0);
CMP
   my $blib_lib  = File::Spec->catdir( $FindBin::Bin, '..', 'blib', 'lib' );
   my $blib_arch = File::Spec->catdir( $FindBin::Bin, '..', 'blib', 'arch' );
   my $local_lib = File::Spec->catdir( $FindBin::Bin, '..', 'local', 'lib', 'perl5' );
   my $bench_lib = File::Spec->catdir( $FindBin::Bin, '..', 'bench', 'lib' );
   my @cmd = (
      $^X,
      "-e", $cmp,
      $blib_lib, $blib_arch, $local_lib, $bench_lib,
      $path,
   );
   local $ENV{PERL_HASH_SEED}    = '0xC0FFEE';
   local $ENV{PERL_PERTURB_KEYS} = '0';
   # Hash seed applies at interpreter start — must spawn a child.
   my $out = "";
   {
      open my $fh, "-|", "env", "PERL_HASH_SEED=0xC0FFEE", "PERL_PERTURB_KEYS=0", @cmd
         or die "spawn inrefs compare: $!";
      local $/;
      $out = <$fh> // "";
      close $fh;
   }
   my $child_ok = ( $out =~ /bad=0\b/ && $? == 0 );
   ok( $child_ok, "rust inrefs strong/weak/direct match perl (fixed hash seed child)" )
      or diag("child output: $out wait=$?");
}

# ---- Index policy: default skips fat idx on small dumps ----
SKIP: {
   skip 'rust required', 3 unless $have_rust;
   require Devel::MAT::Core;

   my $tmpdir = tempdir( CLEANUP => 1 );
   my $dump = File::Spec->catfile( $tmpdir, 'policy.pmat' );
   {
      our $Z = 1;
      require Devel::MAT::Dumper;
      Devel::MAT::Dumper::dump($dump);
   }
   my $idx = $dump . '.idx';
   unlink $idx if -e $idx;

   # Unset PMAT_IDX → size-gated; force high threshold so small dump skips idx
   {
      delete local $ENV{PMAT_IDX};
      local $ENV{PMAT_IDX_MIN_BYTES} = '999999999';
      unlink $idx if -e $idx;
      my $core = Devel::MAT::Core->load($dump);
      ok( $core, 'load ok without PMAT_IDX force' );
      ok( !-f $idx, 'size gate: no idx when under PMAT_IDX_MIN_BYTES' );
   }

   # Force on
   {
      local $ENV{PMAT_IDX} = '1';
      unlink $idx if -e $idx;
      my $core = Devel::MAT::Core->load_full_parse($dump);
      ok( -f $idx, 'PMAT_IDX=1 forces index write' );
   }
}

# Static: summary prefers heap_count under rust
{
   open my $fh, '<', File::Spec->catfile( $FindBin::Bin, '..', 'lib', 'Devel', 'MAT', 'Tool', 'Summary.pm' )
      or die $!;
   local $/;
   my $src = <$fh>;
   like( $src, qr/heap_count/, 'Summary uses heap_count' );
   like( $src, qr/rust_core/, 'Summary checks rust_core' );
}

# Static: Inrefs lazy path re-filters outrefs; classic full walk retained as fallback.
# Pure-CSR slot fill without outrefs re-filter is forbidden (OPT-03 lesson).
{
   open my $fh, '<', File::Spec->catfile( $FindBin::Bin, '..', 'lib', 'Devel', 'MAT', 'Tool', 'Inrefs.pm' )
      or die $!;
   local $/;
   my $src = <$fh>;
   like( $src, qr/_ensure_inrefs_built|_inrefs_lazy/, 'Inrefs has lazy on-demand path' );
   like( $src, qr/\$sv->outrefs|outrefs\( "NO_DESC" \)/, 'Inrefs re-filters via outrefs' );
   like( $src, qr/PMAT_INREFS_FULL|foreach my \$sv \( \$df->heap \)/,
      'Inrefs keeps classic full-heap fallback' );
}

done_testing;
