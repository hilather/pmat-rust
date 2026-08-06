package PMAT::Bench::Fixture;
# Generate and locate .pmat fixtures for tests and benchmarks.

use v5.14;
use warnings;

use Cwd ();
use File::Basename qw( dirname );
use File::Path qw( make_path );
use File::Spec;
use JSON::PP ();
use Time::HiRes qw( time );

use PMAT::Bench::Tiers qw( tier_info );
use PMAT::Bench::Util qw( format_bytes rss_kb timed );

sub fixtures_dir {
   my ( $class, $override ) = @_;
   return File::Spec->rel2abs($override)
      if defined $override && length $override;
   return File::Spec->rel2abs( $ENV{PMAT_FIXTURES} )
      if defined $ENV{PMAT_FIXTURES} && length $ENV{PMAT_FIXTURES};
   # repo_root/fixtures  (this file is bench/lib/PMAT/Bench/Fixture.pm)
   my $here = File::Spec->rel2abs( dirname( __FILE__ ) );
   my $root = File::Spec->catdir( $here, ( File::Spec->updir ) x 4 );
   return File::Spec->catdir( Cwd::realpath($root) // File::Spec->canonpath($root), 'fixtures' );
}

sub fixture_path {
   my ( $class, $tier_name, %opts ) = @_;
   my $dir = $class->fixtures_dir( $opts{dir} );
   my $info = ref $tier_name ? $tier_name : tier_info($tier_name);
   my $name = $info->{name};

   if ( $info->{method} eq 'synthetic' ) {
      my $tb = $info->{target_bytes} // 0;
      return File::Spec->catfile( $dir, sprintf( "%s-%s.pmat", $name, _bytes_tag($tb) ) );
   }
   my $shape = $info->{shape} // 'mixed';
   my $nodes = $info->{nodes} // 0;
   return File::Spec->catfile( $dir, sprintf( "%s-%s-n%d.pmat", $name, $shape, $nodes ) );
}

sub meta_path {
   my ( $class, $pmat_path ) = @_;
   return $pmat_path . ".meta.json";
}

sub ensure {
   my ( $class, $tier, %opts ) = @_;
   $tier = tier_info($tier) unless ref $tier;
   my $path = $class->fixture_path( $tier, %opts );
   my $meta_path = $class->meta_path($path);

   if ( -f $path && -f $meta_path && !$opts{force} ) {
      my $meta = _load_json($meta_path);
      if ( $class->_meta_matches( $meta, $tier ) ) {
         return ( $path, $meta );
      }
   }

   make_path( dirname($path) );
   my $meta = $class->generate( $tier, $path, %opts );
   _write_json( $meta_path, $meta );
   return ( $path, $meta );
}

sub _meta_matches {
   my ( $class, $meta, $tier ) = @_;
   return 0 unless $meta && $meta->{tier} eq $tier->{name};
   return 0 unless ( $meta->{method} // '' ) eq ( $tier->{method} // '' );
   if ( $tier->{method} eq 'synthetic' ) {
      return 0 unless ( $meta->{target_bytes} // 0 ) == ( $tier->{target_bytes} // 0 );
   }
   else {
      return 0 unless ( $meta->{nodes} // -1 ) == ( $tier->{nodes} // -1 );
      return 0 unless ( $meta->{shape} // '' ) eq ( $tier->{shape} // '' );
   }
   return 1;
}

sub generate {
   my ( $class, $tier, $path, %opts ) = @_;
   $tier = tier_info($tier) unless ref $tier;

   my $method = $tier->{method} // 'dumper';
   if ( $method eq 'dumper' ) {
      return $class->_generate_dumper( $tier, $path, %opts );
   }
   if ( $method eq 'synthetic' ) {
      return $class->_generate_synthetic( $tier, $path, %opts );
   }
   die "Unknown fixture method '$method'\n";
}

# ---------------------------------------------------------------------------
# Real dumps via Devel::MAT::Dumper (connected graph, realistic tool workload)
# ---------------------------------------------------------------------------

sub _generate_dumper {
   my ( $class, $tier, $path, %opts ) = @_;

   require Devel::MAT::Dumper;

   my $nodes = $tier->{nodes} // 0;
   my $shape = $tier->{shape} // 'mixed';
   my $progress = $opts{progress};

   $progress->( sprintf(
      "Building %s fixture: shape=%s nodes=%d (hint ~%s RSS to generate)...",
      $tier->{name}, $shape, $nodes, format_bytes( ( $tier->{gen_rss_hint_mb} // 0 ) * 1024 * 1024 )
   ) ) if $progress;

   # Build payload under a main:: global so it is rooted and easy to find.
   {
      no strict 'refs';
      *{"main::PMAT_BENCH_ROOT"} = \ _build_shape( $shape, $nodes, $progress );
   }

   $progress->( "Writing dump to $path ..." ) if $progress;
   my ( $tinfo ) = timed {
      Devel::MAT::Dumper::dump($path);
   };

   # Drop payload before returning so the parent process can free memory.
   {
      no strict 'refs';
      *{"main::PMAT_BENCH_ROOT"} = \undef;
      delete $main::{PMAT_BENCH_ROOT};
   }

   my $size = -s $path;
   my $meta = {
      tier          => $tier->{name},
      method        => 'dumper',
      shape         => $shape,
      nodes         => $nodes,
      path          => $path,
      bytes         => $size,
      generate_s    => $tinfo->{seconds},
      generate_rss_kb => $tinfo->{rss_kb},
      created_unix  => time(),
      perl          => "$]",
      dumper        => do {
         my $v = eval { $Devel::MAT::Dumper::VERSION };
         defined $v ? "$v" : 'unknown';
      },
   };

   # Optional heap SV count without forcing tools: light load in a child would
   # be ideal; for simplicity count after load when requested.
   if ( $opts{count_svs} ) {
      require Devel::MAT;
      my $pmat = Devel::MAT->load( $path, progress => $progress );
      $meta->{heap_svs} = scalar $pmat->dumpfile->heap;
   }

   $progress->( sprintf(
      "Wrote %s (%s) in %s",
      $path, format_bytes($size),
      sprintf( "%.2fs", $tinfo->{seconds} // 0 ),
   ) ) if $progress;

   return $meta;
}

sub _build_shape {
   my ( $shape, $nodes, $progress ) = @_;

   if ( $shape eq 'mixed' ) {
      # Nested hashes/arrays: good connectivity for inrefs/reachability/identify.
      my @root;
      for my $i ( 1 .. $nodes ) {
         push @root, {
            id   => $i,
            data => [ map { "x$i-$_" } 0 .. 9 ],
            nest => { a => [ 1 .. 5 ], b => "val$i" },
         };
         if ( $progress && ( $i % 50_000 ) == 0 ) {
            $progress->( sprintf( "  built %d / %d nodes", $i, $nodes ) );
         }
      }
      return \@root;
   }

   if ( $shape eq 'wide' ) {
      # One large array of small scalars — stresses heap table size.
      return [ map { $_ } 1 .. $nodes ];
   }

   if ( $shape eq 'deep' ) {
      # Linked list of refs — deep identify / graph walks.
      my $head;
      for my $i ( 1 .. $nodes ) {
         $head = { i => $i, next => $head };
      }
      return $head;
   }

   if ( $shape eq 'pv' ) {
      # Few SVs, large string bodies — dump I/O and PV load path.
      my $chunk = 64 * 1024;
      my $n_pvs = $nodes > 0 ? $nodes : 16;
      return [ map { "P" x $chunk } 1 .. $n_pvs ];
   }

   die "Unknown shape '$shape' (want mixed|wide|deep|pv)\n";
}

# ---------------------------------------------------------------------------
# Synthetic bulk dumps (streaming, low generator RSS, large on-disk size)
# ---------------------------------------------------------------------------

sub _generate_synthetic {
   my ( $class, $tier, $path, %opts ) = @_;

   my $target   = $tier->{target_bytes} // ( 256 * 1024 * 1024 );
   my $pv_bytes = $tier->{pv_bytes} // 4096;
   my $progress = $opts{progress};

   $progress->( sprintf(
      "Writing synthetic bulk fixture %s (target %s, pv %s)...",
      $path, format_bytes($target), format_bytes($pv_bytes)
   ) ) if $progress;

   my ( $tinfo, $meta_extra ) = timed {
      _write_synthetic_pmat(
         $path,
         target_bytes => $target,
         pv_bytes     => $pv_bytes,
         progress     => $progress,
      );
   };

   my $size = -s $path;
   return {
      tier            => $tier->{name},
      method          => 'synthetic',
      shape           => 'bulk',
      target_bytes    => $target,
      pv_bytes        => $pv_bytes,
      path            => $path,
      bytes           => $size,
      heap_svs        => $meta_extra->{heap_svs},
      generate_s      => $tinfo->{seconds},
      generate_rss_kb => $tinfo->{rss_kb},
      created_unix    => time(),
      perl            => "$]",
      %$meta_extra,
   };
}

# Write a minimal but valid PMAT 0.6 dump: immortal roots + one root ARRAY
# holding N SCALAR PVs. Streams to disk so generator RSS stays low.
sub _write_synthetic_pmat {
   my ( $path, %args ) = @_;
   my $target   = $args{target_bytes};
   my $pv_bytes = $args{pv_bytes};
   my $progress = $args{progress};

   open my $fh, '>:raw', $path or die "Cannot write $path: $!\n";

   my $little = 1; # pack endian
   my $flags  = 0x02 | 0x04; # 64-bit UV/IV and PTR, little-endian, no long double
   # Magic + flags + zero + format 0.6 + perlver
   print {$fh} "PMAT";
   print {$fh} pack( 'C', $flags );
   print {$fh} pack( 'C', 0 );
   print {$fh} pack( 'C', 0 ); # major
   print {$fh} pack( 'C', 6 ); # minor
   # Fake a 5.38.2-ish perlver: rev<<24 | ver<<16 | sub
   print {$fh} pack( 'L<', ( 5 << 24 ) | ( 38 << 16 ) | 2 );

   # Type size table — must match layouts we emit below.
   # Indices from Devel::MAT.xs / format.txt:
   #  0 common, 1 GLOB, 2 SCALAR, 3 REF, 4 ARRAY, 5 HASH, ...
   #  13 UNDEF, 14 YES, 15 NO
   my @types = (
      # header_bytes, nptrs, nstrs
      [ 20, 1, 0 ], # 0 common: PTR addr, U32 refcnt, UINT size + PTR blessed
      [ 16, 8, 2 ], # 1 GLOB (unused)
      [ 25, 1, 1 ], # 2 SCALAR
      [  1, 2, 0 ], # 3 REF
      [  9, 0, 0 ], # 4 ARRAY (+ body of COUNT ptrs)
      [  8, 1, 0 ], # 5 HASH (unused)
      [  8, 5, 1 ], # 6 STASH
      [ 29, 5, 2 ], # 7 CODE
      [ 16, 3, 0 ], # 8 IO
      [ 17, 1, 0 ], # 9 LVALUE
      [  0, 0, 0 ], # 10 REGEXP
      [  0, 0, 0 ], # 11 FORMAT
      [  0, 0, 0 ], # 12 INVLIST
      [  0, 0, 0 ], # 13 UNDEF
      [  0, 0, 0 ], # 14 YES
      [  0, 0, 0 ], # 15 NO
      [  8, 0, 0 ], # 16 OBJECT
      [  8, 6, 1 ], # 17 CLASS
   );
   print {$fh} pack( 'C', scalar @types );
   for my $t ( @types ) {
      print {$fh} pack( 'C3', @$t );
   }

   # Extensions (declare the usual set so minor=6 readers are happy; unused)
   my @ext = (
      [ 2, 3, 0 ], # 0x80 MAGIC
      [ 0, 1, 0 ], # 0x81 SAVED_SV
      [ 0, 1, 0 ],
      [ 0, 1, 0 ],
      [ 8, 1, 0 ],
      [ 0, 2, 0 ],
      [ 0, 1, 0 ],
      [ 0, 1, 1 ],
      [ 16, 0, 1 ],
      [ 8, 0, 0 ],
      [ 20, 5, 0 ],
   );
   print {$fh} pack( 'C', scalar @ext );
   print {$fh} pack( 'C3', @$_ ) for @ext;

   # Contexts
   my @ctx = (
      [ 9, 0, 1 ], # common
      [ 4, 2, 0 ], # SUB
      [ 0, 0, 0 ], # TRY
      [ 0, 1, 0 ], # EVAL
   );
   print {$fh} pack( 'C', scalar @ctx );
   print {$fh} pack( 'C3', @$_ ) for @ctx;

   # Addresses (unique fake heap pointers)
   my $ADDR_UNDEF = 0x1000;
   my $ADDR_YES   = 0x1008;
   my $ADDR_NO    = 0x1010;
   my $ADDR_ROOT  = 0x2000;  # root ARRAY
   my $ADDR_BASE  = 0x10000; # first SCALAR

   # Estimate bytes per SCALAR SV record so we can plan N.
   # type(1) + common(20+8) + scalar(25+8) + str(8+pv_bytes)
   my $per_scalar = 1 + 28 + 33 + 8 + $pv_bytes;
   # type + common + array header + N ptrs, plus overhead for roots/header (~4k)
   my $overhead = 4096 + 1 + 28 + 9; # rough
   my $n = int( ( $target - $overhead ) / ( $per_scalar + 8 ) );
   $n = 1 if $n < 1;

   # Roots: undef/yes/no + named root pointing at our ARRAY
   print {$fh} pack( 'Q<', $ADDR_UNDEF );
   print {$fh} pack( 'Q<', $ADDR_YES );
   print {$fh} pack( 'Q<', $ADDR_NO );
   print {$fh} pack( 'L<', 1 ); # nroots
   _write_str( $fh, "defstash" ); # any name; used as a strong-ish root label
   print {$fh} pack( 'Q<', $ADDR_ROOT );

   # Empty stack
   print {$fh} pack( 'Q<', 0 );

   # Heap SVs
   _write_immortal( $fh, 13, $ADDR_UNDEF, 1 );
   _write_immortal( $fh, 14, $ADDR_YES,   1 );
   _write_immortal( $fh, 15, $ADDR_NO,    1 );

   # Root ARRAY of N elements
   _write_array( $fh, $ADDR_ROOT, [ map { $ADDR_BASE + $_ * 0x20 } 0 .. $n - 1 ] );

   my $pv = "B" x $pv_bytes;
   my $report_every = $n > 1000 ? int( $n / 20 ) : $n;
   $report_every = 1 if $report_every < 1;

   for my $i ( 0 .. $n - 1 ) {
      my $addr = $ADDR_BASE + $i * 0x20;
      _write_scalar_pv( $fh, $addr, $pv );
      if ( $progress && ( ( $i + 1 ) % $report_every ) == 0 ) {
         my $pos = tell($fh);
         $progress->( sprintf(
            "  synthetic %d / %d SVs (%.1f%% of target bytes)",
            $i + 1, $n, 100 * $pos / $target
         ) );
      }
   }

   # End of heap
   print {$fh} pack( 'C', 0 );
   # End of contexts
   print {$fh} pack( 'C', 0 );
   # Mortals count = 0
   print {$fh} pack( 'Q<', 0 );

   close $fh;

   # If we undershot/overshot badly, that's fine — target is a guide.
   my $size = -s $path;
   $progress->( sprintf(
      "Synthetic dump done: %s, %d scalar SVs (+4 structural)",
      format_bytes($size), $n
   ) ) if $progress;

   return {
      heap_svs     => $n + 4, # scalars + undef/yes/no + array
      scalar_svs   => $n,
      bytes_planned => $target,
   };
}

sub _write_str {
   my ( $fh, $s ) = @_;
   print {$fh} pack( 'Q<', length($s) );
   print {$fh} $s;
}

sub _write_common {
   my ( $fh, $addr, $refcnt, $size ) = @_;
   # 20 header bytes: PTR + U32 + UINT, then 1 ptr blessed=0
   print {$fh} pack( 'Q<', $addr );
   print {$fh} pack( 'L<', $refcnt );
   print {$fh} pack( 'Q<', $size );
   print {$fh} pack( 'Q<', 0 ); # blessed
}

sub _write_immortal {
   my ( $fh, $type, $addr, $refcnt ) = @_;
   print {$fh} pack( 'C', $type );
   _write_common( $fh, $addr, $refcnt, 24 );
}

sub _write_scalar_pv {
   my ( $fh, $addr, $pv ) = @_;
   print {$fh} pack( 'C', 2 ); # SCALAR
   _write_common( $fh, $addr, 1, 40 + length($pv) );
   # flags: has STR (0x08)
   print {$fh} pack( 'C', 0x08 );
   print {$fh} pack( 'Q<', 0 );       # IV
   print {$fh} pack( 'd<', 0.0 );     # NV
   print {$fh} pack( 'Q<', length($pv) ); # PVLEN
   print {$fh} pack( 'Q<', 0 );       # OURSTASH
   _write_str( $fh, $pv );
}

sub _write_array {
   my ( $fh, $addr, $elems ) = @_;
   my $n = scalar @$elems;
   print {$fh} pack( 'C', 4 ); # ARRAY
   _write_common( $fh, $addr, 1, 64 + 8 * $n );
   print {$fh} pack( 'Q<', $n ); # COUNT
   print {$fh} pack( 'C', 0 );   # FLAGS (REAL)
   print {$fh} pack( 'Q<*', @$elems );
}

sub _write_json {
   my ( $path, $data ) = @_;
   open my $fh, '>', $path or die "Cannot write $path: $!\n";
   print {$fh} JSON::PP->new->canonical(1)->pretty(1)->encode($data);
   close $fh;
}

sub _load_json {
   my ( $path ) = @_;
   open my $fh, '<', $path or return undef;
   local $/;
   my $raw = <$fh>;
   close $fh;
   return JSON::PP->new->decode($raw);
}

sub _bytes_tag {
   my ( $n ) = @_;
   return "0" unless $n;
   if ( $n >= 1024**3 && ( $n % (1024**3) ) == 0 ) {
      return sprintf( "%dG", $n / (1024**3) );
   }
   if ( $n >= 1024**2 && ( $n % (1024**2) ) == 0 ) {
      return sprintf( "%dM", $n / (1024**2) );
   }
   if ( $n >= 1024 && ( $n % 1024 ) == 0 ) {
      return sprintf( "%dK", $n / 1024 );
   }
   return "${n}B";
}

1;
