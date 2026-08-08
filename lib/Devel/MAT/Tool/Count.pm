#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2013-2018 -- leonerd@leonerd.org.uk

package Devel::MAT::Tool::Count 0.54;

use v5.14;
use warnings;
use base qw( Devel::MAT::Tool );

use constant CMD => "count";
use constant CMD_DESC => "Count the various kinds of SV";

use List::Util qw( sum );
use List::UtilsBy qw( rev_nsort_by );
use Struct::Dumb;

=head1 NAME

C<Devel::MAT::Tool::Count> - count the various kinds of SV

=head1 DESCRIPTION

This C<Devel::MAT> tool counts the different kinds of SV in the heap.

=cut

=head1 COMMANDS

=head2 count

   pmat> count
     Kind       Count (blessed)        Bytes (blessed)
     ARRAY        170         0     15.1 KiB          
     CODE         166         0     20.8 KiB          

Prints a summary of the count of each type of object.

Takes the following named options:

=over 4

=item --blessed, -b

Additionally classify blessed references per package

=item --scalars, -S

Additionally classify SCALAR SVs according to which fields they have present

=item --struct

Use the structural size to sum byte counts

=item --owned

Use the owned size to sum byte counts

=back

=cut

use constant CMD_OPTS => (
   blessed => { help => "classify blessed references per package",
                alias => "b" },
   scalars => { help => "classify SCALARs according to present fields",
                alias => "S" },
   struct  => { help => "sum SVs by structural size" },
   owned   => { help => "sum SVs by owned size" },
);

struct Counts => [qw( svs bytes blessed_svs blessed_bytes )];

sub run
{
   my $self = shift;

   $self->count_svs( %{ +shift } );
}

sub count_svs
{
   my $self = shift;
   my %opts = @_;

   # TODO: consider options for
   #   sorting
   #   filtering

   my $size_meth = $opts{owned}  ? "owned_size" :
                   $opts{struct} ? "structure_size" :
                   "size";

   # Options for bin/pmat-counts
   my $emit_count = $opts{emit_count} //
      sub { ( !$_[1] || $_[2] ) ? $_[2] : "" };
   my $emit_bytes = $opts{emit_bytes} //
      sub { ( !$_[1] || $_[2] ) ? Devel::MAT::Cmd->format_bytes( $_[2] ) : "" };

   my %counts;
   my %counts_SCALAR;
   my %counts_per_package;

   # Default count under Rust: scan dense model without heap() materialize.
   if (  !$opts{blessed} && !$opts{scalars}
      && $size_meth eq "size"
      && $self->df->can('rust_core') && $self->df->rust_core
      && $self->df->rust_core->can('object_at')
   ) {
      $self->_count_svs_rust_default( \%counts, $emit_count, $emit_bytes, \%opts );
      return;
   }

   # Exercise batch native type histogram when Rust core is present (one FFI
   # call for the whole heap). Display table still uses heap walk so type
   # names match 0.54 proxy reclassification (PAD/BOOL/etc.).
   if ( $self->df->can('rust_core') && $self->df->rust_core ) {
      my $tc = $self->df->rust_core->type_counts;
      $self->{rust_type_counts_batch} = $tc if $tc;
   }

   foreach my $sv ( $self->df->heap ) {
      my $kind = $sv->type;
      my $c = $counts{$kind} //= Counts( ( 0 ) x 4 );
      my $bytes = $sv->$size_meth;

      $c->svs++;
      $c->bytes += $bytes;

      if( $sv->blessed ) {
         $c->blessed_svs++;
         $c->blessed_bytes += $bytes;
      }

      if( $opts{scalars} and $sv->isa( "Devel::MAT::SV::SCALAR" ) ) {
         my $desc = $sv->desc;

         $c = $counts_SCALAR{$desc} //= Counts( ( 0 ) x 4 );

         $c->svs++;
         $c->bytes += $bytes;

         if( $sv->blessed ) {
            $c->blessed_svs++;
            $c->blessed_bytes += $bytes;
         }
      }

      $opts{blessed} or next;

      if( $sv->blessed ) {
         $c = $counts_per_package{ref $sv}{ $sv->blessed->stashname } //= Counts( ( 0 ) x 4 );
         $c->blessed_svs++;
         $c->blessed_bytes += $bytes;
      }
   }

   my @table;

   foreach my $kind ( sort keys %counts ) {
      my $c = $counts{$kind};

      push @table, [ $kind,
            $emit_count->( $kind, 0, $c->svs ),
            $emit_count->( $kind, 1, $c->blessed_svs ),
            $emit_bytes->( $kind, 0, $c->bytes ),
            $emit_bytes->( $kind, 1, $c->blessed_bytes ) ];

      push @table, _gen_package_breakdown( $counts_per_package{$_}, $emit_count, $emit_bytes ) if $opts{blessed};

      if( $kind eq "SCALAR" and $opts{scalars} ) {
         foreach ( sort keys %counts_SCALAR ) {
            my $c = $counts_SCALAR{$_};

            push @table, [ "  $_",
                  $emit_count->( $_, 0, $c->svs ),
                  $emit_count->( $_, 1, $c->blessed_svs ),
                  $emit_bytes->( $_, 0, $c->bytes ),
                  $emit_bytes->( $_, 1, $c->blessed_bytes ) ];
         }
      }
   }

   push @table, []; # HR

   my $total = Counts( ( 0 ) x 4 );
   foreach my $method (qw( svs bytes blessed_svs blessed_bytes )) {
      $total->$method = sum map { $_->$method } values %counts;
   }

   push @table, [ "(total)",
      $emit_count->( "(total)", 0, $total->svs ),
      $emit_count->( "(total)", 1, $total->blessed_svs ),
      $emit_bytes->( "(total)", 0, $total->bytes ),
      $emit_bytes->( "(total)", 1, $total->blessed_bytes ) ];

   Devel::MAT::Cmd->print_table( \@table,
      indent   => 2,
      headings => [ "Kind", "Count", "(blessed)", "Bytes", "(blessed)" ],
      sep      => [ "    ", " ", "    ", " " ],
      align    => [ undef, "right", "right", "right", "right" ],
      %{ $opts{table_args} || {} },
   );
}

