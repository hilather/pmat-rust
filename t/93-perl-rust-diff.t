#!/usr/bin/perl
# PAR-010/020/030/031: differential load + type counts + edge multisets vs oracle.

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

plan skip_all => 'Devel::MAT not built'
   unless eval { require Devel::MAT; 1 };
plan skip_all => 'Dumper required for micro fixture'
   unless eval { require Devel::MAT::Dumper; 1 };

require Devel::MAT::Backend;

my $tmpdir = File::Spec->catdir( $FindBin::Bin, '..', 'fixtures' );
my ( $tier ) = resolve_tiers('micro');
my ( $path ) = PMAT::Bench::Fixture->ensure( $tier, dir => $tmpdir );

# ---- Forced Perl (oracle) ----
my $perl;
my $perl_df;
{
   local $ENV{PMAT_BACKEND} = 'perl';
   is( Devel::MAT::Backend->resolve, 'perl', 'forced perl' );
   $perl_df = Devel::MAT->load($path)->dumpfile;
   $perl = capture($perl_df);
}

ok( $perl->{heap_svs} > 1000, 'perl heap non-trivial' );

# ---- Forced Rust ----
SKIP: {
   skip 'Rust core not available', 20 unless Devel::MAT::Backend->rust_available;

   local $ENV{PMAT_BACKEND} = 'rust';
   is( Devel::MAT::Backend->resolve, 'rust', 'forced rust resolves' );
   ok( !Devel::MAT::Backend->fell_back, 'forced rust did not fall back' );

   my $pmat = Devel::MAT->load($path);
   my $df   = $pmat->dumpfile;
   is( $df->backend, 'rust', 'dumpfile backend rust' );
   ok( $df->rust_core, 'rust_core handle present' );

   my $rust = capture($df);
   my $core = $df->rust_core;

   is( $rust->{heap_svs}, $perl->{heap_svs}, 'heap SV count matches' );
   is( $rust->{format_minor}, $perl->{format_minor}, 'format minor matches' );

   is(
      [ sort @{ $rust->{root_names} } ],
      [ sort @{ $perl->{root_names} } ],
      'root names match'
   );

   # Type counts from Core batch vs perl reclass aggregates
   my $rtc = $core->type_counts;
   my %by_code = map { 0 + $_ => $rtc->{$_} } keys %$rtc;

   is( $by_code{3} // 0, $perl->{type_counts}{REF} // 0, 'REF count' );
   is( $by_code{5} // 0, $perl->{type_counts}{HASH} // 0, 'HASH count' );
   is( $by_code{7} // 0, $perl->{type_counts}{CODE} // 0, 'CODE count' );
   is( $by_code{1} // 0, $perl->{type_counts}{GLOB} // 0, 'GLOB count' );
   is( $by_code{6} // 0, $perl->{type_counts}{STASH} // 0, 'STASH count' );

   {
      my $p_arr = ( $perl->{type_counts}{ARRAY} // 0 )
                + ( $perl->{type_counts}{PAD} // 0 )
                + ( $perl->{type_counts}{PADLIST} // 0 )
                + ( $perl->{type_counts}{PADNAMES} // 0 );
      is( $by_code{4} // 0, $p_arr, 'ARRAY file-type (+PAD*)' );

      my $rust_sc = ( $by_code{2} // 0 ) + ( $by_code{14} // 0 ) + ( $by_code{15} // 0 );
      my $perl_sc = ( $perl->{type_counts}{SCALAR} // 0 )
                  + ( $perl->{type_counts}{BOOL} // 0 );
      cmp_ok( abs( $rust_sc - $perl_sc ), '<=', 8,
         "SCALAR-ish within 8 (rust=$rust_sc perl=$perl_sc)" );
   }

   cmp_ok( $core->forward_edge_count, '>', 0, 'forward edges built' );
   is( $core->forward_edge_count, $core->reverse_edge_count,
      'forward/reverse edge counts equal' );

   # Immortal addresses (oracle special-cases these outside heap)
   my $undef_at = $perl_df->{undef_at};
   my $yes_at   = $perl_df->{yes_at};
   my $no_at    = $perl_df->{no_at};
   ok( defined $undef_at && $core->id_for_addr($undef_at) != 0xFFFFFFFF,
      'immortal undef has ObjectId for edge resolution' );
   ok( $core->id_for_addr($yes_at) != 0xFFFFFFFF, 'immortal yes has ObjectId' );
   ok( $core->id_for_addr($no_at) != 0xFFFFFFFF, 'immortal no has ObjectId' );

   # ---- PAR-030: outrefs_direct multiset (target addr + strength) ----
   # GLOBs: full structural model matches 0.54 _outrefs (egv weak-if-self).
   my ( $glob_ok, $glob_n, $glob_mismatch ) = ( 0, 0, undef );
   my $imm_perl = 0;
   my $imm_rust = 0;
   my %imm = map { $_ => 1 } ( $undef_at, $yes_at, $no_at );

   for my $sv ( $perl_df->heap ) {
      my $addr = $sv->addr;
      my $id   = $core->id_for_addr($addr);
      next if $id == 0xFFFFFFFF;

      my @perl_edges = perl_direct_edges($sv);
      my @rust_edges = rust_direct_edges( $core, $id );

      for my $e ( @perl_edges ) {
         $imm_perl++ if $imm{ $e->[0] };
      }
      for my $e ( @rust_edges ) {
         $imm_rust++ if $imm{ $e->[0] };
      }

      next unless $sv->type eq 'GLOB';
      $glob_n++;
      my $pm = multiset_of(@perl_edges);
      my $rm = multiset_of(@rust_edges);
      if ( multisets_equal( $pm, $rm ) ) {
         $glob_ok++;
      }
      elsif ( !defined $glob_mismatch ) {
         $glob_mismatch = {
            addr  => sprintf( '%#x', $addr ),
            perl  => [ sort keys %$pm ],
            rust  => [ sort keys %$rm ],
         };
      }
   }

   is( $glob_ok, $glob_n, "GLOB outrefs_direct multiset exact for all $glob_n GLOBs" )
      or do {
         require Data::Dumper;
         diag( Data::Dumper->new( [$glob_mismatch] )->Terse(1)->Indent(1)->Dump );
      };

   # Immortal targets must not be dropped from the structural edge graph
   cmp_ok( $imm_rust, '>=', int( $imm_perl * 0.95 ),
      "edges to immortals: rust=$imm_rust perl_direct=$imm_perl (>=95%)" );

   # Sample REFs: rv strength must match
   my ( $ref_ok, $ref_n ) = ( 0, 0 );
   for my $sv ( $perl_df->heap ) {
      next unless $sv->type eq 'REF';
      my $id = $core->id_for_addr( $sv->addr );
      next if $id == 0xFFFFFFFF;
      $ref_n++;
      my $pm = multiset_of( perl_direct_edges($sv) );
      my $rm = multiset_of( rust_direct_edges( $core, $id ) );
      # REF may have ourstash; compare rv edge at minimum
      my @p_rv = grep {1} keys %$pm;
      my @r_rv = grep {1} keys %$rm;
      # Exact multiset for REF direct outrefs (rv + optional ourstash if both emit)
      $ref_ok++ if multisets_equal( $pm, $rm );
      last if $ref_n >= 100;
   }
   cmp_ok( $ref_ok / ( $ref_n || 1 ), '>=', 0.90,
      sprintf( 'REF outrefs_direct exact match rate %.0f%% (%d/%d)',
         100 * $ref_ok / ( $ref_n || 1 ), $ref_ok, $ref_n ) );

   # ---- PAR-031: reverse edges — every forward edge has a matching reverse ----
   my $checked_rev = 0;
   my $rev_ok      = 0;
   for my $id ( 0 .. 300 ) {
      my $batch = $core->outrefs_batch($id);
      for my $row ( @$batch ) {
         my ( $tid, $str ) = @$row;
         next if $tid == 0xFFFFFFFF;
         my $ins = $core->inrefs_batch($tid);
         my $found = 0;
         for my $in ( @$ins ) {
            if ( $in->[0] == $id && $in->[1] == $str ) {
               $found = 1;
               last;
            }
         }
         $checked_rev++;
         $rev_ok++ if $found;
      }
   }
   cmp_ok( $checked_rev, '>', 0, "checked $checked_rev reverse edges" );
   is( $rev_ok, $checked_rev, 'every sampled forward edge has matching reverse' );
}

done_testing;

# ---- helpers ----

sub capture {
   my ( $df ) = @_;
   my %type_counts;
   for my $sv ( $df->heap ) {
      $type_counts{ $sv->type }++;
   }
   my @root_names = $df->{roots} ? keys %{ $df->{roots} } : ();
   return {
      heap_svs     => scalar( $df->heap ),
      format_minor => $df->{format_minor},
      type_counts  => \%type_counts,
      root_names   => \@root_names,
   };
}

# Returns list of [addr, strength] for outrefs_direct (strong+weak only).
sub perl_direct_edges {
   my ( $sv ) = @_;
   my @out;
   for my $ref ( $sv->outrefs_direct ) {
      my $t = $ref->sv or next;
      push @out, [ $t->addr, $ref->strength ];
   }
   return @out;
}

# Rust batch edges as [addr, strength_name].
sub rust_direct_edges {
   my ( $core, $id ) = @_;
   my $batch = $core->outrefs_batch($id);
   my @out;
   for my $row ( @$batch ) {
      my ( $tid, $str_bits ) = @$row;
      next if $tid == 0xFFFFFFFF;
      my $addr = $core->addr_for_id($tid);
      next unless $addr;
      my $name = strength_name($str_bits);
      next unless $name eq 'strong' || $name eq 'weak'; # direct only
      push @out, [ $addr, $name ];
   }
   return @out;
}

sub strength_name {
   my ( $bits ) = @_;
   return 'strong'   if $bits == 1;
   return 'weak'     if $bits == 2;
   return 'indirect' if $bits == 4;
   return 'inferred' if $bits == 8;
   return "bits_$bits";
}

sub multiset_of {
   my %m;
   for my $e ( @_ ) {
      my $k = sprintf( '%x:%s', $e->[0], $e->[1] );
      $m{$k}++;
   }
   return \%m;
}

sub multisets_equal {
   my ( $a, $b ) = @_;
   return 0 unless keys %$a == keys %$b;
   for my $k ( keys %$a ) {
      return 0 unless ( $b->{$k} // 0 ) == $a->{$k};
   }
   return 1;
}
