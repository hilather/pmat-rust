package PMAT::Bench::Tiers;
# Named size tiers for dump fixtures and benchmarks.
#
# Defaults favour fast iteration. Larger tiers (including multi-GB dumps up to
# the 17 GiB target) are opt-in via --size / PMAT_BENCH_SIZE.

use v5.14;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw( tier_names tier_info resolve_tiers all_tier_names );

# nodes: number of mixed-graph root objects for the "real" (Dumper) generator.
# Approx dump sizes from calibration on perl 5.38 / Devel-MAT 0.54:
#   nodes=0      ~3.5 MiB,  ~30k SVs  (process baseline)
#   nodes=1k     ~5.4 MiB,  ~55k SVs
#   nodes=10k    ~22 MiB,   ~280k SVs
#   nodes=50k    ~98 MiB,   ~1.3M SVs
#   nodes=100k   ~192 MiB,  ~2.5M SVs
#
# target_bytes: used by the synthetic bulk generator for huge dumps that
# would be impractical to allocate as a live perl process.

my %TIERS = (
   micro => {
      label           => "micro (unit-test / smoke)",
      nodes           => 200,
      shape           => "mixed",
      method          => "dumper",
      default_test    => 1,
      default_bench   => 0,
      # Rough expectations (loose; platforms differ)
      expect_dump_max => 8 * 1024 * 1024,
      expect_svs_min  => 20_000,
      gen_rss_hint_mb => 50,
   },
   small => {
      label           => "small (default bench iteration)",
      nodes           => 5_000,
      shape           => "mixed",
      method          => "dumper",
      default_test    => 0,
      default_bench   => 1,
      expect_dump_max => 30 * 1024 * 1024,
      expect_svs_min  => 100_000,
      gen_rss_hint_mb => 150,
   },
   medium => {
      label           => "medium",
      nodes           => 25_000,
      shape           => "mixed",
      method          => "dumper",
      default_test    => 0,
      default_bench   => 0,
      expect_dump_max => 120 * 1024 * 1024,
      expect_svs_min  => 500_000,
      gen_rss_hint_mb => 400,
   },
   large => {
      label           => "large",
      nodes           => 100_000,
      shape           => "mixed",
      method          => "dumper",
      default_test    => 0,
      default_bench   => 0,
      expect_dump_max => 250 * 1024 * 1024,
      expect_svs_min  => 2_000_000,
      gen_rss_hint_mb => 1_200,
   },
   xlarge => {
      label           => "xlarge",
      nodes           => 400_000,
      shape           => "mixed",
      method          => "dumper",
      default_test    => 0,
      default_bench   => 0,
      expect_dump_max => 1024 * 1024 * 1024,
      expect_svs_min  => 8_000_000,
      gen_rss_hint_mb => 4_000,
   },
   # Synthetic streaming dump: large on-disk size without allocating a
   # multi-GB live process. Good for load / I/O path and SV table scaling.
   # target 17 GiB mirrors the largest production process dumps we care about.
   huge => {
      label           => "huge (synthetic bulk, up to 17 GiB dump)",
      nodes           => 0,
      shape           => "bulk",
      method          => "synthetic",
      default_test    => 0,
      default_bench   => 0,
      # Default huge fixture is capped lower so a machine with free disk can
      # still opt in without writing 17 GiB by accident. Pass
      # --target-bytes=17G (or PMAT_HUGE_BYTES) for the full-size target.
      target_bytes    => 256 * 1024 * 1024,   # 256 MiB default for huge
      max_target_bytes => 17 * 1024 * 1024 * 1024,
      pv_bytes        => 4096,
      gen_rss_hint_mb => 200,
   },
);

sub all_tier_names {
   return qw( micro small medium large xlarge huge );
}

sub tier_names {
   my ( $which ) = @_;
   $which //= 'all';
   if ( $which eq 'default_bench' ) {
      return grep { $TIERS{$_}{default_bench} } all_tier_names();
   }
   if ( $which eq 'default_test' ) {
      return grep { $TIERS{$_}{default_test} } all_tier_names();
   }
   return all_tier_names();
}

sub tier_info {
   my ( $name ) = @_;
   my $t = $TIERS{$name} or die "Unknown tier '$name' (want: @{[all_tier_names()]})\n";
   return { name => $name, %$t };
}

# Resolve a comma/space separated size list, with aliases.
#   default | quick  -> default bench tiers
#   test             -> default test tiers
#   all              -> every tier
#   micro,small,...  -> explicit
#   17g / 17G        -> huge with 17 GiB target override
sub resolve_tiers {
   my ( $spec, %opts ) = @_;
   $spec //= $ENV{PMAT_BENCH_SIZE} // 'default';
   $spec =~ s/^\s+|\s+$//g;

   my @names;
   my %overrides; # tier => { field => value }

   for my $tok ( split /[\s,]+/, $spec ) {
      next unless length $tok;
      my $lc = lc $tok;

      if ( $lc eq 'default' || $lc eq 'quick' ) {
         push @names, tier_names('default_bench');
         next;
      }
      if ( $lc eq 'test' ) {
         push @names, tier_names('default_test');
         next;
      }
      if ( $lc eq 'all' ) {
         push @names, all_tier_names();
         next;
      }
      # 17g / 17gb / 17GiB -> huge at full production size
      if ( $lc =~ /^(\d+(?:\.\d+)?)(k|m|g|kb|mb|gb|kib|mib|gib)?$/ ) {
         my ( $n, $u ) = ( $1, lc( $2 // 'b' ) );
         my $mult = 1;
         $mult = 1024           if $u =~ /^k/;
         $mult = 1024**2        if $u =~ /^m/;
         $mult = 1024**3        if $u =~ /^g/;
         my $bytes = int( $n * $mult );
         push @names, 'huge';
         $overrides{huge}{target_bytes} = $bytes;
         next;
      }
      if ( exists $TIERS{$lc} ) {
         push @names, $lc;
         next;
      }
      die "Unknown size token '$tok'\n";
   }

   # de-dupe preserving order
   my %seen;
   @names = grep { !$seen{$_}++ } @names;

   if ( defined $opts{target_bytes} ) {
      $overrides{huge}{target_bytes} = $opts{target_bytes};
   }
   if ( defined $ENV{PMAT_HUGE_BYTES} && $ENV{PMAT_HUGE_BYTES} =~ /^\d+$/ ) {
      $overrides{huge}{target_bytes} = 0 + $ENV{PMAT_HUGE_BYTES};
   }

   my @tiers;
   for my $name ( @names ) {
      my $info = tier_info($name);
      if ( my $o = $overrides{$name} ) {
         @{$info}{ keys %$o } = values %$o;
      }
      if ( $name eq 'huge' && $info->{target_bytes} > $info->{max_target_bytes} ) {
         die sprintf(
            "huge target_bytes %d exceeds max %d (17 GiB)\n",
            $info->{target_bytes}, $info->{max_target_bytes}
         );
      }
      push @tiers, $info;
   }
   return @tiers;
}

1;
