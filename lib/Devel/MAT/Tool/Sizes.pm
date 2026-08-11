#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2013-2024 -- leonerd@leonerd.org.uk

package Devel::MAT::Tool::Sizes 0.54;

use v5.14;
use warnings;
use base qw( Devel::MAT::Tool );

use constant FOR_UI => 1;

use List::Util qw( sum0 );
use List::UtilsBy qw( rev_nsort_by );

=head1 NAME

C<Devel::MAT::Tool::Sizes> - calculate sizes of SV structures

=head1 DESCRIPTION

This C<Devel::MAT> tool calculates the sizes of the structures around SVs.
The individual size of each individual SV is given by the C<size> method,
though in several cases SVs can be considered to be part of larger structures
of a combined aggregate size. This tool calculates those sizes and adds them
to the UI.

The structural size is calculated from the basic size of the SV, added to
which for various types is:

=over 2

=item ARRAY

Arrays add the basic size of every non-mortal element SV.

=item HASH

Hashes add the basic size of every non-mortal value SV.

=item CODE

Codes add the basic size of their padlist and constant value, and all their
padnames, pads, constants and globrefs.

=back

The owned size is calculated by starting at the given SV and accumulating the
set of every strong outref whose refcount is 1. This is the set of all SVs the
original directly owns.

=cut

sub init_ui
{
   my $self = shift;
   my ( $ui ) = @_;

   my %size_tooltip = (
      SV        => "Display the size of each SV individually",
      Structure => "Display the size of SVs including its internal structure",
      Owned     => "Display the size of SVs including all owned referrents",
   );

   $ui->provides_radiobutton_set(
      map {
         my $size = $_ eq "SV" ? "size" : "\L${_}_size";

         $ui->register_icon(
            name => "size-$_",
            svg  => "icons/size-$_.svg",
         );

         {
            text    => $_,
            icon    => "size-$_",
            tooltip => $size_tooltip{$_},
            code    => sub {
               $ui->set_svlist_column_values(
                  column => Devel::MAT::UI->COLUMN_SIZE,
                  from   => sub { shift->$size },
               );
            },
         }
      } qw( SV Structure Owned )
   );
}

=head1 SV METHODS

This tool adds the following SV methods.

=head2 structure_set

   @svs = $sv->structure_set;

Returns the total set of the SV's structure.

=head2 structure_size

   $size = $sv->structure_size;

Returns the size, in bytes, of the structure that the SV contains.

=cut

# Most SVs' structual set is just themself
sub Devel::MAT::SV::structure_set { shift }

# ARRAY structure includes the element SVs
sub Devel::MAT::SV::ARRAY::structure_set
{
   my $av = shift;
   my @svs = ( $av, grep { $_ && !$_->immortal } $av->elems );
   return @svs;
}

# HASH structure includes the value SVs
sub Devel::MAT::SV::HASH::structure_set
{
   my $hv = shift;
   my @svs = ( $hv, grep { $_ && !$_->immortal } $hv->values );
   return @svs;
}

# CODE structure includes PADLIST, PADNAMES, PADs, and all pad name and pad SVs
sub Devel::MAT::SV::CODE::structure_set
{
   my $cv = shift;
   my @svs = ( $cv, grep { $_ && !$_->immortal }
      $cv->padlist, $cv->padnames_av, $cv->pads,
      $cv->constval, $cv->constants, $cv->globrefs );
   return @svs;
}

sub Devel::MAT::SV::structure_size
{
   return sum0 map { $_->size } shift->structure_set
}

=head2 owned_set

   @svs = $sv->owned_set;

Returns the set of every SV owned by the given one.

=head2 owned_size

   $size = $sv->owned_size;

Returns the total size, in bytes, of the SVs owned by the given one.

=cut

# Exclusive strong children: non-immortal strong outrefs with refcnt == 1.
# Same filter as the historic owned_set walk (0.54 semantics).
# NOTE: this digraph is not always a tree — the same refcnt==1 SV can appear as
# a strong outref from multiple parents (e.g. GLOB→CODE and protosub GLOB→CODE).
# owned_size therefore cannot use child-sum DP; it must use a %seen walk.
# Children lists are cached on the SV to avoid repeating outrefs_strong.
sub Devel::MAT::SV::_owned_children
{
   my $sv = shift;
   return @{ $sv->{tool_sizes_owned_chld} } if $sv->{tool_sizes_owned_chld};
   my @c = grep {
      $_ && !$_->immortal && $_->refcnt == 1
   } map { $_->sv } $sv->outrefs_strong;
   $sv->{tool_sizes_owned_chld} = \@c;
   return @c;
}

