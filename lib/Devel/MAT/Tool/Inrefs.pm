#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2013-2024 -- leonerd@leonerd.org.uk

package Devel::MAT::Tool::Inrefs 0.54;

use v5.14;
use warnings;
use base qw( Devel::MAT::Tool );

use List::Util qw( any pairs );

my %STRENGTH_TO_IDX = (
   strong   => 0,
   weak     => 1,
   indirect => 2,
   inferred => 3,
);
use constant {
   IDX_ROOTS_STRONG => 4,
   IDX_ROOTS_WEAK   => 5,
   IDX_STACK        => 6,
};

=head1 NAME

C<Devel::MAT::Tool::Inrefs> - annotate which SVs are referred to by others

=head1 DESCRIPTION

This C<Devel::MAT> tool annotates each SV with back-references from other SVs
that refer to it. It follows the C<outrefs> method of every heap SV and
annotates the referred SVs with back-references pointing back to the SVs that
refer to them.

B<Note:> Under forced Rust, reverse edges are built B<on demand> for each SV
(CSR reverse candidates + re-filter via proxy C<outrefs> for 0.54 strengths
and names). This avoids a full-heap materialize for interactive tools such as
C<identify>. Set C<PMAT_INREFS_FULL=1> to force the classic full outref walk
at tool init (oracle / differential debugging).

Dense CSR reverse alone is a structural subset of 0.54 C<outrefs> (e.g. CODE
C<"the glob"> may be absent). On-demand re-filter restores 0.54 strength for
edges that appear as CSR candidates; pure-CSR without re-filter remains
residual (see F<docs/lessons/opt-03-csr-inrefs.md>).

=cut

sub init_tool
{
   my $self = shift;

   my $df = $self->df;

   # Lazy on-demand reverse is opt-in (Identify sets _want_inrefs_lazy under rust).
   # Default remains classic full walk so inrefs/oracle tools stay complete.
   my $force_full = $ENV{PMAT_INREFS_FULL}
      && $ENV{PMAT_INREFS_FULL} !~ /^(0|false|off|no)$/i;
   my $want_lazy = !$force_full && $df->{_want_inrefs_lazy};

   my $can_lazy = $want_lazy
      && $df->can('rust_core') && $df->rust_core
      && $df->rust_core->can('inrefs_batch')
      && $df->rust_core->can('id_for_addr');

   # Roots / stack only (cheap; few SVs). Required for both paths.
   foreach ( pairs $df->roots_strong ) {
      my ( undef, $sv ) = @$_;
      next unless $sv;
      $sv->{tool_inrefs}[IDX_ROOTS_STRONG]++;
   }

   foreach ( pairs $df->roots_weak ) {
      my ( undef, $sv ) = @$_;
      next unless $sv;
      $sv->{tool_inrefs}[IDX_ROOTS_WEAK]++;
   }

   foreach my $sv ( $df->stack ) {
      $sv->{tool_inrefs}[IDX_STACK]++;
   }

   if ( $can_lazy ) {
      # On-demand reverse edges via _ensure_inrefs_built (identify walk set).
      $df->{_inrefs_lazy} = 1;
      $self->report_progress();
      return;
   }

   # Classic outref walk — full heap materialize + complete 0.54 edge set.
   $df->{_inrefs_lazy} = 0;
   my $heap_total = scalar $df->heap;
   my $count = 0;
   foreach my $sv ( $df->heap ) {
      foreach ( pairs $sv->outrefs( "NO_DESC" ) ) {
         my ( $strength, $refsv ) = @$_;

         push @{ $refsv->{tool_inrefs}[ $STRENGTH_TO_IDX{ $strength } ] }, $sv->addr if !$refsv->immortal;
      }

      $count++;
      $self->report_progress( sprintf "Patching refs in %d of %d (%.2f%%)",
         $count, $heap_total, 100*$count / $heap_total ) if ($count % 10000) == 0
   }

   $self->report_progress();
}

