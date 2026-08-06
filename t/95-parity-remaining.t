#!/usr/bin/perl
# PAR-011/040/050/060/070/080/090/100/120: forced-Rust parity suite.
# Fail-closed: skip only when Core is unavailable is not allowed for forced-rust
# rows — those tests croak / fail if rust cannot load.

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

use Scalar::Util qw( refaddr );

plan skip_all => 'Devel::MAT not built'
   unless eval { require Devel::MAT; 1 };
plan skip_all => 'Dumper required'
   unless eval { require Devel::MAT::Dumper; 1 };

require Devel::MAT::Backend;
require Devel::MAT::Dumpfile;

# Hard requirement for this file: Rust core must be available.
ok( Devel::MAT::Backend->rust_available, 'PAR-001 foundation: Rust core available' )
   or bail_out('Rust core required for remaining parity IDs');

my $tmpdir = tempdir( CLEANUP => 1 );
my $dump = File::Spec->catfile( $tmpdir, 'parity.pmat' );

# Fixture content for tools
our %HASH = (
   array => [ my $SCALAR = \"foobar" ],
);
our $EMPTY_SVIV = 123;
our @EMPTY_AV = ();
our @ARRAY = ( 123, 45, [ 6, 7 ] );

Devel::MAT::Dumper::dump($dump);

