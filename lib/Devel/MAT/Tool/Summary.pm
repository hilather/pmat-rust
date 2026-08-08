#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2018-2024 -- leonerd@leonerd.org.uk

package Devel::MAT::Tool::Summary 0.54;

use v5.14;
use warnings;
use base qw( Devel::MAT::Tool );

use constant CMD => "summary";
use constant CMD_DESC => "Print basic information about the loaded dumpfile";

=head1 NAME

C<Devel::MAT::Tool::Summary> - show basic information about the dumpfile

=head1 DESCRIPTION

This C<Devel::MAT> tool displays a summary of the overall contents of the
dumpfile.

=head1 COMANDS

=cut

=head2 summary

   pmat> summary
   Perl memory dumpfile from perl 5.26.1 threaded
   Heap contains 3315 objects

Prints basic information about the dumpfile - the version of perl that created
it, and the number of SVs it contains.

=cut

sub run
{
   my $self = shift;

   my $df = $self->df;

   Devel::MAT::Cmd->printf( "Perl memory dumpfile from perl %s %s\n",
      $df->perlversion, $df->ithreads ? "threaded" : "non-threaded" );

   # Prefer core heap_count under forced-Rust so summary does not force
   # full proxy materialization via heap() (OPT open-path / large dumps).
   my $n;
   if ( $df->can('rust_core') && $df->rust_core && $df->rust_core->can('heap_count') ) {
      $n = $df->rust_core->heap_count;
   }
   else {
      $n = scalar $df->heap;
   }

   Devel::MAT::Cmd->printf( "Heap contains %d objects\n", $n );
}

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>

=cut

0x55AA;
