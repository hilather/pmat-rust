use v5.14;
use warnings;

use Module::Build;
use File::Spec;
use Cwd qw( abs_path );

my $root = abs_path('.');
my $rust_dir = File::Spec->catdir( $root, 'rust', 'pmat-core' );
my $rust_target = File::Spec->catdir( $rust_dir, 'target', 'release' );
my $libname = 'pmat_core';
my $have_rust_lib = 0;

my $have_cargo = 0;
{
   my $v = `cargo --version 2>/dev/null`;
   $have_cargo = ( $? == 0 && $v =~ /cargo/ );
}

if ( $have_cargo && -d $rust_dir ) {
   print "Building Rust pmat-core (release)...\n";
   my $cmd = "cargo build --release --manifest-path "
      . quotemeta( File::Spec->catfile( $rust_dir, 'Cargo.toml' ) );
   system($cmd) == 0 or die "cargo build failed\n";
}

if ( -e File::Spec->catfile( $rust_target, "lib${libname}.so" )
  || -e File::Spec->catfile( $rust_target, "lib${libname}.a" ) )
{
   $have_rust_lib = 1;
}
else {
   warn "pmat-core library not found; Rust backend disabled\n";
}

# Subclass so only Core.xs links libpmat_core (avoid dual-load of Rust runtime).
my $class = Module::Build->subclass(
   class => 'Module::Build::DevelMAT',
   code  => q{
      sub link_c {
         my ($self, $spec) = @_;
         my $file = $spec->{module_name} // '';
         my @save = @{ $self->extra_linker_flags // [] };
         if ( $file =~ /Core/ && $self->notes('pmat_core_link') ) {
            $self->extra_linker_flags( @{ $self->notes('pmat_core_link') } );
         }
         else {
            # MAT.xs must not link pmat_core
            $self->extra_linker_flags();
         }
         my $ret = $self->SUPER::link_c($spec);
         $self->extra_linker_flags(@save);
         return $ret;
      }
   },
);

# Packaging may redirect link/search path and runtime rpath:
#   PMAT_CORE_LIBDIR  — where to find libpmat_core at link time (default: cargo target)
#   PMAT_CORE_RPATH   — DT_RUNPATH embedded in Core.so (default: same as LIBDIR)
# For system RPMs set both to e.g. /usr/lib64 so Core.so finds the packaged .so.
my $core_libdir = $ENV{PMAT_CORE_LIBDIR} // $rust_target;
my $core_rpath  = $ENV{PMAT_CORE_RPATH}  // $core_libdir;

my @core_link = $have_rust_lib ? (
   "-L$core_libdir",
   "-l${libname}",
   "-Wl,-rpath,$core_rpath",
   '-ldl', '-lpthread', '-lm',
) : ();

if ( $have_rust_lib ) {
   print "pmat-core link: -L$core_libdir -l$libname -Wl,-rpath,$core_rpath\n";
}

my $build = $class->new(
   module_name => 'Devel::MAT',
   requires => {
      'perl' => '5.014',
      'Syntax::Keyword::Match' => 0,
      'Commandable::Invocation' => '0.04',
      'Devel::MAT::Dumper' => '0.48',
      'Feature::Compat::Try' => '0',
      'File::ShareDir' => 0,
      'File::Spec' => 0,
      'Heap' => 0,
      'List::Util' => '1.44',
      'List::UtilsBy' => 0,
      'Module::Pluggable' => 0,
      'String::Tagged' => '0.15',
      'String::Tagged::Terminal' => '0.03',
      'Struct::Dumb' => '0.07',
   },
   test_requires => {
      'Test2::V0' => 0,
   },
   configure_requires => {
      'Module::Build' => '0.4004',
   },
   share_dir => {
      module => { "Devel::MAT::UI" => "share" },
   },
   license => 'perl',
   create_license => 1,
   create_readme  => 1,
   extra_compiler_flags => $have_rust_lib
      ? [ "-I" . File::Spec->catdir( $rust_dir, 'include' ) ]
      : [],
   xs_files => {
      'lib/Devel/MAT.xs' => 'lib/Devel/MAT.xs',
      ( $have_rust_lib
         ? ( 'lib/Devel/MAT/Core.xs' => 'lib/Devel/MAT/Core.xs' )
         : () ),
   },
);

$build->notes( pmat_core_link => \@core_link );

if( $build->args( "DEBUG" ) ) {
   $build->extra_compiler_flags( @{ $build->extra_compiler_flags }, "-ggdb" );
}

$build->create_build_script;
