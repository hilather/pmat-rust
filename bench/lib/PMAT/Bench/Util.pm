package PMAT::Bench::Util;
# Shared timing / memory helpers for the pmat benchmark suite.

use v5.14;
use warnings;

use Exporter 'import';
use Time::HiRes qw( gettimeofday tv_interval );
use JSON::PP ();
use overload ();

our @EXPORT_OK = qw(
   timed
   rss_kb
   peak_rss_kb
   format_bytes
   format_duration
   format_rate
   write_json
   read_json
   human_svs
);

sub timed (&) {
   my ( $code ) = @_;
   my $rss0 = rss_kb();
   my $t0   = [ gettimeofday ];
   my @ret  = $code->();
   my $secs = tv_interval($t0);
   my $rss1 = rss_kb();
   my $result = {
      seconds   => $secs,
      rss_kb    => $rss1,
      rss_delta_kb => defined $rss0 && defined $rss1 ? $rss1 - $rss0 : undef,
   };
   return ( $result, @ret );
}

# Current resident set size of this process in KiB, or undef.
sub rss_kb {
   if ( open my $fh, '<', "/proc/$$/status" ) {
      while ( my $line = <$fh> ) {
         if ( $line =~ /^VmRSS:\s+(\d+)\s+kB/ ) {
            return 0 + $1;
         }
      }
   }
   return undef;
}

sub peak_rss_kb {
   if ( open my $fh, '<', "/proc/$$/status" ) {
      while ( my $line = <$fh> ) {
         if ( $line =~ /^VmHWM:\s+(\d+)\s+kB/ ) {
            return 0 + $1;
         }
      }
   }
   return undef;
}

sub format_bytes {
   my ( $n ) = @_;
   return "n/a" unless defined $n;
   my @units = qw( B KiB MiB GiB TiB );
   my $u = 0;
   my $v = 0 + $n;
   while ( $v >= 1024 && $u < $#units ) {
      $v /= 1024;
      $u++;
   }
   return $u == 0 ? sprintf( "%d %s", $v, $units[$u] )
                  : sprintf( "%.2f %s", $v, $units[$u] );
}

sub format_duration {
   my ( $secs ) = @_;
   return "n/a" unless defined $secs;
   if ( $secs < 1 ) {
      return sprintf( "%.1f ms", $secs * 1000 );
   }
   if ( $secs < 60 ) {
      return sprintf( "%.3f s", $secs );
   }
   my $m = int( $secs / 60 );
   my $s = $secs - 60 * $m;
   return sprintf( "%dm %.1fs", $m, $s );
}

sub format_rate {
   my ( $count, $secs ) = @_;
   return "n/a" unless defined $count && defined $secs && $secs > 0;
   my $rate = $count / $secs;
   if ( $rate >= 1_000_000 ) {
      return sprintf( "%.2f M/s", $rate / 1_000_000 );
   }
   if ( $rate >= 1_000 ) {
      return sprintf( "%.1f k/s", $rate / 1_000 );
   }
   return sprintf( "%.1f /s", $rate );
}

sub human_svs {
   my ( $n ) = @_;
   return "n/a" unless defined $n;
   if ( $n >= 1_000_000 ) {
      return sprintf( "%.2fM", $n / 1_000_000 );
   }
   if ( $n >= 1_000 ) {
      return sprintf( "%.1fk", $n / 1_000 );
   }
   return "$n";
}

sub write_json {
   my ( $path, $data ) = @_;
   open my $fh, '>', $path or die "Cannot write $path: $!\n";
   print {$fh} JSON::PP->new
      ->canonical(1)
      ->pretty(1)
      ->allow_nonref(1)
      ->convert_blessed(1)
      ->encode( _json_clean($data) );
   close $fh;
}

# Collapse blessed refs (e.g. version objects from $VERSION) to plain data.
sub _json_clean {
   my ( $v ) = @_;
   return $v unless defined $v && ref $v;
   if ( ref $v eq 'ARRAY' ) {
      return [ map { _json_clean($_) } @$v ];
   }
   if ( ref $v eq 'HASH' ) {
      return { map { $_ => _json_clean( $v->{$_} ) } keys %$v };
   }
   # version / other objects
   if ( overload::Method( $v, '""' ) || eval { $v->can('stringify') } ) {
      return "$v";
   }
   return "$v";
}

sub read_json {
   my ( $path ) = @_;
   open my $fh, '<', $path or die "Cannot read $path: $!\n";
   local $/;
   my $raw = <$fh>;
   close $fh;
   return JSON::PP->new->decode($raw);
}

1;
