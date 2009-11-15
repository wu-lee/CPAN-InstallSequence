use strict;
use warnings;
use Module::Build;

{ # define a handy rscan_dir function
    my $manifest_skip = qr/(?!)/; # this regex always fails 
    if (open my $fh, '<', 'MANIFEST.SKIP')
    {
        # map /.*/ chomps newlines, since . doesn't match EOLs
        $manifest_skip = join '|', map /(.*)/, <$fh>;
        close $fh;
        $manifest_skip = qr/$manifest_skip/;
    }

    sub rscan_dir
    {
        grep !/$manifest_skip/, @{ Module::Build->rscan_dir(@_) };
    }
}

my $builder = Module::Build->new
    (module_name         => 'CPAN::InstallSequence',
     license             => 'artistic',
     dist_author         => 'Nick Woolley <npw@cpan.org>',
     dist_version_from   => 'lib/CPAN/InstallSequence.pm',
     dist_abstract       => 'Given a module name, generates an ordered list of prerequisites to install',
     create_readme       => 1,
     create_makefile_pl  => 'traditional',
     build_requires => 
     {
         'Module::Build' => 0.28,
     },
     requires => 
     {
      'Test::More' => 0,
      'File::Temp' => 0, 
      'version'    => 0.74,
      'CPANPLUS::Backend' => 0,
      'File::Spec' => 0,
      'LWP' => 0,
      'YAML::Tiny' => 0,
     },
     recommends => 
     {
         'Test::Pod::Coverage' => 1.04,
         'Test::Pod' => 1.14,
         'Perl::Critic' => 0,
         'File::HomeDir' => 0,
     },
     test_files         => [ rscan_dir('t', '\.t$') ],
     add_to_cleanup      => [ 'CPAN-InstallSequence-*' ],
    );

$builder->create_build_script();
