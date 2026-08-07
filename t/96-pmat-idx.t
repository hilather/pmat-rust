#!/usr/bin/perl
# PAR-110: persistent .pmat.idx sidecar under forced Rust.
# Fail-closed: requires Devel::MAT::Core (Rust).

use v5.14;
use warnings;

use Test2::V0;
use FindBin;
use File::Spec;
use File::Temp qw( tempdir );
use File::Copy qw( copy );
use lib File::Spec->catdir( $FindBin::Bin, '..', 'blib', 'lib' );
use lib File::Spec->catdir( $FindBin::Bin, '..', 'blib', 'arch' );
use lib File::Spec->catdir( $FindBin::Bin, '..', 'local', 'lib', 'perl5' );

plan skip_all => 'Devel::MAT not built'
   unless eval { require Devel::MAT; 1 };
plan skip_all => 'Dumper required'
   unless eval { require Devel::MAT::Dumper; 1 };

require Devel::MAT::Backend;
require Devel::MAT::Core;

ok( Devel::MAT::Backend->rust_available, 'Rust core available' )
   or bail_out('PAR-110 requires pmat-core');

my $tmpdir = tempdir( CLEANUP => 1 );
my $dump = File::Spec->catfile( $tmpdir, 'idx-fixture.pmat' );

# Minimal dump
{
   our $X = 42;
   our @A = ( 1, 2, 3 );
   Devel::MAT::Dumper::dump($dump);
}

my $idx = Devel::MAT::Core::index_path_for($dump);
ok( $idx =~ /\.idx\z/, 'index path ends with .idx' );
is( $idx, $dump . '.idx', 'index path is dump + .idx' );

# Ensure clean slate
unlink $idx if -e $idx;

# ---- First load: full parse, write index ----
{
   local $ENV{PMAT_BACKEND} = 'rust';
   local $ENV{PMAT_IDX} = '1';
   # Force rebuild path
   my $core = Devel::MAT::Core->load_full_parse($dump);
   ok( $core, 'full_parse load ok' );
   cmp_ok( $core->heap_count, '>', 100, 'heap non-trivial' );
   is( Devel::MAT::Core::last_load_used_index(), 0,
      'full_parse does not report used_index' );
   ok( -f $idx, 'sidecar written after full_parse' );
   cmp_ok( -s $idx, '>', 64, 'index non-empty' );
}

my $heap1;
my $fwd1;
{
   local $ENV{PMAT_BACKEND} = 'rust';
   local $ENV{PMAT_IDX} = '1';
   my $core = Devel::MAT::Core->load($dump);
   $heap1 = $core->heap_count;
   $fwd1  = $core->forward_edge_count;
   is( Devel::MAT::Core::last_load_used_index(), 1,
      'second load uses validated index' );
   is( $core->heap_count, $heap1, 'heap stable' );
}

# ---- Digest mismatch: change dump bytes after index written ----
{
   local $ENV{PMAT_BACKEND} = 'rust';
   local $ENV{PMAT_IDX} = '1';

   # Corrupt dump while keeping index from previous content
   open my $fh, '>>', $dump or die $!;
   print {$fh} "\0";  # append one byte — digest/size must fail
   close $fh;

   # Index still present for old content
   ok( -f $idx, 'index still present before mismatch load' );

   my $core = Devel::MAT::Core->load($dump);
   ok( $core, 'load after dump change still succeeds (full parse fallback)' );
   is( Devel::MAT::Core::last_load_used_index(), 0,
      'digest mismatch does not use index' );
   # After fallback, a new index for the new dump should be rewritten
   ok( -f $idx, 'index rewritten after fallback' );
}

# Recreate a clean dump+index for remaining cases
unlink $dump, $idx;
{
   our $Y = "parity-110";
   Devel::MAT::Dumper::dump($dump);
}
{
   local $ENV{PMAT_IDX} = '1';
   Devel::MAT::Core->load_full_parse($dump);
   ok( -f $idx, 'fresh index for corruption tests' );
}