# Dump type codes → 0.54 count-table kind names (before PAD reclass).
my %TYPE_CODE_KIND = (
   1  => 'GLOB',
   2  => 'SCALAR',
   3  => 'REF',
   4  => 'ARRAY',
   5  => 'HASH',
   6  => 'STASH',
   7  => 'CODE',
   8  => 'IO',
   9  => 'LVALUE',
   10 => 'REGEXP',
   11 => 'FORMAT',
   12 => 'INVLIST',
   13 => 'UNDEF',
   14 => 'BOOL',   # YES → BOOL after reclass
   15 => 'BOOL',   # NO  → BOOL
   16 => 'OBJECT',
   17 => 'CLASS',
   0x7F => 'C_STRUCT',
);

sub _count_svs_rust_default
{
   my $self = shift;
   my ( $counts_href, $emit_count, $emit_bytes, $opts ) = @_;

   my $core = $self->df->rust_core;
   my $n    = $core->heap_count;

   # Mark ARRAYs that CODE fixup would reclass as PAD / PADLIST / PADNAMES.
   my %reclass;  # addr => kind
   for my $id ( 0 .. $n - 1 ) {
      my $row = $core->object_at($id) or next;
      next unless ( $row->[1] // 0 ) == 7;  # CODE
      my $d = $core->object_detail($id) or next;
      my $ptrs = $d->{ptrs} // [];
      if ( my $pl = $ptrs->[3] ) {
         $reclass{$pl} = 'PADLIST';
      }
      if ( my $pnat = $d->{code_padnames_at} ) {
         $reclass{$pnat} = 'PADNAMES';
      }
      for my $pad ( @{ $d->{code_pads} // [] } ) {
         my $paddr = ref($pad) eq 'ARRAY' ? $pad->[-1] : $pad;
         $reclass{$paddr} = 'PAD' if $paddr;
      }
   }

   my %counts;
   for my $id ( 0 .. $n - 1 ) {
      my $row = $core->object_at($id) or next;
      my ( $addr, $type, undef, $size, $blessed ) = @$row;
      my $kind = $reclass{$addr} // $TYPE_CODE_KIND{ $type // -1 } // sprintf( 'TYPE_%d', $type // -1 );
      my $c = $counts{$kind} //= Counts( ( 0 ) x 4 );
      $c->svs++;
      $c->bytes += $size // 0;
      if ( $blessed ) {
         $c->blessed_svs++;
         $c->blessed_bytes += $size // 0;
      }
   }
   %$counts_href = %counts;

   # Same table emission as the heap-walk path
   my @table;
   foreach my $kind ( sort keys %counts ) {
      my $c = $counts{$kind};
      push @table, [ $kind,
            $emit_count->( $kind, 0, $c->svs ),
            $emit_count->( $kind, 1, $c->blessed_svs ),
            $emit_bytes->( $kind, 0, $c->bytes ),
            $emit_bytes->( $kind, 1, $c->blessed_bytes ) ];
   }
   push @table, [];
   my $total = Counts( ( 0 ) x 4 );
   foreach my $method (qw( svs bytes blessed_svs blessed_bytes )) {
      $total->$method = sum map { $_->$method } values %counts;
   }
   push @table, [ "(total)",
      $emit_count->( "(total)", 0, $total->svs ),
      $emit_count->( "(total)", 1, $total->blessed_svs ),
      $emit_bytes->( "(total)", 0, $total->bytes ),
      $emit_bytes->( "(total)", 1, $total->blessed_bytes ) ];

   Devel::MAT::Cmd->print_table( \@table,
      indent   => 2,
      headings => [ "Kind", "Count", "(blessed)", "Bytes", "(blessed)" ],
      sep      => [ "    ", " ", "    ", " " ],
      align    => [ undef, "right", "right", "right", "right" ],
      %{ $opts->{table_args} || {} },
   );
}

sub _gen_package_breakdown
{
   my ( $counts, $emit_count, $emit_bytes ) = @_;

   my @packages = rev_nsort_by { $counts->{$_}->blessed_svs } sort keys %$counts;

   my @ret;

   my $count;
   while( @packages ) {
      my $package = shift @packages;

      push @ret,
         [
            "    " . Devel::MAT::Cmd->format_symbol( $package ),
            $emit_count->( $package, 0, 0 ),
            $emit_count->( $package, 1, $counts->{$package}->blessed_svs ),
            $emit_bytes->( $package, 0, 0 ),
            $emit_bytes->( $package, 1, $counts->{$package}->blessed_bytes ),
         ];

      $count++;
      last if $count >= 10;
   }

   my $remaining = Counts( ( 0 ) x 4 );
   foreach my $method (qw( blessed_svs blessed_bytes )) {
      $remaining->$method = sum map { $counts->{$_}->$method } @packages;
   }

   push @ret,
      [ "    " . Devel::MAT::Cmd->format_note( "(others)" ),
         $emit_count->( "(others)", 0, 0 ),
         $emit_count->( "(others)", 1, $remaining->blessed_svs ),
         $emit_bytes->( "(others)", 0, 0 ),
         $emit_bytes->( "(others)", 1, $remaining->blessed_bytes ),
      ] if @packages;

   return @ret;
}

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>

=cut

0x55AA;