sub Devel::MAT::SV::owned_set
{
   my @more = ( shift );

   my %seen;
   my @owned;

   while( @more ) {
      my $next = pop @more;
      next if $seen{ $next->addr }++;
      push @owned, $next;
      push @more, grep { !$seen{ $_->addr } } $next->_owned_children;
   }
   return @owned;
}

# Generation counter for owned_size %seen (avoids clearing a big hash each call).
our $_owned_size_gen = 0;
our %_owned_size_seen_gen;  # addr => generation

# owned_size ≡ sum of size() over owned_set (0.54). Always a classic %seen walk
# (cached children). Never sums child owned_size — that over-counts diamonds
# (same exclusive child claimed via multiple strong outrefs).
sub Devel::MAT::SV::owned_size
{
   my $sv = shift;
   return $sv->{tool_sizes_owned} if defined $sv->{tool_sizes_owned};

   # Fast path: no exclusive children → just this SV.
   my @kids = $sv->_owned_children;
   if ( !@kids ) {
      return $sv->{tool_sizes_owned} = $sv->size;
   }

   my $gen = ++$_owned_size_gen;
   # Prevent gen overflow stomping; rare, cheap reset.
   if ( $gen >= 2_000_000_000 ) {
      %_owned_size_seen_gen = ();
      $gen = $_owned_size_gen = 1;
   }

   my $total = 0;
   my @stack = ( $sv );
   while ( @stack ) {
      my $n = pop @stack;
      my $a = $n->addr;
      next if ( $_owned_size_seen_gen{$a} // 0 ) == $gen;
      $_owned_size_seen_gen{$a} = $gen;
      $total += $n->size;
      my $ch = $n->{tool_sizes_owned_chld};
      if ( $ch ) {
         push @stack, @$ch;
      }
      else {
         push @stack, $n->_owned_children;
      }
   }
   return $sv->{tool_sizes_owned} = $total;
}

# Full-heap fill for largest --owned: prime children caches once (one outrefs pass
# per SV), then classic owned_size per SV. Correct for multi-parent exclusive edges.
sub Devel::MAT::Tool::Sizes::_largest::_precompute_owned_sizes
{
   my ( $svs ) = @_;
   return unless $svs && @$svs;

   for my $sv ( @$svs ) {
      $sv->_owned_children;
   }
   for my $sv ( @$svs ) {
      $sv->owned_size;
   }
}

=head1 COMMANDS

=cut

=head2 size

Prints the sizes of a given SV

   pmat> size defstash
   STASH(61) at 0x556e47243e10=defstash consumes:
     2.1 KiB directly
     11.2 KiB structurally
     54.2 KiB including owned referrants

=cut

use constant CMD => "size";
use constant CMD_DESC => "Show the size of a given SV";

use constant CMD_ARGS_SV => 1;

sub run
{
   my $self = shift;
   my ( $sv ) = @_;

   Devel::MAT::Cmd->printf( "%s consumes:\n",
      Devel::MAT::Cmd->format_sv( $sv )
   );

   Devel::MAT::Cmd->printf( "  %s directly\n",
      Devel::MAT::Cmd->format_bytes( $sv->size )
   );
   Devel::MAT::Cmd->printf( "  %s structurally\n",
      Devel::MAT::Cmd->format_bytes( $sv->structure_size )
   );
   Devel::MAT::Cmd->printf( "  %s including owned referrants\n",
      Devel::MAT::Cmd->format_bytes( $sv->owned_size )
   );
}

package # hide
   Devel::MAT::Tool::Sizes::_largest;
use base qw( Devel::MAT::Tool );

=head2 largest

   pmat> largest -owned
   STASH(61) at 0x55e4317dfe10: 54.2 KiB: of which
    |   GLOB(%*) at 0x55e43180be60: 16.9 KiB: of which
    |    |   STASH(40) at 0x55e43180bdd0: 16.7 KiB
    |    |   GLOB(&*) at 0x55e4318ad330: 2.8 KiB
    |    |   others: 15.0 KiB
    |   GLOB(%*) at 0x55e4317fdf28: 4.1 KiB: of which
    |    |   STASH(34) at 0x55e4317fdf40: 4.0 KiB bytes
   ...

Finds and prints the largest SVs by size. The 5 largest SVs are shown.

If counting sizes in a way that includes referred SVs, a tree is printed
showing the 3 largest SVs within these, and of those the 2 largest referred
SVs again. This should help identify large memory occupiers.

Takes the following named options:

=over 4

=item --struct

Count SVs using the structural size.

=item --owned

Count SVs using the owned size.

=back

By default, only the individual SV size is counted.

=cut

use constant CMD => "largest";
use constant CMD_DESC => "Find the largest SVs by size";

my %seen;

# Fixed top-K selection: O(N·K) for small K (default 5/3/2). Higher score wins;
# ties broken by lower address (stable, deterministic). Replaces full Fibonacci
# heap over every SV (OPT-10).
# Callable as function or package method (drops invocant when not an ARRAY ref).
sub _select_topk
{
   shift if @_ && !ref( $_[0] );
   my ( $svlist, $method, $k ) = @_;
   return () if $k <= 0 || !@$svlist;

   # @best held sorted descending by score, then ascending by addr; length <= k
   my @best;
   for my $sv ( @$svlist ) {
      my $score = $sv->$method;
      my $addr  = $sv->addr;
      if ( @best < $k
           || $score > $best[-1][0]
           || ( $score == $best[-1][0] && $addr < $best[-1][1] ) ) {
         push @best, [ $score, $addr, $sv ];
         @best = sort {
            $b->[0] <=> $a->[0] || $a->[1] <=> $b->[1]
         } @best;
         pop @best if @best > $k;
      }
   }
   return map { $_->[2] } @best;
}

sub list_largest_svs
{
   my ( $svlist, $metric, $indent, @counts ) = @_;

   my $method = $metric ? "${metric}_size" : "size";

   my $count = shift @counts;
   my @top = _select_topk( $svlist, $method, $count );

   for my $largest ( @top ) {
      $seen{$largest->addr}++;

      Devel::MAT::Cmd->printf( "$indent%s: %s",
         Devel::MAT::Cmd->format_sv( $largest ),
         Devel::MAT::Cmd->format_bytes( $largest->$method ),
      );

      if( !defined $metric or !@counts ) {
         Devel::MAT::Cmd->printf( "\n" );
         next;
      }

      my $set_method = "${metric}_set";
      my @set = $largest->$set_method;
      shift @set; # SV itself is always first

      if( !@set ) {
         Devel::MAT::Cmd->printf( "\n" );
         next;
      }

      Devel::MAT::Cmd->printf( ": of which\n" );
      list_largest_svs( \@set, $metric, "${indent} |   ", @counts );

      $seen{$_->addr}++ for @set;
   }

   my $others = 0;
   $others += $_->size for grep { !$seen{$_->addr} } @$svlist;

   if( $others ) {
      Devel::MAT::Cmd->printf( "$indent%s: %s\n",
         Devel::MAT::Cmd->format_note( "others" ),
         Devel::MAT::Cmd->format_bytes( $others ),
      );
   }
}

use constant CMD_OPTS => (
   struct => { help => "count SVs by structural size" },
   owned  => { help => "count SVs by owned size" },
);

use constant CMD_ARGS => (
   { name => "count", help => "how many items to display",
     repeated => 1 },
);

# Dense-model owned sizes by ObjectId (no full Perl proxy heap).
# Prefers Rust pmat_owned_sizes (classic %seen over strong exclusive CSR kids).
# Returns ( \@owned_by_id, \@addr_by_id ) or empty list if unavailable.
# Note: builds full addr×N — prefer _native_owned_topk / owned_largest_tree for ranking.
sub _native_owned_by_id
{
   my ( $df ) = @_;
   my $core = $df->can('rust_core') && $df->rust_core;
   return unless $core && $core->can('object_at');

   my $n = $core->heap_count;
   return unless $n;

   my @addr;
   $#addr = $n - 1;
   for my $id ( 0 .. $n - 1 ) {
      my $row = $core->object_at($id) or next;
      $addr[$id] = $row->[0];
   }

   if ( $core->can('owned_sizes') ) {
      my $owned = $core->owned_sizes;
      return ( $owned, \@addr ) if $owned && ref($owned) eq 'ARRAY' && @$owned == $n;
   }

   return;
}

# Top-K ObjectIds by native owned size (higher score, then lower addr).
# Legacy pure-Perl scan over full owned+addr arrays — kept for tests/fallback.
sub _native_owned_topk_ids
{
   my ( $owned, $addr, $k ) = @_;
   return () if $k <= 0;
   my @best;  # [score, addr, id]
   for my $id ( 0 .. $#$owned ) {
      my $score = $owned->[$id] // 0;
      my $ad    = $addr->[$id] // 0;
      if ( @best < $k
           || $score > $best[-1][0]
           || ( $score == $best[-1][0] && $ad < $best[-1][1] ) )
      {
         push @best, [ $score, $ad, $id ];
         # Do not use $a/$b lexicals here — they shadow sort's $a/$b.
         @best = sort { $b->[0] <=> $a->[0] || $a->[1] <=> $b->[1] } @best;
         pop @best if @best > $k;
      }
   }
   return map { $_->[2] } @best;
}

# Native top-K roots via pmat_owned_topk — no full-heap Perl addr table.
# Returns list of [ id, addr, score ] or empty if unavailable.
sub _native_owned_topk
{
   my ( $df, $k ) = @_;
   return () if $k <= 0;
   my $core = $df->can('rust_core') && $df->rust_core;
   return () unless $core && $core->can('owned_topk');
   my @rows = $core->owned_topk($k);
   return @rows;
}

# Print multi-level largest-owned tree from native dense ranking.
# Materializes only nodes that appear in the tree (not full owned_set).
sub _list_native_owned_tree
{
   my ( $df, $indent, @counts ) = @_;
   my $core = $df->rust_core;
   return 0 unless $core && $core->can('owned_largest_tree');

   my @rows = $core->owned_largest_tree( \@counts );
   return 0 unless @rows;

   # Group children by parent index for "of which" nesting.
   my @by_parent;  # parent_idx+1 => [ row indices ]
   my @roots;
   for my $i ( 0 .. $#rows ) {
      my $p = $rows[$i][4];
      if ( !defined $p || $p < 0 ) {
         push @roots, $i;
      }
      else {
         push @{ $by_parent[ $p + 1 ] }, $i;
      }
   }

   my $emit;
   $emit = sub {
      my ( $idxs, $ind ) = @_;
      # "others" among siblings is not tracked natively; skip classic others for native tree.
      for my $i ( @$idxs ) {
         my ( $id, $addr, $score, $depth, $parent ) = @{ $rows[$i] };
         my $sv = $df->sv_at($addr) or next;
         $sv->{tool_sizes_owned} = $score;

         Devel::MAT::Cmd->printf( "$ind%s: %s",
            Devel::MAT::Cmd->format_sv($sv),
            Devel::MAT::Cmd->format_bytes($score),
         );

         my $kids = $by_parent[ $i + 1 ];
         if ( $kids && @$kids ) {
            Devel::MAT::Cmd->printf( ": of which\n" );
            $emit->( $kids, "$ind |   " );
         }
         else {
            Devel::MAT::Cmd->printf( "\n" );
         }
      }
   };

   $emit->( \@roots, $indent );
   return 1;
}

sub run
{
   my $self = shift;
   my %opts = %{ +shift };

   my @counts = ( 5, 3, 2 );
   $counts[$_] = $_[$_] for 0 .. $#_;

   my $df = $self->df;

   my $METRIC;
   $METRIC = "structure" if $opts{struct};
   $METRIC = "owned"     if $opts{owned};

   my $method = $METRIC ? "${METRIC}_size" : "size";

   # largest --owned under Rust: dense owned precompute + materialize only tree
   # nodes (top-K roots and nested exclusive-descendant picks), not full heap.
   if ( $METRIC && $METRIC eq "owned"
      && $df->can('rust_core') && $df->rust_core
      && !( $ENV{PMAT_OWNED_FULL} && $ENV{PMAT_OWNED_FULL} !~ /^(0|false|off|no)$/i )
   ) {
      $self->report_progress( "Calculating owned sizes (native)..." );
      # One native build: parallel owned scores + top-K roots + nested exclusive
      # descendants (CSR), materializing only printed nodes — no full addr×N glue.
      my $ok = _list_native_owned_tree( $df, "", @counts );
      $self->report_progress();
      return if $ok;
      # fall through to classic if native unavailable
   }

   my @svs = $df->heap;

   my $heap_total = scalar @svs;
   if ( $METRIC && $METRIC eq "owned" ) {
      $self->report_progress( "Calculating owned sizes..." ) if $heap_total;
      _precompute_owned_sizes( \@svs );
      $self->report_progress();
   }
   else {
      my $count = 0;
      foreach my $sv ( @svs ) {
         $count++;
         $self->report_progress( sprintf "Calculating sizes in %d of %d (%.2f%%)",
            $count, $heap_total, 100*$count / $heap_total ) if $count % 20000 == 0;
         $sv->$method;
      }
      $self->report_progress();
   }

   undef %seen;
   list_largest_svs( \@svs, $METRIC, "", @counts );
}

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>

=cut

0x55AA;