# ---- Schema / magic rejection ----
{
   local $ENV{PMAT_BACKEND} = 'rust';
   local $ENV{PMAT_IDX} = '1';
   open my $fh, '>', $idx or die $!;
   print {$fh} "BADMAGIC" . ( "\0" x 100 );
   close $fh;

   my $core = Devel::MAT::Core->load($dump);
   ok( $core, 'bad magic falls back to full parse' );
   is( Devel::MAT::Core::last_load_used_index(), 0,
      'bad magic does not use index' );
}

# ---- Truncated / corrupt payload ----
{
   local $ENV{PMAT_BACKEND} = 'rust';
   local $ENV{PMAT_IDX} = '1';
   # Rebuild good index then truncate
   Devel::MAT::Core->load_full_parse($dump);
   ok( -f $idx && -s $idx > 100, 'good index for truncate' );

   open my $fh, '+<', $idx or die $!;
   my $sz = -s $idx;
   truncate $fh, int( $sz / 3 );
   close $fh;

   my $core = Devel::MAT::Core->load($dump);
   ok( $core, 'truncated index falls back to full parse' );
   is( Devel::MAT::Core::last_load_used_index(), 0,
      'truncated index not trusted' );
}

# ---- CRC / mid-file corruption (valid header, bad payload) ----
{
   local $ENV{PMAT_BACKEND} = 'rust';
   local $ENV{PMAT_IDX} = '1';
   Devel::MAT::Core->load_full_parse($dump);
   my $sz = -s $idx;
   cmp_ok( $sz, '>', 80, 'index large enough to corrupt middle' );

   open my $fh, '+<', $idx or die $!;
   binmode $fh;
   seek $fh, int( $sz / 2 ), 0;
   print {$fh} "\xFF" x 32;
   close $fh;

   my $core = Devel::MAT::Core->load($dump);
   ok( $core, 'garbled payload falls back' );
   is( Devel::MAT::Core::last_load_used_index(), 0,
      'corrupt payload not trusted' );
}

# ---- Never modifies the .pmat ----
{
   local $ENV{PMAT_IDX} = '1';
   open my $fh, '<:raw', $dump or die $!;
   local $/;
   my $before = <$fh>;
   close $fh;

   Devel::MAT::Core->load($dump);
   Devel::MAT::Core->load_full_parse($dump);

   open my $fh2, '<:raw', $dump or die $!;
   local $/;
   my $after = <$fh2>;
   close $fh2;
   is( $after, $before, 'index ops never modify source .pmat' );
}

# ---- Dumpfile forced-rust path still works with index ----
{
   local $ENV{PMAT_BACKEND} = 'rust';
   local $ENV{PMAT_IDX} = '1';
   unlink $idx if -e $idx;
   my $p1 = Devel::MAT->load($dump);
   ok( $p1->dumpfile->backend eq 'rust', 'dumpfile rust backend' );
   ok( -f $idx, 'Dumpfile load wrote index' );
   my $p2 = Devel::MAT->load($dump);
   is( Devel::MAT::Core::last_load_used_index(), 1,
      'Dumpfile second load used index' );
   is(
      scalar( $p2->dumpfile->heap ),
      scalar( $p1->dumpfile->heap ),
      'heap count matches across index reuse'
   );
}

# ---- PMAT_IDX=0 disables index ----
{
   local $ENV{PMAT_BACKEND} = 'rust';
   local $ENV{PMAT_IDX} = '0';
   unlink $idx if -e $idx;
   my $core = Devel::MAT::Core->load($dump);
   ok( $core, 'load with PMAT_IDX=0' );
   is( Devel::MAT::Core::last_load_used_index(), 0, 'index disabled: not used' );
   ok( !-f $idx, 'index not written when PMAT_IDX=0' );
}

done_testing;
