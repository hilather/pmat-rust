#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)

package Devel::MAT::Core 0.54;

use v5.14;
use warnings;

=head1 NAME

C<Devel::MAT::Core> - Perl interface to the Rust pmat-core library

=head1 DESCRIPTION

Thin wrapper around the C ABI of C<pmat-core>. When the shared library is not
built or loadable, L</available> is false and L</load> croaks.

All hot-path queries are batch-oriented (type counts, edge batches). Do not
add one-call-per-edge wrappers for production hot loops.

=cut

our $LOADED;
our $LOAD_ERROR;

BEGIN {
   # Load XS during compile. Do not reset $LOADED at runtime afterwards.
   eval {
      require XSLoader;
      XSLoader::load( __PACKAGE__, our $VERSION );
      $LOADED = 1;
      1;
   } or do {
      $LOAD_ERROR = $@ // 'XSLoader failed';
      $LOADED = 0;
   };
}

sub available {
   return 0 unless $LOADED;
   return 0 unless __PACKAGE__->can('_xs_available');
   return _xs_available() ? 1 : 0;
}

sub load {
   my ( $class, $path ) = @_;
   croak_unavailable() unless available();
   return _xs_load($path);
}

sub croak_unavailable {
   require Carp;
   Carp::croak(
      "Devel::MAT::Core (pmat-core) is not available"
      . ( $LOAD_ERROR ? ": $LOAD_ERROR" : "" )
   );
}

# Pure-Perl helpers used when XS returns raw data structures.

sub type_name {
   my ( $code ) = @_;
   state $names = {
      1 => 'GLOB', 2 => 'SCALAR', 3 => 'REF', 4 => 'ARRAY', 5 => 'HASH',
      6 => 'STASH', 7 => 'CODE', 8 => 'IO', 9 => 'LVALUE', 10 => 'REGEXP',
      11 => 'FORMAT', 12 => 'INVLIST', 13 => 'UNDEF', 14 => 'YES', 15 => 'NO',
      16 => 'OBJECT', 17 => 'CLASS', 0x7F => 'STRUCT',
   };
   return $names->{ $code } // sprintf( 'TYPE_%d', $code );
}

# Handle DESTROY is implemented in XS (Devel::MAT::Core::DESTROY / Handle).
package Devel::MAT::Core::Handle;
# XS methods are installed on Devel::MAT::Core; re-dispatch via inheritance.
our @ISA = qw( Devel::MAT::Core );

1;
