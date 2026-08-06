package PMAT::Bench::Runner;
# Run timed analysis phases against a .pmat dump.

use v5.14;
use warnings;

use File::Spec;

use PMAT::Bench::Util qw(
   timed format_bytes format_duration format_rate human_svs rss_kb peak_rss_kb
);

sub _silence (&);  # forward-declare so block form works at call sites

sub phases {
   return qw( load inrefs count sizes_struct sizes_owned reachability identify heap_walk );
}

sub run {
   my ( $class, $path, %opts ) = @_;
   my @want = @{ $opts{phases} // [qw( load inrefs count sizes_struct reachability identify heap_walk )] };
   my %want = map { $_ => 1 } @want;
   my $progress = $opts{progress};
   my $quiet_tools = $opts{quiet_tools} // 1;

   require Devel::MAT;
   require Commandable::Invocation;
   # Tools such as Count/Identify print via Devel::MAT::Cmd; install the
   # terminal implementation so printf/print_table exist (same as bin/pmat).
   require Devel::MAT::Cmd::Terminal;
   # Class/object SVs in modern dumps are still experimental in 0.54.
   local $SIG{__WARN__} = sub {
      return if $_[0] =~ /class features in PMAT file is experimental/;
      return if $_[0] =~ /marked mortal but there is no SV/;
      warn @_;
   };

   my %results = (
      path    => $path,
      bytes   => -s $path,
      phases  => {},
      host    => {
         perl => "$]",
         mat  => do {
            my $v = eval { $Devel::MAT::VERSION };
            defined $v ? "$v" : 'unknown';
         },
         rss_kb_start => rss_kb(),
      },
   );

   # ---- load ----
   my $pmat;
   if ( $want{load} || 1 ) {
      $progress->( "load $path ..." ) if $progress;
      my ( $t, $obj ) = timed {
         Devel::MAT->load( $path,
            progress => ( $opts{load_progress} ? $progress : undef ),
         );
      };
      $pmat = $obj;
      my $df = $pmat->dumpfile;
      my $heap_svs = scalar $df->heap;
      $results{heap_svs} = $heap_svs;
      $results{phases}{load} = {
         %$t,
         heap_svs   => $heap_svs,
         bytes_per_s => $t->{seconds} > 0 ? ( -s $path ) / $t->{seconds} : undef,
         svs_per_s   => $t->{seconds} > 0 ? $heap_svs / $t->{seconds} : undef,
      };
   }

   my $df = $pmat->dumpfile;
   my $heap_svs = $results{heap_svs} // scalar $df->heap;
   $results{heap_svs} = $heap_svs;

   # Ensure tools are discoverable.
   $pmat->available_tools;

   # ---- inrefs (critical; almost every other tool depends on it) ----
   if ( $want{inrefs} ) {
      $progress->( "inrefs ..." ) if $progress;
      my ( $t ) = timed {
         $pmat->load_tool( "Inrefs",
            progress => ( $opts{tool_progress} ? $progress : undef ),
         );
      };
      $results{phases}{inrefs} = {
         %$t,
         svs_per_s => $t->{seconds} > 0 ? $heap_svs / $t->{seconds} : undef,
      };
   }

   # ---- heap walk (raw outrefs scan, no tool state) ----
   if ( $want{heap_walk} ) {
      $progress->( "heap_walk ..." ) if $progress;
      my $n_refs = 0;
      my ( $t ) = timed {
         for my $sv ( $df->heap ) {
            # NO_DESC path is what Inrefs uses — cheap ref enumeration.
            my @r = $sv->outrefs( "NO_DESC" );
            $n_refs += @r / 2;
         }
      };
      $results{phases}{heap_walk} = {
         %$t,
         outrefs    => $n_refs,
         svs_per_s  => $t->{seconds} > 0 ? $heap_svs / $t->{seconds} : undef,
      };
   }

   # ---- count ----
   if ( $want{count} ) {
      $progress->( "count ..." ) if $progress;
      my ( $t ) = timed {
         my $tool = $pmat->load_tool("Count");
         _silence {
            $tool->count_svs();
         };
      };
      $results{phases}{count} = {
         %$t,
         svs_per_s => $t->{seconds} > 0 ? $heap_svs / $t->{seconds} : undef,
      };
   }

   # ---- sizes (structure) ----
   if ( $want{sizes_struct} ) {
      $progress->( "sizes_struct ..." ) if $progress;
      my ( $t ) = timed {
         $pmat->load_tool("Sizes");
         my $n = 0;
         my $total = 0;
         for my $sv ( $df->heap ) {
            $total += $sv->structure_size;
            last if ++$n >= ( $opts{sizes_limit} // $heap_svs );
         }
         $total;
      };
      $results{phases}{sizes_struct} = {
         %$t,
         svs_per_s => $t->{seconds} > 0 ? $heap_svs / $t->{seconds} : undef,
      };
   }

   # ---- sizes (owned) — can be very expensive; optional ----
   if ( $want{sizes_owned} ) {
      $progress->( "sizes_owned ..." ) if $progress;
      my $limit = $opts{owned_limit} // 5_000;
      my ( $t ) = timed {
         $pmat->load_tool("Sizes");
         my $n = 0;
         my $total = 0;
         for my $sv ( $df->heap ) {
            $total += $sv->owned_size;
            last if ++$n >= $limit;
         }
         $total;
      };
      $results{phases}{sizes_owned} = {
         %$t,
         sample_svs => $opts{owned_limit} // 5_000,
      };
   }

   # ---- reachability ----
   if ( $want{reachability} ) {
      $progress->( "reachability ..." ) if $progress;
      my ( $t ) = timed {
         # Reachability tool marks the heap in its constructor.
         $pmat->load_tool( "Reachability",
            progress => ( $opts{tool_progress} ? $progress : undef ),
         );
      };
      $results{phases}{reachability} = {
         %$t,
         svs_per_s => $t->{seconds} > 0 ? $heap_svs / $t->{seconds} : undef,
      };
   }

   # ---- identify (walk up from a leaf-ish SV) ----
   if ( $want{identify} ) {
      $progress->( "identify ..." ) if $progress;
      # Need inrefs for identify.
      $pmat->load_tool("Inrefs") unless $pmat->{tools}{Inrefs};

      my $target = _pick_identify_target($pmat);
      my ( $t ) = timed {
         $pmat->load_tool("Identify");
         if ( $target ) {
            _silence {
               eval {
                  $pmat->run_command(
                     Commandable::Invocation->new(
                        sprintf( "identify %#x", $target->addr )
                     )
                  );
                  1;
               } or do {
                  # Fallback: touch inrefs if command path is unavailable.
                  my @in = eval { $target->inrefs };
                  scalar @in;
               };
            };
         }
      };
      $results{phases}{identify} = {
         %$t,
         target_addr => $target ? sprintf( "%#x", $target->addr ) : undef,
         target_desc => $target ? $target->desc : undef,
      };
   }

   $results{host}{rss_kb_end}  = rss_kb();
   $results{host}{rss_kb_peak} = peak_rss_kb();
   $results{total_s} = 0;
   for my $ph ( values %{ $results{phases} } ) {
      $results{total_s} += $ph->{seconds} // 0;
   }

   return \%results;
}

# Redirect STDOUT (and STDERR noise from wide-char warnings) for tool UIs.
# Must rebind *STDOUT itself: Devel::MAT::Cmd::Terminal checks -t STDOUT and
# may call print_to_terminal, which ignores select().
sub _silence (&) {  ## no critic (ProhibitSubroutinePrototypes)
   my ( $code ) = @_;
   open my $null, '>:utf8', File::Spec->devnull() or return $code->();
   local *STDOUT = $null;
   local *STDERR = $null;
   my $ok = eval { $code->(); 1 };
   my $err = $@;
   die $err if !$ok;
   return;
}

sub _pick_identify_target {
   my ( $pmat ) = @_;
   my $df = $pmat->dumpfile;

   # Prefer a package global from our fixture if present.
   my $sv = eval { $pmat->find_symbol('@PMAT_BENCH_ROOT') };
   return $sv if $sv;

   # Else pick a non-immortal SCALAR with a PV if possible.
   for my $cand ( $df->heap ) {
      next if $cand->immortal;
      if ( $cand->type eq 'SCALAR' && eval { defined $cand->pv } ) {
         return $cand;
      }
   }

   # Fallback: any non-immortal SV.
   for my $cand ( $df->heap ) {
      return $cand unless $cand->immortal;
   }
   return undef;
}

sub format_report {
   my ( $class, $results ) = @_;
   my @out;
   push @out, sprintf(
      "Dump: %s (%s, %s SVs)",
      $results->{path},
      format_bytes( $results->{bytes} ),
      human_svs( $results->{heap_svs} ),
   );
   push @out, sprintf(
      "Host: perl %s  Devel::MAT %s  RSS start/end/peak %s / %s / %s",
      $results->{host}{perl},
      $results->{host}{mat},
      format_bytes( ( $results->{host}{rss_kb_start} // 0 ) * 1024 ),
      format_bytes( ( $results->{host}{rss_kb_end} // 0 ) * 1024 ),
      format_bytes( ( $results->{host}{rss_kb_peak} // 0 ) * 1024 ),
   );
   push @out, "";
   push @out, sprintf( "%-16s %12s %12s %14s %10s", "phase", "time", "RSS Δ", "throughput", "note" );
   push @out, "-" x 70;

   for my $name ( phases() ) {
      my $ph = $results->{phases}{$name} or next;
      my $thru = "";
      if ( defined $ph->{svs_per_s} ) {
         $thru = format_rate( $ph->{svs_per_s}, 1 ) =~ s/ \/s$/ SVs\/s/r;
         # format_rate expects count/secs; we already have rate. Reformat:
         $thru = _fmt_sv_rate( $ph->{svs_per_s} );
      }
      elsif ( defined $ph->{bytes_per_s} ) {
         $thru = format_bytes( $ph->{bytes_per_s} ) . "/s";
      }
      my $note = "";
      $note = $ph->{target_desc} if $name eq 'identify' && $ph->{target_desc};
      $note = sprintf( "%s outrefs", human_svs( $ph->{outrefs} ) )
         if $name eq 'heap_walk' && defined $ph->{outrefs};
      push @out, sprintf(
         "%-16s %12s %12s %14s %10s",
         $name,
         format_duration( $ph->{seconds} ),
         defined $ph->{rss_delta_kb}
            ? format_bytes( $ph->{rss_delta_kb} * 1024 )
            : "n/a",
         $thru || "-",
         $note,
      );
   }
   push @out, "-" x 70;
   push @out, sprintf( "Total measured: %s", format_duration( $results->{total_s} ) );
   return join( "\n", @out ) . "\n";
}

sub _fmt_sv_rate {
   my ( $rate ) = @_;
   return "n/a" unless defined $rate;
   if ( $rate >= 1_000_000 ) {
      return sprintf( "%.2fM SV/s", $rate / 1_000_000 );
   }
   if ( $rate >= 1_000 ) {
      return sprintf( "%.1fk SV/s", $rate / 1_000 );
   }
   return sprintf( "%.0f SV/s", $rate );
}

1;
