#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)

package Devel::MAT::Backend 0.54;

use v5.14;
use warnings;

use Carp;

=head1 NAME

C<Devel::MAT::Backend> - select Perl vs Rust dump load backend

=head1 SYNOPSIS

   use Devel::MAT::Backend;
   my $mode = Devel::MAT::Backend->mode;  # perl | rust | auto

=head1 DESCRIPTION

Controls which dump loader is used. Environment variable C<PMAT_BACKEND>:

=over 4

=item * C<rust> (default) — forced Rust C ABI path; B<never> silently falls back to Perl

=item * C<perl> — forced 0.54 Perl/XS path (oracle)

=item * C<auto> — prefer Rust when available, otherwise Perl. Fallback must not
be counted as a Rust pass in tests.

=back

=cut

# Captures last auto decision for tests / diagnostics.
our $LAST_RESOLVED;       # perl | rust
our $LAST_FALLBACK_REASON; # undef or string when auto fell back

sub env_name { 'PMAT_BACKEND' }

sub mode {
   my $key = env_name();
   # Default: rust (parity complete). Use PMAT_BACKEND=perl for the oracle path.
   my $raw = $ENV{$key} // 'rust';
   $raw = lc $raw;
   $raw =~ s/^\s+|\s+$//g;
   return $raw if $raw eq 'perl' || $raw eq 'rust' || $raw eq 'auto';
   croak "Invalid PMAT_BACKEND='$ENV{$key}' (want perl|rust|auto)";
}

sub rust_available {
   return 0 unless eval {
      require Devel::MAT::Core;
      Devel::MAT::Core->can('load') && Devel::MAT::Core::available();
   };
   return 1;
}

# Returns 'perl' or 'rust'. Under forced rust, croaks if Rust is unavailable
# instead of falling back.
sub resolve {
   my ( $class ) = @_;
   $LAST_FALLBACK_REASON = undef;
   my $mode = $class->mode;

   if ( $mode eq 'perl' ) {
      return $LAST_RESOLVED = 'perl';
   }
   if ( $mode eq 'rust' ) {
      croak "PMAT_BACKEND=rust but Devel::MAT::Core (pmat-core) is not available"
         unless $class->rust_available;
      return $LAST_RESOLVED = 'rust';
   }
   # auto
   if ( $class->rust_available ) {
      return $LAST_RESOLVED = 'rust';
   }
   $LAST_FALLBACK_REASON = 'rust library unavailable';
   return $LAST_RESOLVED = 'perl';
}

sub used_rust {
   return ( $LAST_RESOLVED // '' ) eq 'rust';
}

sub fell_back {
   return defined $LAST_FALLBACK_REASON;
}

1;