# Force classic full reverse index once (materializes full heap). Used when
# weak/indirect/inferred are requested — CSR reverse is incomplete for those.
sub Devel::MAT::Dumpfile::_inrefs_force_classic_full
{
   my $df = shift;
   return if $df->{_inrefs_classic_done};
   $df->{_inrefs_lazy} = 0;

   my $heap_total = scalar $df->heap;
   my $count      = 0;
   foreach my $sv ( $df->heap ) {
      # Clear partial lazy slots (keep roots/stack indices 4..6).
      if ( my $ti = $sv->{tool_inrefs} ) {
         $ti->[0] = $ti->[1] = $ti->[2] = $ti->[3] = undef;
      }
      delete $sv->{tool_inrefs_ready};
      foreach ( pairs $sv->outrefs( "NO_DESC" ) ) {
         my ( $strength, $refsv ) = @$_;
         push @{ $refsv->{tool_inrefs}[ $STRENGTH_TO_IDX{$strength} ] }, $sv->addr
            if $refsv && !$refsv->immortal;
      }
      $count++;
   }
   for my $sv ( $df->heap ) {
      $sv->{tool_inrefs_ready} = 1;
   }
   $df->{_inrefs_classic_done} = 1;
}

# Build heap reverse slots for one SV under forced-Rust lazy mode (strong path).
# Candidates from dense reverse CSR; 0.54 strength/name via source outrefs re-filter.
sub Devel::MAT::SV::_ensure_inrefs_built
{
   my $self = shift;
   return if $self->{tool_inrefs_ready};

   my $df = $self->df;
   unless ( $df && $df->{_inrefs_lazy} ) {
      $self->{tool_inrefs_ready} = 1;
      return;
   }

   if ( $self->immortal ) {
      $self->{tool_inrefs_ready} = 1;
      return;
   }

   my $core = $df->rust_core;
   my $id   = $core->id_for_addr( $self->addr );
   $self->{tool_inrefs} ||= [];

   if ( defined $id && $id != 0xFFFFFFFF ) {
      my $batch = $core->inrefs_batch($id);
      my %seen_src;
      for my $row ( @{ $batch // [] } ) {
         next unless ref($row) eq 'ARRAY';
         my ( $src_id, undef ) = @$row;
         next unless defined $src_id;
         next if $seen_src{$src_id}++;

         my $src_meta = $core->object_at($src_id) or next;
         next unless ref($src_meta) eq 'ARRAY';
         my $src_addr = $src_meta->[0];
         my $src      = $df->sv_at($src_addr) or next;

         foreach ( pairs $src->outrefs( "NO_DESC" ) ) {
            my ( $strength, $refsv ) = @$_;
            next unless $refsv && $refsv == $self;
            push @{ $self->{tool_inrefs}[ $STRENGTH_TO_IDX{$strength} ] }, $src->addr;
         }
      }
   }

   $self->{tool_inrefs_ready} = 1;
}

=head1 SV METHODS

This tool adds the following SV methods.

=head2 inrefs

   @refs = $sv->inrefs;

Returns a list of Reference objects for each of the SVs that refer to this
one. This is formed by the inverse mapping along the SV graph from C<outrefs>.

=head2 inrefs_strong

=head2 inrefs_weak

=head2 inrefs_direct

=head2 inrefs_indirect

=head2 inrefs_inferred

   @refs = $sv->inrefs_strong;

   @refs = $sv->inrefs_weak;

   @refs = $sv->inrefs_direct;

   @refs = $sv->inrefs_indirect;

   @refs = $sv->inrefs_inferred;

Returns lists of Reference objects filtered by type, analogous to the various
C<outrefs_*> methods.

=cut

sub Devel::MAT::SV::_inrefs
{
   my $self = shift;
   my ( @strengths ) = @_;

   # In scalar context we don't need to return SVs or Reference instances,
   #   just count them. This allows a lot of optimisations.
   my $just_count = !wantarray;

   my $df = $self->df;
   if ( $df && $df->{_inrefs_lazy} ) {
      # CSR reverse + outrefs re-filter is good for strong (and many weak) edges.
      # Indirect/inferred 0.54 edges may be absent from CSR — use classic full walk.
      if ( any { $_ eq 'indirect' || $_ eq 'inferred' } @strengths ) {
         $df->_inrefs_force_classic_full;
      }
      else {
         $self->_ensure_inrefs_built;
      }
   }
   $self->{tool_inrefs} ||= [];

   $df = $self->df;
   my @inrefs;
   foreach my $strength ( @strengths ) {
      my %seen;
      foreach my $addr ( @{ $self->{tool_inrefs}[ $STRENGTH_TO_IDX{$strength} ] // [] } ) {
         if( $just_count ) {
            # Slots are pre-bucketed by 0.54 strength (classic walk or lazy re-filter),
            # so counting slot entries matches list context after re-filter
            # (each push is one outref edge of that strength).
            push @inrefs, 1;
         }
         else {
            $seen{$addr}++ and next;

            my $sv = $df->sv_at( $addr );
            next unless $sv;

            push @inrefs, Devel::MAT::SV::Reference( $_->name, $_->strength, $sv )
               for grep { $_->strength eq $strength and $_->sv && $_->sv == $self } $sv->outrefs;
         }
      }
   }

   if( $self->{tool_inrefs}[IDX_ROOTS_STRONG] and $strengths[0] eq "strong" ) {
      if( $just_count ) {
         push @inrefs, ( 1 ) x $self->{tool_inrefs}[IDX_ROOTS_STRONG];
      }
      else {
         foreach ( pairs $df->roots_strong ) {
            my ( $name, $sv ) = @$_;
            push @inrefs, Devel::MAT::SV::Reference( $name, strong => undef )
               if defined $sv and $sv == $self;
         }
      }
   }

   if( $self->{tool_inrefs}[IDX_ROOTS_WEAK] and any { $_ eq "weak" } @strengths ) {
      if( $just_count ) {
         push @inrefs, ( 1 ) x $self->{tool_inrefs}[IDX_ROOTS_WEAK];
      }
      else {
         foreach ( pairs $df->roots_weak ) {
            my ( $name, $sv ) = @$_;
            push @inrefs, Devel::MAT::SV::Reference( $name, weak => undef )
               if defined $sv and $sv == $self;
         }
      }
   }

   if( $self->{tool_inrefs}[IDX_STACK] and any { $_ eq "weak" } @strengths ) {
      if( $just_count ) {
         push @inrefs, ( 1 ) x $self->{tool_inrefs}[IDX_STACK];
      }
      else {
         foreach my $stacksv ( $df->stack ) {
            next unless $stacksv->addr == $self->addr;

            push @inrefs, Devel::MAT::SV::Reference( "a value on the stack", strong => undef );
         }
      }
   }

   return @inrefs;
}

# If 'strong' is included in these lists it must be first
sub Devel::MAT::SV::inrefs          { shift->_inrefs( qw( strong weak indirect inferred )) }
sub Devel::MAT::SV::inrefs_strong   { shift->_inrefs( qw( strong      )) }
sub Devel::MAT::SV::inrefs_weak     { shift->_inrefs( qw( weak        )) }
sub Devel::MAT::SV::inrefs_direct   { shift->_inrefs( qw( strong weak )) }
sub Devel::MAT::SV::inrefs_indirect { shift->_inrefs( qw( indirect    )) }
sub Devel::MAT::SV::inrefs_inferred { shift->_inrefs( qw( inferred    )) }

=head1 COMANDS

=cut

=head2 inrefs

   pmat> inrefs defstash
   s  the hash  GLOB(%*) at 0x556e47243e40

Shows the incoming references that refer to a given SV.

Takes the following named options:

=over 4

=item --weak

Include weak direct references in the output (by default only strong direct
ones will be included).

=item --all

Include both weak and indirect references in the output.

=back

=cut

use constant CMD => "inrefs";
use constant CMD_DESC => "Show incoming references to a given SV";

use constant CMD_OPTS => (
   weak     => { help => "include weak references" },
   all      => { help => "include weak and indirect references",
                 alias => "a" },
);

use constant CMD_ARGS_SV => 1;

sub run
{
   my $self = shift;
   my %opts = %{ +shift };
   my ( $sv ) = @_;

   my $method = $opts{all}  ? "inrefs" :
                $opts{weak} ? "inrefs_direct" :
                              "inrefs_strong";

   require Devel::MAT::Tool::Outrefs;
   Devel::MAT::Tool::Outrefs->show_refs_by_method( $method, $sv );
}

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>

=cut

0x55AA;
