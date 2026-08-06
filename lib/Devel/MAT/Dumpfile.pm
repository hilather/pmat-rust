#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2013-2024 -- leonerd@leonerd.org.uk

package Devel::MAT::Dumpfile 0.54;

use v5.14;
use warnings;

use Carp;
use IO::Handle;   # ->read
use IO::Seekable; # ->tell

use List::Util qw( pairmap );

use Devel::MAT::SV;
use Devel::MAT::Context;

use Struct::Dumb 0.07 qw( readonly_struct );
readonly_struct StructType => [qw( name fields )];
readonly_struct StructField => [qw( name type )];

use constant {
   PMAT_SVxMAGIC => 0x80,
};

=head1 NAME

C<Devel::MAT::Dumpfile> - load and analyse a heap dump file

=head1 SYNOPSIS

   use Devel::MAT::Dumpfile;

   my $df = Devel::MAT::Dumpfile->load( "path/to/the/file.pmat" );

=head1 DESCRIPTION

This module provides a class that loads a heap dump file previously written by
L<Devel::MAT::Dumper>. It provides accessor methods to obtain various
well-known root starting addresses, or to find arbitrary SVs by address. Each
SV is represented by an instance of L<Devel::MAT::SV>.

=cut

my @ROOTS;
my %ROOTDESC;
foreach (
   [ sv_undef        => "+the undef SV" ],
   [ sv_yes          => "+the true SV" ],
   [ sv_no           => "+the false SV" ],
   [ main_cv         => "+the main code" ],
   [ defstash        => "+the default stash" ],
   [ mainstack       => "+the main stack AV" ],
   [ beginav         => "+the BEGIN list" ],
   [ checkav         => "+the CHECK list" ],
   [ unitcheckav     => "+the UNITCHECK list" ],
   [ initav          => "+the INIT list" ],
   [ endav           => "+the END list" ],
   [ strtab          => "+the shared string table HV" ],
   [ envgv           => "-the ENV GV" ],
   [ incgv           => "+the INC GV" ],
   [ statgv          => "+the stat GV" ],
   [ statname        => "+the statname SV" ],
   [ tmpsv           => "-the temporary SV" ],
   [ defgv           => "+the default GV" ],
   [ argvgv          => "-the ARGV GV" ],
   [ argvoutgv       => "+the argvout GV" ],
   [ argvout_stack   => "+the argvout stack AV" ],
   [ errgv           => "+the *@ GV" ],
   [ fdpidav         => "+the FD-to-PID mapping AV" ],
   [ preambleav      => "+the compiler preamble AV" ],
   [ modglobalhv     => "+the module data globals HV" ],
   [ regex_padav     => "+the REGEXP pad AV" ],
   [ sortstash       => "+the sort stash" ],
   [ firstgv         => "-the *a GV" ],
   [ secondgv        => "-the *b GV" ],
   [ debstash        => "-the debugger stash" ],
   [ stashcache      => "+the stash cache" ],
   [ isarev          => "+the reverse map of \@ISA dependencies" ],
   [ registered_mros => "+the registered MROs HV" ],
   [ rs              => "+the IRS" ],
   [ last_in_gv      => "+the last input GV" ],
   [ ofsgv           => "+the OFS GV" ],
   [ defoutgv        => "+the default output GV" ],
   [ hintgv          => "-the hints (%^H) GV" ],
   [ patchlevel      => "+the patch level" ],
   [ apiversion      => "+the API version" ],
   [ e_script        => "+the '-e' script" ],
   [ mess_sv         => "+the message SV" ],
   [ ors_sv          => "+the ORS SV" ],
   [ encoding        => "+the encoding" ],
   [ blockhooks      => "+the block hooks" ],
   [ custom_ops      => "+the custom ops HV" ],
   [ custom_op_names => "+the custom op names HV" ],
   [ custom_op_descs => "+the custom op descriptions HV" ],
   map { [ $_ => "+the $_" ] } qw(
      Latin1 UpperLatin1 AboveLatin1 NonL1NonFinalFold HasMultiCharFold
      utf8_mark utf8_X_regular_begin utf8_X_extend utf8_toupper utf8_totitle
      utf8_tolower utf8_tofold utf8_charname_begin utf8_charname_continue
      utf8_idstart utf8_idcont utf8_xidstart utf8_perl_idstart utf8_perl_idcont
      utf8_xidcont utf8_foldclosures utf8_foldable ),
) {
   my ( $name, $desc ) = @$_;
   push @ROOTS, $name;
   $ROOTDESC{$name} = $desc;

   # Autogenerate the accessors
   my $code = sub {
      my $self = shift;
      $self->{roots}{$name} ? $self->sv_at( $self->{roots}{$name}[0] ) : undef;
   };
   no strict 'refs';
   *$name = $code;
}

*ROOTS = sub { @ROOTS };

=head1 CONSTRUCTOR

=cut

=head2 load

   $df = Devel::MAT::Dumpfile->load( $path, %args );

Loads a heap dump file from the given path, and returns a new
C<Devel::MAT::Dumpfile> instance representing it.

Takes the following named arguments:

=over 8

=item progress => CODE

If given, should be a CODE reference to a function that will be called
regularly during the loading process, and given a status message to update the
user.

=back

=cut

sub load
{
   my $class = shift;
   my ( $path, %args ) = @_;

   require Devel::MAT::Backend;
   my $backend = Devel::MAT::Backend->resolve;
   if ( $backend eq 'rust' ) {
      return $class->_load_rust( $path, %args );
   }
   return $class->_load_perl( $path, %args );
}