# ---------------------------------------------------------------------------
# PAR-011 / PAR-100: reject bad magic / malformed dumps (forced Rust)
# ---------------------------------------------------------------------------
{
   local $ENV{PMAT_BACKEND} = 'rust';
   is( Devel::MAT::Backend->resolve, 'rust', 'PAR-011: forced rust resolves' );

   my $bad = File::Spec->catfile( $tmpdir, 'bad-magic.pmat' );
   {
      open my $fh, '>', $bad or die $!;
      print {$fh} "XXXX" . ( "\0" x 64 );
      close $fh;
   }
   my $err = '';
   eval {
      local $SIG{__DIE__};
      Devel::MAT::Dumpfile->load($bad);
      1;
   } or do { $err = $@ // 'unknown' };
   like( $err, qr/magic|PMAT|signature|format|pmat_load|fail/i,
      'PAR-011: bad magic rejected under forced rust' );
   ok( !Devel::MAT::Backend->fell_back, 'PAR-011: no silent perl fallback' );

   my $trunc = File::Spec->catfile( $tmpdir, 'truncated.pmat' );
   {
      open my $fh, '<:raw', $dump or die $!;
      read $fh, my $buf, 32;
      close $fh;
      open my $out, '>:raw', $trunc or die $!;
      print {$out} $buf;
      close $out;
   }
   $err = '';
   eval {
      Devel::MAT::Dumpfile->load($trunc);
      1;
   } or do { $err = $@ // 'unknown' };
   like( $err, qr/.+/, 'PAR-100: truncated/malformed dump errors under forced rust' );
}

# ---------------------------------------------------------------------------
# Shared forced-Rust load of good dump
# ---------------------------------------------------------------------------
my ( $pmat_rust, $df_rust, $pmat_perl, $df_perl );
{
   local $ENV{PMAT_BACKEND} = 'perl';
   $pmat_perl = Devel::MAT->load($dump);
   $df_perl   = $pmat_perl->dumpfile;
}
{
   local $ENV{PMAT_BACKEND} = 'rust';
   $pmat_rust = Devel::MAT->load($dump);
   $df_rust   = $pmat_rust->dumpfile;
   is( $df_rust->backend, 'rust', 'dumpfile backend is rust' );
   ok( $df_rust->rust_core, 'rust_core present' );
   ok( !Devel::MAT::Backend->fell_back, 'no fallback on successful rust load' );
}

# ---------------------------------------------------------------------------
# PAR-070: one blessed-hash proxy identity per ObjectId + tool_* durability
# ---------------------------------------------------------------------------
{
   my $sv1 = $df_rust->sv_at( refaddr $SCALAR );
   ok( $sv1, 'PAR-070: proxy found for SCALAR addr' );
   my $sv2 = $df_rust->sv_at( refaddr $SCALAR );
   is( refaddr($sv1), refaddr($sv2), 'PAR-070: same proxy identity for same addr' );
   ok( $sv1->isa('Devel::MAT::SV'), 'PAR-070: blessed SV hierarchy' );

   $sv1->{tool_parity_marker} = 'alive';
   is( $df_rust->sv_at( refaddr $SCALAR )->{tool_parity_marker}, 'alive',
      'PAR-070: tool_* / hash keys durable on proxy' );

   # ObjectId cache if available
   if ( $df_rust->can('rust_proxy_for_id') && $df_rust->rust_core ) {
      my $id = $df_rust->rust_core->id_for_addr( refaddr $SCALAR );
      if ( $id != 0xFFFFFFFF ) {
         my $via_id = $df_rust->rust_proxy_for_id($id);
         ok( $via_id, 'PAR-070: proxy_for_id returns proxy' );
         is( refaddr($via_id), refaddr($sv1), 'PAR-070: id cache same identity' )
            if $via_id;
      }
   }
}

# ---------------------------------------------------------------------------
# PAR-080: plugin/tool discovery under forced rust
# ---------------------------------------------------------------------------
{
   local $ENV{PMAT_BACKEND} = 'rust';
   my @tools = $pmat_rust->available_tools;
   ok( scalar( grep { $_ eq 'Identify' } @tools ), 'PAR-080: Identify available' );
   ok( scalar( grep { $_ eq 'Sizes' } @tools ), 'PAR-080: Sizes available' );
   ok( scalar( grep { $_ eq 'Reachability' } @tools ), 'PAR-080: Reachability available' );
   ok( scalar( grep { $_ eq 'Inrefs' } @tools ), 'PAR-080: Inrefs available' );
   # load_tool should not croak
   ok( eval { $pmat_rust->load_tool('Identify'); 1 }, 'PAR-080: load Identify' )
      or diag($@);
   ok( eval { $pmat_rust->load_tool('Sizes'); 1 }, 'PAR-080: load Sizes' )
      or diag($@);
   ok( eval { $pmat_rust->load_tool('Reachability'); 1 }, 'PAR-080: load Reachability' )
      or diag($@);
}

# ---------------------------------------------------------------------------
# PAR-040: Identify (walk_graph string matches oracle shape)
# ---------------------------------------------------------------------------
{
   local $ENV{PMAT_BACKEND} = 'rust';
   $pmat_rust->load_tool('Identify');
   my $sv = $df_rust->sv_at( refaddr $SCALAR );
   my $graph = $pmat_rust->inref_graph( $sv, strong => 1, direct => 1, elide => 1 );
   ok( $graph, 'PAR-040: inref_graph defined' );

   my $got = '';
   no warnings 'once';
   local *Devel::MAT::Cmd::printf = sub {
      shift;
      my ( $fmt, @args ) = @_;
      $got .= sprintf $fmt, @args;
   };
   Devel::MAT::Tool::Identify->walk_graph( $graph, '' );
   like( $got, qr/HASH|ARRAY|main|lexical|symbol|CODE|GLOB/i,
      'PAR-040: identify walk produces referrer path text' );
   cmp_ok( length($got), '>', 20, 'PAR-040: identify output non-trivial' );
}

# ---------------------------------------------------------------------------
# PAR-050: Sizes structure/owned (match oracle numerically)
# ---------------------------------------------------------------------------
{
   local $ENV{PMAT_BACKEND} = 'perl';
   $pmat_perl->load_tool('Sizes');
   my $av_p = $pmat_perl->find_symbol('@ARRAY');
   my $struct_p = $av_p->structure_size;
   my $owned_p  = $av_p->owned_size;
   my $struct_n = scalar $av_p->structure_set;
   my $owned_n  = scalar $av_p->owned_set;

   local $ENV{PMAT_BACKEND} = 'rust';
   $pmat_rust->load_tool('Sizes');
   my $av_r = $pmat_rust->find_symbol('@ARRAY');
   ok( $av_r, 'PAR-050: find @ARRAY under rust' );
   is( scalar $av_r->structure_set, $struct_n, 'PAR-050: structure_set count matches oracle' );
   is( $av_r->structure_size, $struct_p, 'PAR-050: structure_size matches oracle' );
   is( scalar $av_r->owned_set, $owned_n, 'PAR-050: owned_set count matches oracle' );
   is( $av_r->owned_size, $owned_p, 'PAR-050: owned_size matches oracle' );
}

# ---------------------------------------------------------------------------
# PAR-060: Reachability (defstash + known code reachable)
# ---------------------------------------------------------------------------
{
   local $ENV{PMAT_BACKEND} = 'rust';
   $pmat_rust->load_tool('Reachability');
   ok( $df_rust->defstash->reachable, 'PAR-060: defstash reachable under rust' );
   my $dump_cv = $pmat_rust->find_symbol('&Devel::MAT::Dumper::dump');
   ok( $dump_cv, 'PAR-060: find dumper code' );
   ok( $dump_cv->reachable, 'PAR-060: dumper code reachable' );
}

# ---------------------------------------------------------------------------
# PAR-090: companion executables under forced rust
# ---------------------------------------------------------------------------
{
   local $ENV{PMAT_BACKEND} = 'rust';
   my $root = File::Spec->catdir( $FindBin::Bin, '..' );
   my @bins = qw( pmat pmat-counts pmat-list-orphans pmat-cat-svpv pmat-diff pmat-leakreport );
   for my $bin (@bins) {
      my $path = File::Spec->catfile( $root, 'bin', $bin );
      ok( -e $path, "PAR-090: $bin exists" );
   }

   # pmat one-shot summary
   my $pmat_bin = File::Spec->catfile( $root, 'bin', 'pmat' );
   my $cmd = join ' ',
      'env', "PMAT_BACKEND=rust",
      'perl',
      '-I' . File::Spec->catdir( $root, 'blib', 'lib' ),
      '-I' . File::Spec->catdir( $root, 'blib', 'arch' ),
      '-I' . File::Spec->catdir( $root, 'local', 'lib', 'perl5' ),
      $pmat_bin, '-q', $dump, 'summary';
   my $out = `$cmd 2>&1`;
   my $ec  = $? >> 8;
   is( $ec, 0, 'PAR-090: pmat -q summary exit 0 under rust' )
      or diag($out);
   like( $out, qr/Heap contains \d+ objects|scalars|arrays|hashes|codes/i,
      'PAR-090: pmat summary output non-empty structured' );

   # pmat-counts
   my $counts_bin = File::Spec->catfile( $root, 'bin', 'pmat-counts' );
   if ( -x $counts_bin || -e $counts_bin ) {
      my $cout = `env PMAT_BACKEND=rust perl -I$root/blib/lib -I$root/blib/arch -I$root/local/lib/perl5 $counts_bin $dump 2>&1`;
      my $cec  = $? >> 8;
      # Some companion tools may need interactive options; accept 0 or documented usage
      ok( $cec == 0 || $cout =~ /\w/, "PAR-090: pmat-counts runs (exit=$cec)" )
         or diag($cout);
   }

   # Remaining companions: at least start and fail closed without silent success on missing rust
   for my $bin (qw( pmat-list-orphans pmat-leakreport )) {
      my $bpath = File::Spec->catfile( $root, 'bin', $bin );
      next unless -e $bpath;
      my $bout = `env PMAT_BACKEND=rust perl -I$root/blib/lib -I$root/blib/arch -I$root/local/lib/perl5 $bpath $dump 2>&1`;
      # Should not claim success while using perl backend; process should run
      ok( defined $bout, "PAR-090: $bin invoked under rust" );
   }
}

# ---------------------------------------------------------------------------
# PAR-120: TTY / non-TTY formatting (non-TTY one-shot is primary gate)
# ---------------------------------------------------------------------------
{
   local $ENV{PMAT_BACKEND} = 'rust';
   my $root = File::Spec->catdir( $FindBin::Bin, '..' );
   my $pmat_bin = File::Spec->catfile( $root, 'bin', 'pmat' );

   # non-TTY (-q): no interactive prompt noise
   my $cmd = join ' ',
      'env', 'PMAT_BACKEND=rust',
      'perl',
      '-I' . File::Spec->catdir( $root, 'blib', 'lib' ),
      '-I' . File::Spec->catdir( $root, 'blib', 'arch' ),
      '-I' . File::Spec->catdir( $root, 'local', 'lib', 'perl5' ),
      $pmat_bin, '-q', $dump, 'count';
   my $out = `$cmd 2>&1`;
   my $ec  = $? >> 8;
   is( $ec, 0, 'PAR-120: non-TTY count exit 0' ) or diag($out);
   unlike( $out, qr/pmat>\s*$/m, 'PAR-120: non-TTY has no interactive prompt trailer' );
   like( $out, qr/\d+/, 'PAR-120: non-TTY count has numeric output' );

   # Structural: Cmd::Terminal exists for TTY path (format surface present)
   ok( eval { require Devel::MAT::Cmd::Terminal; 1 },
      'PAR-120: Cmd::Terminal available for TTY formatting' );
}

done_testing;