# Forced-Rust path: parse via pmat-core, materialize full SV proxies so tools
# (identify, sizes, reachability, plugins) match 0.54 oracle behaviour.
sub _load_rust
{
   my $class = shift;
   my ( $path, %args ) = @_;

   my $progress = $args{progress};
   $progress->( "Loading file $path (rust)..." ) if $progress;

   require Devel::MAT::Core;
   my $core = Devel::MAT::Core->load( $path );

   # Default host-endian 64-bit; override if needed by dump meta later.
   my $self = bless {
      backend   => 'rust',
      rust_core => $core,
      path      => $path,
      big_endian => 0,
      u32_fmt    => 'L<',
      u64_fmt    => 'Q<',
      uint_len   => 8,
      uint_fmt   => 'Q<',
      ptr_len    => 8,
      ptr_fmt    => 'Q<',
      nv_len     => 8,
      nv_fmt     => 'd<',
      ithreads   => $core->ithreads ? 1 : 0,
      format_minor => $core->format_minor,
      perlver    => $core->perlver,
      minus_1    => unpack( 'Q<', pack( 'Q<', -1 ) ),
      heap       => {},
      roots      => {},
      contexts   => [],
      stack_at   => [],
      protosubs_by_oproot => {},
      structtypes_by_id   => {},
      sv_sizes   => [],
      svx_sizes  => [],
      ctx_sizes  => [],
      _proxy_by_id => [],  # ObjectId => proxy for PAR-070 identity
   }, $class;

   # Roots
   my $roots = $self->{roots} = {};
   for my $r ( @{ $core->roots } ) {
      my $name = $r->{name};
      my $desc = $ROOTDESC{$name} // $name;
      $desc =~ m/^[+-]/ or $desc = "+$desc";
      $roots->{$name} = [ $r->{addr}, $desc ];
   }

   # Immortal objects for undef/yes/no (same construction as Perl path)
   for my $imm (qw( undef yes no )) {
      my $key = "sv_$imm";
      my $addr = $roots->{$key}[0] // next;
      my $iclass = "Devel::MAT::SV::\U$imm";
      $self->{ uc $imm } = $iclass->new( $self, $addr );
      $self->{"${imm}_at"} = $addr;
   }

   # Materialize heap SV proxies with full type payloads
   $progress->( "Materializing SV proxies from rust core..." ) if $progress;
   my $heap  = $self->{heap};
   my $total = $core->heap_count;
   for my $id ( 0 .. $total - 1 ) {
      warn "DETAIL $id
" if $ENV{PMAT_DEBUG_RUST};
      my $detail = $core->object_detail($id) or next;
      warn "MAKE $id type=$detail->{type}
" if $ENV{PMAT_DEBUG_RUST};
      my $sv = eval { _rust_make_sv_full( $self, $id, $detail ) };
      if ($@) { warn "MAKE FAIL id=$id type=$detail->{type}: $@"; die $@ }
      if ( $sv ) {
         $heap->{ $detail->{addr} } = $sv;
         $self->{_proxy_by_id}[$id] = $sv;
      }
      $progress->( sprintf "Materializing %d of %d (%.2f%%)",
         $id + 1, $total, 100 * ( $id + 1 ) / ( $total || 1 ) )
         if $progress && ( ( $id + 1 ) % 20000 ) == 0;
   }

   # Stack
   $self->{stack_at} = [ @{ $core->stack // [] } ];

   # Mortals
   my $mortals = $core->mortals // [];
   if ( @$mortals ) {
      $self->{mortals_at} = [ @$mortals ];
      for my $addr ( @$mortals ) {
         my $sv = $self->sv_at($addr) or next;
         $sv->_set_is_mortal if $sv->can('_set_is_mortal');
      }
   }

   # Contexts (call stack)
   require Devel::MAT::Context;
   my @contexts;
   if ( $core->can('contexts_raw') ) {
      for my $cr ( @{ $core->contexts_raw // [] } ) {
         my $ctype = $cr->{type} // next;
         my $ctx = eval {
            Devel::MAT::Context->new(
               $ctype, $self,
               $cr->{common_header} // '',
               undef,
               $cr->{common_strs} // [],
            );
         };
         next unless $ctx;
         eval {
            $ctx->load(
               $cr->{type_header} // '',
               $cr->{type_ptrs} // [],
               [],
            );
         };
         push @contexts, $ctx;
      }
   }
   $self->{contexts} = \@contexts;

   # Depth fixup for SUB contexts (format_minor >= 2)
   if ( $self->{format_minor} >= 2 ) {
      my %prev_depth_by_cvaddr;
      foreach my $ctx ( @contexts ) {
         next unless $ctx->type eq "SUB";
         my $cvaddr = $ctx->{cv_at};
         my $cv = $self->sv_at($cvaddr);
         $ctx->_set_depth( $prev_depth_by_cvaddr{$cvaddr} // ( $cv ? $cv->depth : 0 ) );
         $prev_depth_by_cvaddr{$cvaddr} = $ctx->olddepth;
      }
   }

   # Root name annotations
   foreach my $name ( keys %$roots ) {
      my $sv = $self->root( $name ) or next;
      $sv->{rootname} = $name;
   }

   # Protosubs by oproot (must exist before fixup links clones)
   my $protosubs = $self->{protosubs_by_oproot} = {};
   for my $sv ( values %$heap ) {
      next unless $sv->type eq 'CODE' and $sv->can('oproot') and $sv->oproot and $sv->is_clone;
      $protosubs->{ $sv->oproot } = $sv;
   }

   # Fixups (PADLIST/PADNAMES reclass, glob_at, protosub, ithread consts)
   $self->_fixup( %args ) unless $args{no_fixup};

   $progress->() if $progress;
   return $self;
}

# One strongly-cached proxy per ObjectId (PAR-070).
sub rust_proxy_for_id
{
   my $self = shift;
   my ( $id ) = @_;
   return $self->{_proxy_by_id}[$id] if defined $self->{_proxy_by_id}[$id];
   return undef;
}

sub _rust_make_sv_full
{
   my ( $df, $id, $d ) = @_;
   my $type = $d->{type};
   my $addr = $d->{addr};
   my $refcnt = $d->{refcnt};
   my $size = $d->{size};
   my $blessed = $d->{blessed} // 0;

   state $type_class = {
      1  => 'Devel::MAT::SV::GLOB',
      2  => 'Devel::MAT::SV::SCALAR',
      3  => 'Devel::MAT::SV::REF',
      4  => 'Devel::MAT::SV::ARRAY',
      5  => 'Devel::MAT::SV::HASH',
      6  => 'Devel::MAT::SV::STASH',
      7  => 'Devel::MAT::SV::CODE',
      8  => 'Devel::MAT::SV::IO',
      9  => 'Devel::MAT::SV::LVALUE',
      10 => 'Devel::MAT::SV::REGEXP',
      11 => 'Devel::MAT::SV::FORMAT',
      12 => 'Devel::MAT::SV::INVLIST',
      13 => 'Devel::MAT::SV::_UNDEFSV',
      14 => 'Devel::MAT::SV::_YESSV',
      15 => 'Devel::MAT::SV::_NOSV',
      16 => 'Devel::MAT::SV::OBJECT',
      17 => 'Devel::MAT::SV::CLASS',
      0x7F => 'Devel::MAT::SV::C_STRUCT',
      0xff => 'Devel::MAT::SV::Unknown',
   };

   require Devel::MAT::SV;
   my $class = $type_class->{$type} // 'Devel::MAT::SV::Unknown';
   my $self = bless {}, $class;
   $self->_set_core_fields( $type, $df, $addr, $refcnt, $size, $blessed );

   my $header = $d->{header} // '';
   my $ptrs   = $d->{ptrs} // [];
   my $strs   = $d->{strs} // [];

   if ( $type == 1 ) {
      # GLOB: header = UINT line + PTR name_hek; ptrs 0..7; strs name,file (order: NAME, FILE in load)
      my ( $line, $name_hek ) = ( 0, 0 );
      if ( length $header >= $df->{uint_len} + $df->{ptr_len} ) {
         ( $line, $name_hek ) = unpack "$df->{uint_fmt} $df->{ptr_fmt}", $header;
      }
      $self->_set_glob_fields(
         map { $_ // 0 } @{$ptrs}[0..7],
         $name_hek // 0, $line // 0,
         $strs->[1],  # file
         $strs->[0],  # name
      );
   }
   elsif ( $type == 2 ) {
      my ( $flags, $uv, $nvbytes, $pvlen ) = ( 0, 0, "\0" x $df->{nv_len}, 0 );
      if ( length $header ) {
         eval {
            ( $flags, $uv, $nvbytes, $pvlen ) =
               unpack "C $df->{uint_fmt} a$df->{nv_len} $df->{uint_fmt}", $header;
         };
      }
      my $nv = 0;
      eval { $nv = unpack "$df->{nv_fmt}", $nvbytes // ("\0" x $df->{nv_len}); };
      my $pv = $strs->[0];
      $pv = "" unless defined $pv;
      # _set_scalar_fields may swipe PV buffer; pass a copy
      my $pv_sv = $pv;
      $self->_set_scalar_fields( $flags // 0, $uv // 0, $nv, $pv_sv, $pvlen // length($pv), $ptrs->[0] // 0 );
   }
   elsif ( $type == 3 ) {
      my $flags = length $header ? unpack( "C", $header ) : 0;
      $self->_set_ref_fields( $ptrs->[0] // 0, $ptrs->[1] // 0, $flags & 0x01 );
   }
   elsif ( $type == 4 ) {
      my $flags = $d->{array_flags} // 0;
      my $elems = $d->{elems} // [];
      $self->_set_array_fields( $flags, $elems );
   }
   elsif ( $type == 5 || $type == 6 || $type == 17 ) {
      my $backrefs = $ptrs->[0] // 0;
      my $hv = $d->{hash_values} // {};
      $self->_set_hash_fields( $backrefs, $hv );
      if ( $type == 6 || $type == 17 ) {
         my $mro = $d->{mro_ptrs} // [];
         @{$self}{qw( mro_linearall_at mro_linearcurrent_at mro_nextmethod_at mro_isa_at )} =
            map { $_ // 0 } @$mro[0..3];
         $self->{name} = $d->{stash_name} // $strs->[-1] // '';
      }
      if ( $type == 17 ) {
         # CLASS field definitions
         $self->{fields} = [ map { [ $_->[0], $_->[1] ] } @{ $d->{class_fields} // [] } ];
         # remaining ptr after STASH portion may be adjust_blocks
         my $mro = $d->{mro_ptrs} // [];
         # if CLASS has adjust_blocks beyond STASH mro, it is in ptrs after stash count;
         # best-effort: last type ptr
         $self->{adjust_blocks_at} = $ptrs->[-1] if @$ptrs;
      }
   }
   elsif ( $type == 7 ) {
      my ( $line, $flags, $oproot, $depth, $name_hek ) = ( 0, 0, 0, -1, 0 );
      if ( length $header ) {
         eval {
            ( $line, $flags, $oproot, $depth, $name_hek ) =
               unpack "$df->{uint_fmt} C $df->{ptr_fmt} $df->{u32_fmt} $df->{ptr_fmt}", $header;
         };
      }
      defined $depth or $depth = -1;
      $name_hek //= 0;
      # ptrs: STASH, GV(glob), OUTSIDE, PADLIST, CONSTVAL — load uses [0,2..4]
      # Empty NAME string must stay undef so hekname is undef and symname
      # falls through to the GLOB name (e.g. __ANON__).
      my $code_file = $strs->[0];
      my $code_name = $strs->[1];
      $code_name = undef if defined $code_name && $code_name eq '';
      $self->_set_code_fields(
         $line // 0, $flags // 0, $oproot // 0, $depth, $name_hek,
         $ptrs->[0] // 0,  # stash
         $ptrs->[2] // 0,  # outside
         $ptrs->[3] // 0,  # padlist
         $ptrs->[4] // 0,  # constval
         $code_file, $code_name,
      );
      $self->_set_glob_at( $ptrs->[1] // 0 ) if $self->can('_set_glob_at');
      $self->{consts_at} = [ @{ $d->{code_consts} // [] } ];
      $self->{gvs_at}    = [ @{ $d->{code_gvs} // [] } ];
      $self->{constix}   = [ @{ $d->{code_constix} // [] } ];
      $self->{gvix}      = [ @{ $d->{code_gvix} // [] } ];
      if ( my $pnat = $d->{code_padnames_at} ) {
         $self->_set_padnames_at($pnat) if $self->can('_set_padnames_at');
      }
      for my $pad ( @{ $d->{code_pads} // [] } ) {
         my ( $depth, $paddr ) = @$pad;
         $self->{pads_at}[$depth] = $paddr;
      }
      # Padnames (inline, for older perls)
      if ( @{ $d->{code_padnames} // [] } ) {
         require Struct::Dumb;
         # Padname struct already defined in CODE package
         for my $pn ( @{ $d->{code_padnames} } ) {
            my $padix = $pn->{padix};
            $self->{padnames}[$padix] = Devel::MAT::SV::CODE::Padname(
               $pn->{name}, $pn->{ourstash}, $pn->{flags} & 0xff,
               $pn->{fieldix} // 0, $pn->{fieldstash} // 0,
            );
            # field flag bit
            if ( $pn->{flags} & 0x100 ) {
               $self->{padnames}[$padix]->flags = $self->{padnames}[$padix]->flags | 0x100;
            }
         }
      }
      $self->{padnames} = [] if $df->{perlver} > ( ( 5 << 24 ) | ( 20 << 16 ) | 0xffff )
         && !@{ $self->{padnames} // [] };
   }
   elsif ( $type == 8 ) {
      my ( $ifileno, $ofileno ) = ( -1, -1 );
      if ( length $header >= 2 * $df->{uint_len} ) {
         ( $ifileno, $ofileno ) = unpack "$df->{uint_fmt}2", $header;
         defined $_ and $_ == $df->{minus_1} and $_ = -1 for ( $ifileno, $ofileno );
      }
      @{$self}{qw( ifileno ofileno )} = ( $ifileno, $ofileno );
      @{$self}{qw( topgv_at formatgv_at bottomgv_at )} = map { $_ // 0 } @{$ptrs}[0..2];
   }
   elsif ( $type == 9 ) {
      if ( length $header ) {
         eval {
            ( $self->{type}, $self->{off}, $self->{len} ) =
               unpack "a1 $df->{uint_fmt}2", $header;
         };
      }
      $self->{targ_at} = $ptrs->[0] // 0;
   }
   elsif ( $type == 14 ) {
      bless $self, "Devel::MAT::SV::BOOL";
      $self->_set_scalar_fields( 0x01, 1, 1.0, "1", 1, 0 );
   }
   elsif ( $type == 15 ) {
      bless $self, "Devel::MAT::SV::BOOL";
      $self->_set_scalar_fields( 0x01, 0, 0, "", 0, 0 );
   }
   elsif ( $type == 16 ) {
      my $fields = $d->{elems} // [];
      $self->_set_object_fields( $fields ) if $self->can('_set_object_fields');
   }
   elsif ( $type == 13 ) {
      bless $self, "Devel::MAT::SV::SCALAR";
      $self->_set_scalar_fields( 0, 0, 0, "", 0, 0 );
   }

   # Magic
   for my $m ( @{ $d->{magic} // [] } ) {
      my ( $tb, $flags, $obj, $ptr, $vtbl ) = @$m;
      my $typec = chr($tb // 0);
      eval { $self->more_magic( $typec => $flags // 0, $obj // 0, $ptr // 0, $vtbl // 0 ); };
      warn "magic fail: $@" if $@;
   }

   # Annotations
   for my $a ( @{ $d->{annotations} // [] } ) {
      my ( $val_at, $name ) = @$a;
      $self->_more_annotations( $val_at, $name );
   }

   # Saved slots (SVx 0x81-0x86)
   for my $s ( @{ $d->{saved} // [] } ) {
      my ( $kind, $idx, $saddr ) = @$s;
      if ( $kind == 1 ) { $self->_more_saved( SCALAR => $saddr ) if $self->can('_more_saved'); }
      elsif ( $kind == 2 ) { $self->_more_saved( ARRAY => $saddr ) if $self->can('_more_saved'); }
      elsif ( $kind == 3 ) { $self->_more_saved( HASH => $saddr ) if $self->can('_more_saved'); }
      elsif ( $kind == 4 ) { $self->_more_saved( $idx, $saddr ) if $self->can('_more_saved'); } # ARRAY elem
      elsif ( $kind == 5 ) { $self->_more_saved( $idx, $saddr ) if $self->can('_more_saved'); } # HASH key,val
      elsif ( $kind == 6 ) { $self->_more_saved( CODE => $saddr ) if $self->can('_more_saved'); }
   }

   return $self;
}

sub rust_core
{
   my $self = shift;
   return $self->{rust_core};
}

sub backend
{
   my $self = shift;
   return $self->{backend} // 'perl';
}

sub _load_perl
{
   my $class = shift;
   my ( $path, %args ) = @_;

   my $progress = $args{progress};

   $progress->( "Loading file $path..." ) if $progress;

   open my $fh, "<", $path or croak "Cannot read $path - $!";
   my $self = bless { fh => $fh, backend => 'perl' }, $class;

   my $filelen = -s $fh;

   # Header
   $self->_read(4) eq "PMAT" or croak "File magic signature not found";

   my $flags = $self->_read_u8;

   my $endian = ( $self->{big_endian} = $flags & 0x01 ) ? ">" : "<";

   my $u32_fmt = $self->{u32_fmt} = "L$endian";
   my $u64_fmt = $self->{u64_fmt} = "Q$endian";

   @{$self}{qw( uint_len uint_fmt )} =
      ( $flags & 0x02 ) ? ( 8, $u64_fmt ) : ( 4, $u32_fmt );

   @{$self}{qw( ptr_len ptr_fmt )} =
      ( $flags & 0x04 ) ? ( 8, $u64_fmt ) : ( 4, $u32_fmt );

   @{$self}{qw( nv_len nv_fmt )} =
      ( $flags & 0x08 ) ? ( 10, "D$endian" ) : ( 8, "d$endian" );

   $self->{ithreads} = !!( $flags & 0x10 );

   $flags &= ~0x1f;
   die sprintf "Cannot read %s - unrecognised flags %x\n", $path, $flags if $flags;

   $self->{minus_1} = unpack $self->{uint_fmt}, pack $self->{uint_fmt}, -1;

   $self->_read_u8 == 0 or die "Cannot read $path - 'zero' header field is not zero";

   $self->_read_u8 == 0 or die "Cannot read $path - format version major unrecognised";

   ( $self->{format_minor} = $self->_read_u8 ) <= 6 or
      die "Cannot read $path - format version minor unrecognised ($self->{format_minor})";

   if( $self->{format_minor} < 1 ) {
      warn "Loading an earlier format of dumpfile - SV MAGIC annotations may be incorrect\n";
   }

   $self->{perlver} = $self->_read_u32;

   my $n_types = $self->_read_u8;
   my @sv_sizes = unpack "(a3)*", my $tmp = $self->_read( $n_types * 3 );
   $self->{sv_sizes} = [ map [ unpack "C C C", $_ ], @sv_sizes ];

   if( $self->{format_minor} >= 4 ) {
      my $n_extns = $self->_read_u8;
      my @extn_sizes = unpack "(a3)*", my $tmp = $self->_read( $n_extns * 3 );
      $self->{svx_sizes} = [ map [ unpack "C C C", $_ ], @extn_sizes ];
   }
   else {
      # versions < 4 had just one, PMAT_SVxMAGIC
      $self->{svx_sizes} = [
         [ 2, 2, 0 ],  # PMAT_SVxMAGIC
      ];
   }

   if( $self->{format_minor} >= 2 ) {
      my $n_ctxs = $self->_read_u8;
      my @ctx_sizes = unpack "(a3)*", my $tmp = $self->_read( $n_ctxs * 3 );
      $self->{ctx_sizes} = [ map [ unpack "C C C", $_ ], @ctx_sizes ];
   }

   $self->{structtypes_by_id} = {};

   # Roots
   foreach (qw( undef yes no )) {
      my $addr = $self->{"${_}_at"} = $self->_read_ptr;
      my $class = "Devel::MAT::SV::\U$_";
      $self->{uc $_} = $class->new( $self, $addr );
   }

   $self->{roots} = \my %roots;
   # The three immortals
   $roots{"sv_$_"} = [ $self->{"\U$_"}->addr, $ROOTDESC{"sv_$_"} ] for qw( undef yes no );

   foreach ( 1 .. $self->_read_u32 ) {
      my $name = $self->_read_str;
      my $desc = $ROOTDESC{$name} // $name;
      $desc =~ m/^[+-]/ or $desc = "+$desc";
      $roots{$name} = [ $self->_read_ptr, $desc ];
   }

   # Stack
   my $stacksize = $self->_read_uint;
   $self->{stack_at} = [ map { $self->_read_ptr } 1 .. $stacksize ];

   # Heap
   $self->{heap} = \my %heap;
   $self->{protosubs_by_oproot} = \my %protosubs_by_oproot;
   while( my $sv = $self->_read_sv ) {
      $heap{$sv->addr} = $sv;

      # Also identify the protosub of every oproot
      if( $sv->type eq "CODE" and $sv->oproot and $sv->is_clone ) {
         $protosubs_by_oproot{$sv->oproot} = $sv;
      }

      my $pos = $fh->IO::Seekable::tell; # fully-qualified method for 5.010
      $progress->( sprintf "Loading file %d of %d bytes (%.2f%%)",
         $pos, $filelen, 100*$pos / $filelen ) if $progress and (keys(%heap) % 5000) == 0;
   }

   # Contexts
   $self->{contexts} = \my @contexts;
   while( my $ctx = $self->_read_ctx ) {
      push @contexts, $ctx;
   }

   # From here onwards newer files have mortals, older ones don't
   if( my $mortalcount = $self->_read_uint ) {
      $self->{mortals_at} = \my @mortals_at;
      push @mortals_at, $self->_read_ptr for 1 .. $mortalcount;
      foreach my $addr ( @mortals_at ) {
         my $sv = $self->sv_at( $addr );
         unless( $sv ) {
            warn sprintf "SV address 0x%x is marked mortal but there is no SV", $addr;
            next;
         }
         $sv->_set_is_mortal;
      }
      $self->{mortal_floor} = $self->_read_uint;
   }

   $self->_fixup( %args ) unless $args{no_fixup};

   return $self;
}

sub structtype
{
   my $self = shift;
   my ( $id ) = @_;

   return $self->{structtypes_by_id}{$id} //
      croak "Dumpfile does not define a struct type of ID=$id\n";
}

sub _fixup
{
   my $self = shift;
   my %args = @_;

   my $progress = $args{progress};

   my $heap = $self->{heap};

   my $heap_total = scalar keys %$heap;

   # Annotate each root SV
   foreach my $name ( keys %{ $self->{roots} } ) {
      my $sv = $self->root( $name ) or next;
      $sv->{rootname} = $name;
   }

   my $count = 0;
   while( my ( $addr ) = each %$heap ) {
      my $sv = $heap->{$addr} or next;

      # While dumping we weren't able to determine what ARRAYs were really
      # PADLISTs. Now we can fix them up
      $sv->_fixup if $sv->can( "_fixup" );

      $count++;
      $progress->( sprintf "Fixing %d of %d (%.2f%%)",
         $count, $heap_total, 100*$count / $heap_total ) if $progress and ($count % 20000) == 0;
   }

   # Walk the SUB contexts setting their true depth
   if( $self->{format_minor} >= 2 ) {
      my %prev_depth_by_cvaddr;

      foreach my $ctx ( @{ $self->{contexts} } ) {
         next unless $ctx->type eq "SUB";

         my $cvaddr = $ctx->{cv_at};
         $ctx->_set_depth( $prev_depth_by_cvaddr{$cvaddr} // $ctx->cv->depth );

         $prev_depth_by_cvaddr{$cvaddr} = $ctx->olddepth;
      }
   }

   return $self;
}

# Nicer interface to IO::Handle
sub _read
{
   my $self = shift;
   my ( $len ) = @_;
   return "" if $len == 0;
   defined( $self->{fh}->read( my $buf, $len ) ) or croak "Cannot read - $!";
   return $buf;
}

sub _read_u8
{
   my $self = shift;
   defined( $self->{fh}->read( my $buf, 1 ) ) or croak "Cannot read - $!";
   return unpack "C", $buf;
}

sub _read_u32
{
   my $self = shift;
   defined( $self->{fh}->read( my $buf, 4 ) ) or croak "Cannot read - $!";
   return unpack $self->{u32_fmt}, $buf;
}

sub _read_u64
{
   my $self = shift;
   defined( $self->{fh}->read( my $buf, 8 ) ) or croak "Cannot read - $!";
   return unpack $self->{u64_fmt}, $buf;
}

sub _read_uint
{
   my $self = shift;
   defined( $self->{fh}->read( my $buf, $self->{uint_len} ) ) or croak "Cannot read - $!";
   return unpack $self->{uint_fmt}, $buf;
}

sub _read_ptr
{
   my $self = shift;
   defined( $self->{fh}->read( my $buf, $self->{ptr_len} ) ) or croak "Cannot read - $!";
   return unpack $self->{ptr_fmt}, $buf;
}

sub _read_ptrs
{
   my $self = shift;
   my ( $n ) = @_;
   defined( $self->{fh}->read( my $buf, $self->{ptr_len} * $n ) ) or croak "Cannot read - $!";
   return unpack "$self->{ptr_fmt}$n", $buf;
}

sub _read_nv
{
   my $self = shift;
   defined( $self->{fh}->read( my $buf, $self->{nv_len} ) ) or croak "Cannot read - $!";
   return unpack $self->{nv_fmt}, $buf;
}

sub _read_str
{
   my $self = shift;
   my $len = $self->_read_uint;
   return undef if $len == $self->{minus_1};
   return $self->_read($len);
}

sub _read_bytesptrsstrs
{
   my $self = shift;
   my ( $nbytes, $nptrs, $nstrs ) = @_;

   return
      ( $nbytes ? $self->_read( $nbytes ) : "" ),
      ( $nptrs  ? [ $self->_read_ptrs( $nptrs ) ] : undef ),
      ( $nstrs  ? [ map { $self->_read_str } 1 .. $nstrs ] : undef );
}

sub _read_sv
{
   my $self = shift;

   while(1) {
      my $type = $self->_read_u8;
      return if !$type;

      if( $type >= 0xF1 ) {
         die sprintf "Unrecognised META tag %02X\n", $type;
      }
      elsif( $type == 0xF0 ) {
         # META_STRUCT
         my $id = $self->_read_uint;
         my $nfields = $self->_read_uint;
         my $name = $self->_read_str;

         my @fields;
         push @fields, StructField(
            $self->_read_str,
            $self->_read_u8,
         ) for 1 .. $nfields;

         $self->{structtypes_by_id}{$id} = StructType(
            $name, \@fields,
         );

         next;
      }
      elsif( $type >= 0x80 ) {
         my $sizes = $self->{svx_sizes}[$type - 0x80];

         if( $self->{format_minor} == 0 and $type == PMAT_SVxMAGIC ) {
            # legacy magic support
            my ( $sv_addr, $obj ) = $self->_read_ptrs(2);
            my $type              = chr $self->_read_u8;

            my $sv = $self->sv_at( $sv_addr );

            # Legacy format didn't have flags, and didn't distinguish obj from ptr
            # However, the only objs it ever saved were refcounted ones. Lets just
            # pretend all of them are refcounted objects.
            $sv->more_magic( $type => 0x01, $obj, 0, 0 );
         }
         elsif( !$sizes ) {
            die sprintf "Unrecognised SV extension type %02x\n", $type;
         }
         else {
            my $sv_addr = $self->_read_ptr;
            my @args = $self->_read_bytesptrsstrs( @$sizes );

            my $sv = $self->sv_at( $sv_addr ) or
               warn( sprintf "Skipping SVx 0x%02X on missing SV at addr 0x%X\n", $type, $sv_addr ), next;

            my $code = $self->can( sprintf "_read_svx_%02X", $type ) or
               warn( sprintf "Skipping unrecognised SVx 0x%02X\n", $type ), next;

            $self->$code( $sv, @args );
         }

         next;
      }

      # First read the "common" header
      my $sv = Devel::MAT::SV->new( $type, $self,
         $self->_read_bytesptrsstrs( @{ $self->{sv_sizes}[0] } )
      );

      if( $type == 0x7F ) {
         my $structtype = $self->structtype( $sv->structid );
         $sv->load( $structtype->fields );
      }
      else {
         # Values 16=OBJECT and 17=CLASS should warn.
         # Technically a padname with the field CODEx extension on it should
         # also warn but in practice we shouldn't see one of those outside of
         # a class that would have warned first anyway.
         $type >= 16 and !$self->{warned_experimental_class}++ and
            warnings::warnif experimental => "Support for class features in PMAT file is experimental";

         my ( $bytes, $nptrs, $nstrs ) = @{ $self->{sv_sizes}[$type] };
         $sv->load(
            $self->_read_bytesptrsstrs( $bytes, $nptrs, $nstrs )
         );
      }

      return $sv;
   }
}

sub _read_svx_80
{
   my $self = shift;
   my ( $sv, $bytes, $ptrs, $strs ) = @_;

   my ( $type, $flags ) = unpack "A1 C", $bytes;

   $sv->more_magic( $type => $flags, @$ptrs );
}

sub _read_svx_81
{
   my $self = shift;
   my ( $sv, $bytes, $ptrs, $strs ) = @_;

   $sv->_more_saved( SCALAR => $ptrs->[0] );
}

sub _read_svx_82
{
   my $self = shift;
   my ( $sv, $bytes, $ptrs, $strs ) = @_;

   $sv->_more_saved( ARRAY => $ptrs->[0] );
}

sub _read_svx_83
{
   my $self = shift;
   my ( $sv, $bytes, $ptrs, $strs ) = @_;

   $sv->_more_saved( HASH => $ptrs->[0] );
}

sub _read_svx_84
{
   my $self = shift;
   my ( $av, $bytes, $ptrs, $strs ) = @_;

   my $index = unpack $self->{uint_fmt}, $bytes;

   $av->isa( "Devel::MAT::SV::ARRAY" ) and
      $av->_more_saved( $index, $ptrs->[0] );
}

sub _read_svx_85
{
   my $self = shift;
   my ( $hv, $bytes, $ptrs, $strs ) = @_;

   $hv->isa( "Devel::MAT::SV::HASH" ) and
      $hv->_more_saved( $ptrs->[0], $ptrs->[1] );
}

sub _read_svx_86
{
   my $self = shift;
   my ( $sv, $bytes, $ptrs, $strs ) = @_;

   $sv->_more_saved( CODE => $ptrs->[0] );
}

sub _read_svx_87
{
   my $self = shift;
   my ( $sv, $bytes, $ptrs, $strs ) = @_;

   $sv->_more_annotations( $ptrs->[0], $strs->[0] );
}

sub _read_svx_88
{
   my $self = shift;
   my ( $sv, $bytes, $ptrs, $strs ) = @_;

   my ( $serial, $line ) = unpack "($self->{uint_fmt})2", $bytes;
   my $file = $strs->[0];

   $sv->_debugdata( $serial, $line, $file );
}

sub _read_svx_89
{
   my $self = shift;
   my ( $sv, $bytes, $ptrs, $strs ) = @_;

   my ( $shared_hek ) = unpack "$self->{ptr_fmt}", $bytes;

   if( $sv->type eq "SCALAR" ) {
      $sv->_set_shared_hek_at( $shared_hek );
   }
   else {
      warn sprintf "Ignoring SVxSHARED_HEK on non-SCALAR SV addr=%#x\n", $sv->addr;
   }
}

sub _read_ctx
{
   my $self = shift;

   my $type = $self->_read_u8;
   return if !$type;

   if( $self->{format_minor} >= 2 ) {
      my $ctx = Devel::MAT::Context->new( $type, $self,
         $self->_read_bytesptrsstrs( @{ $self->{ctx_sizes}[0] } )
      );

      $ctx->load(
         $self->_read_bytesptrsstrs( @{ $self->{ctx_sizes}[$type] } )
      );

      return $ctx;
   }
   else {
      return Devel::MAT::Context->load_v0_1( $type, $self );
   }
}

=head1 METHODS

=cut

=head2 perlversion

   $version = $df->perlversion;

Returns the version of perl that the heap dump file was created by, as a
string in the form C<5.14.2>.

=cut

sub perlversion
{
   my $self = shift;
   my $v = $self->{perlver};
   return join ".", $v>>24, ($v>>16) & 0xff, $v&0xffff;
}

=head2 endian

   $endian = $df->endian;

Returns the endian direction of the perl that the heap dump was created by, as
either C<big> or C<little>.

=cut

sub endian
{
   my $self = shift;
   return $self->{big_endian} ? "big" : "little";
}

=head2 uint_len

   $len = $df->uint_len;

Returns the length in bytes of a uint field of the perl that the heap dump was
created by.

=cut

sub uint_len
{
   my $self = shift;
   return $self->{uint_len};
}

=head2 ptr_len

   $len = $df->ptr_len;

Returns the length in bytes of a pointer field of the perl that the heap dump
was created by.

=cut

sub ptr_len
{
   my $self = shift;
   return $self->{ptr_len};
}

=head2 nv_len

   $len = $df->nv_len;

Returns the length in bytes of a double field of the perl that the heap dump
was created by.

=cut

sub nv_len
{
   my $self = shift;
   return $self->{nv_len};
}

=head2 ithreads

   $ithreads = $df->ithreads;

Returns a boolean indicating whether ithread support was enabled in the perl
that the heap dump was created by.

=cut

sub ithreads
{
   my $self = shift;
   return $self->{ithreads};
}

=head2 roots

   %roots = $df->roots;

Returns a key/value pair list giving the names and SVs at each of the roots.

=head2 roots_strong

   %roots = $df->roots_strong;

Returns a key/value pair list giving the names and SVs at each of the roots
that count as strong references.

=head2 roots_weak

   %roots = $df->roots_weak;

Returns a key/value pair list giving the names and SVs at each of the roots
that count as strong references.

=cut

sub _roots
{
   my $self = shift;
   return map {
      my ( $root_at, $desc ) = @$_;
      $desc => $self->sv_at( $root_at )
   } values %{ $self->{roots} };
}

sub roots
{
   my $self = shift;
   return pairmap { substr( $a, 1 ) => $b } $self->_roots;
}

sub roots_strong
{
   my $self = shift;
   return pairmap { $a =~ m/^\+(.*)/ ? ( $1 => $b ) : () } $self->_roots;
}

sub roots_weak
{
   my $self = shift;
   return pairmap { $a =~ m/^\-(.*)/ ? ( $1 => $b ) : () } $self->_roots;
}

=head2 ROOTS

   $sv = $df->ROOT;

For each of the root names given below, a method exists with that name which
returns the SV at that root:

   main_cv
   defstash
   mainstack
   beginav
   checkav
   unitcheckav
   initav
   endav
   strtabhv
   envgv
   incgv
   statgv
   statname
   tmpsv
   defgv
   argvgv
   argvoutgv
   argvout_stack
   fdpidav
   preambleav
   modglobalhv
   regex_padav
   sortstash
   firstgv
   secondgv
   debstash
   stashcache
   isarev
   registered_mros

=cut

=head2 root_descriptions

   %rootdescs = $df->root_descriptions;

Returns a key/value pair list giving the (method) name and description text of
each of the possible roots.

=cut

sub root_descriptions
{
   my $self = shift;
   my $roots = $self->{roots};
   return map {
      $_ => substr $roots->{$_}[1], 1
   } keys %$roots;
}

=head2 root_at

   $addr = $df->root_at( $name );

Returns the SV address of the given named root.

=cut

sub root_at
{
   my $self = shift;
   my ( $name ) = @_;

   return $self->{roots}{$name} ? $self->{roots}{$name}[0] : undef;
}

=head2 root

   $sv = $df->root( $name );

Returns the given root SV.

=cut

sub root
{
   my $self = shift;
   my $root_at = $self->root_at( @_ ) or return;
   return $self->sv_at( $root_at );
}

=head2 heap

   @svs = $df->heap;

Returns all of the heap-allocated SVs, in no particular order

=cut

sub heap
{
   my $self = shift;
   return values %{ $self->{heap} };
}

=head2 stack

   @svs = $df->stack;

Returns all the SVs on the stack

=cut

sub stack
{
   my $self = shift;

   return map { $self->sv_at( $_ ) } @{ $self->{stack_at} };
}

=head2 contexts

   @ctxs = $df->contexts;

Returns a list of L<Devel::MAT::Context> objects representing the call context
stack in the dumpfile.

=cut

sub contexts
{
   my $self = shift;
   return @{ $self->{contexts} };
}

=head2 sv_at

   $sv = $df->sv_at( $addr );

Returns the SV at the given address, or C<undef> if one does not exist.

(Note that this is unambiguous, as a Perl-level C<undef> is represented by the
immortal C<Devel::MAT::SV::UNDEF> SV).

=cut

sub sv_at
{
   my $self = shift;
   my ( $addr ) = @_;
   return undef if !$addr;

   return $self->{UNDEF} if $addr == $self->{undef_at};
   return $self->{YES}   if $addr == $self->{yes_at};
   return $self->{NO}    if $addr == $self->{no_at};

   return $self->{heap}{$addr};
}

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>

=cut

0x55AA;
