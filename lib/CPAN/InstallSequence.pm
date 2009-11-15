package CPAN::InstallSequence;
use strict;
use warnings;

use version; our $VERSION = qv('0.1');

use CPANPLUS::Backend;
use File::Path ();
use File::Temp;
use LWP::Simple ();
use YAML::Tiny;
use Carp;

sub _trace { printf @_ }


# Gets a META.yml file for the module with $name and $version.
# Returns a path to the downloaded file, or the empty list.
sub _get_meta {
    my $self = shift;
    my ($name, $version) = @_;
    my $name_version = $version? 
        "$name-$version" : $name;

    my $cache_dir = $self->{cache_dir};
    my $dir = "$cache_dir/$name_version";
    File::Path::mkpath $dir;

    my $meta_yml_path = "$dir/META.yml";

    # See http://use.perl.org/articles/07/12/27/1813223.shtml
    my $meta_yml_url = "http://search.cpan.org/meta/$name_version/META.yml";
    my $rc = LWP::Simple::getstore($meta_yml_url, $meta_yml_path);
    _trace "# $meta_yml_url => $rc\n"; # DEBUG
    return $meta_yml_path if $rc == 200;
    return;
}

# This (attempts to) find all the prerequisites for the latest version
# of the module given, and returns them in installation order.  If
# successful, it returns the latest version, and the prerequisites (a
# list of module name / version pairs).  Otherwise it returns the empty list.
sub _get_prereqs {
    my $self = shift;

    my $module_name = shift;

    my $meta_yml_path = $self->_get_meta($module_name);

    if (!$meta_yml_path) { # something failed
        _trace "# CPANPLUS->fetch($module_name)\n"; # DEBUG

        my $cpan = $self->{cpan_backend};
        my $module = $cpan->module_tree($module_name);        
        if ($module->fetch && $module->extract) {
            my $prereqs;
            $prereqs = $module->prereqs
                if $module->can('prereqs'); # CPAN::Module::Fake can't.
            return %{ $prereqs || {} }
        }
        
        _trace(" failed to get any version of $module_name, skipping it\n");
        return;
    }

    my $data = YAML::Tiny::LoadFile($meta_yml_path);
        
    my @prereqs = map { %{ $data->{$_} || {} } }
        qw(configure_requires build_requires requires recommends);
    my $version = $data->{version} || 0;

    return $version, @prereqs;
}




sub _traverse_modules {
    my $self = shift;
    my $process = shift;
    my $module =  shift;

    my $cpan = $self->{cpan_backend};

    # This hash will record suggested min versions (although if a
    # module is not installed yet, this will default to the latest
    # version, as this avoids having to identify the lowest available
    # version, and we assume the latest is best and costs the same as
    # older versions to install).
    my %versions; 

    my $traverse_modules;
    my $traverse_prereqs = sub {
        my $parent_module = shift;

        my $module_name = $parent_module->{name};

        _trace " finding latest version and its prerequisites\n";

        # If we get here, we need to install or upgrade the module.
        # And if we need to do that, we way as well use the latest
        # version.  As mentioned above, this also avoids needing to
        # resolve requirements for non-existing versions (as sometimes
        # crop up).

        # Get the latest version of this module, and its prerequisites
        my ($latest_version, %prereqs) = $self->_get_prereqs($module_name);
        _trace(join "", 
               "   latest is $latest_version\n", 
               map "   $_-$prereqs{$_}\n", sort keys %prereqs); # DEBUG

        # The module's version may have been updated now, so update
        # $versions{$module_name}
        $versions{$module_name} = version->new($latest_version);

        $traverse_modules->({name => $_,
                             version => $prereqs{$_}})
            foreach keys %prereqs;

        return;
    };
    
    $traverse_modules = sub {
        my $parent_module = shift;

        my $module_name = $parent_module->{name};
        my $module_version = $parent_module->{version};
        my $module_author = $parent_module->{author};

        Carp::confess "module has no name"
                unless defined $module_name;
        Carp::confess "module $module_name has no version"
                unless defined $module_version;

        # Don't try and install or analyse Perl or its dependencies.
        return
            if $module_name eq 'perl';

        # Correct module name and version to the name and version the
        # distribution, if different
        my $cpan_module;
        {
            # Construct a hypothetical distname with version, for parse_module...
            $module_name =~ s/::/-/g;
            my $modname_version = $module_version?
                "$module_name-$module_version" : $module_name;
            
            # And so find the actual package this module belongs to
            $cpan_module = $cpan->parse_module(module => $modname_version);
            if (!$cpan_module) {
                _trace "$modname_version: can't parse module name, skipping it\n";
                return;
            }
            
            $module_name = $cpan_module->package_name;
            $module_version = version->new($cpan_module->package_version);
            $module_author = $cpan_module->author->cpanid;
        }

        # Again: don't tackle Perl.
        return 
            if $module_name eq 'perl';
        

        my $distname_version = "$module_name-$module_version";


        # Now worry about whether the required version is installed or not.

        if (defined $versions{$module_name}) { 
            # We've seen this distro required before; if we saw a
            # newer version required we need do nothing more.
            return
                if $module_version <= $versions{$module_name};

            # Otherwise, bump the version required...
            _trace("$distname_version:\n bumped minimum version from $versions{$module_name}\n");
            $versions{$module_name} = $module_version;

            # Is this version or a newer one installed?  If so, we
            # need do nothing more.
            if ($cpan_module->is_uptodate(version => $module_version)) {
                _trace " already up to date\n";
                return;
            }

            # Otherwise, continue on to get the prereqs for this
            # module
        }
        else {
            # This is a new distro, so it needs to be processed.
            _trace "$distname_version:\n";                
            $versions{$module_name} = $module_version;
            
            # Is this version or a newer one installed?  If so, we
            # need do nothing more.
            if ($cpan_module->is_uptodate(version => $module_version)) {
                _trace " already up to date\n";
                return;
            }

            # Otherwise, continue on to get the prereqs for this
            # module.
            my $installed_version = $cpan_module->installed_version;
            
            _trace $installed_version?
                " older version $installed_version installed\n" :
                " not yet installed\n";
        }

        my $updated_parent_module = {name => $module_name,
                                     version => $module_version,
                                     author => $cpan_module->author->cpanid,
                                     module => $cpan_module};

        $traverse_prereqs->($updated_parent_module);

        $process->($self, $updated_parent_module);
    };
    

    $traverse_modules->($module);
}



sub finddeps {
    my $module_name = shift 
        or Carp::croak "You must supply a module name";
    Carp::croak "Uneven number of options"
        if @_ % 2;
    my %options = @_;

    my $version = $options{module_version} ||= 0;

    my $cache_dir = $options{cache_dir} ||= File::Temp::tempdir( CLEANUP => 1);
    File::Path::mkpath $cache_dir;

    my $cpan = $options{cpan_backend} ||= CPANPLUS::Backend->new;

    my $self = bless \%options, __PACKAGE__;


    my @modules;
    
    
    $self->_traverse_modules(
        sub {
            my ($self, $module) = @_;
            push @modules, $module;
        },
        {name => $module_name,
         version => $version},
    );


    return @modules;
}




1;
__END__

=head1 NAME

CPAN::InstallSequence - Given a module name, generates an ordered list of prerequisites to install


=head1 SYNOPSIS

    use CPAN::InstallSequence;

    # Get a list of CPAN distribution names required to install
    # Some::Module on this system, in the order they need to be
    # installed to respect their prerequisites. Any prerequisites
    # which are already installed at the minimum required version or
    # better will not be listed.
    my @deps = CPAN::InstallSequence::finddeps(
        'Some::Module',
        %options
    );

    # The elements returned are simple hashrefs, with author,
    # distribution name, and the minimim version required
    # (which in the case of uninstalled modules, will be the most
    # recent version on CPAN).
    printf "%s-%s-%s\n", @$_{'author','name','version'}
        for @deps;

  
=head1 DESCRIPTION

This documentation is unfinished.

=for author to fill in:
    Write a full description of the module and its features here.
    Use subsections (=head2, =head3) as appropriate.


=head1 INTERFACE 

=for author to fill in:
    Write a separate section listing the public components of the modules
    interface. These normally consist of either subroutines that may be
    exported, or methods that may be called on objects belonging to the
    classes provided by the module.


=head1 DIAGNOSTICS

=for author to fill in:
    List every single error and warning message that the module can
    generate (even the ones that will "never happen"), with a full
    explanation of each problem, one or more likely causes, and any
    suggested remedies.

=over

=item C<< Error message here, perhaps with %s placeholders >>

[Description of error here]

=item C<< Another error message here >>

[Description of error here]

[Et cetera, et cetera]

=back


=head1 CONFIGURATION AND ENVIRONMENT

=for author to fill in:
    A full explanation of any configuration system(s) used by the
    module, including the names and locations of any configuration
    files, and the meaning of any environment variables or properties
    that can be set. These descriptions must also include details of any
    configuration language used.
  
CPAN::InstallSequence requires no configuration files or environment variables.


=head1 DEPENDENCIES

=for author to fill in:
    A list of all the other modules that this module relies upon,
    including any restrictions on versions, and an indication whether
    the module is part of the standard Perl distribution, part of the
    module's distribution, or must be installed separately. ]

None.


=head1 INCOMPATIBILITIES

=for author to fill in:
    A list of any modules that this module cannot be used in conjunction
    with. This may be due to name conflicts in the interface, or
    competition for system or program resources, or due to internal
    limitations of Perl (for example, many modules that use source code
    filters are mutually incompatible).

None reported.


=head1 BUGS AND LIMITATIONS

=for author to fill in:
    A list of known problems with the module, together with some
    indication Whether they are likely to be fixed in an upcoming
    release. Also a list of restrictions on the features the module
    does provide: data types that cannot be handled, performance issues
    and the circumstances in which they may arise, practical
    limitations on the size of data sets, special cases that are not
    (yet) handled, etc.

No bugs have been reported.

Please report any bugs or feature requests to
C<bug-CPAN-InstallSequence@rt.cpan.org>, or through the web interface at
L<http://rt.cpan.org>.


=head1 AUTHOR

Nick Woolley  C<< <npw@cpan.org> >>


=head1 LICENCE AND COPYRIGHT

Copyright (c) 2009, Nick Woolley C<< <npw@cpan.org> >>. All rights reserved.

This module is free software; you can redistribute it and/or
modify it under the same terms as Perl itself. See L<perlartistic>.


=head1 DISCLAIMER OF WARRANTY

BECAUSE THIS SOFTWARE IS LICENSED FREE OF CHARGE, THERE IS NO WARRANTY
FOR THE SOFTWARE, TO THE EXTENT PERMITTED BY APPLICABLE LAW. EXCEPT WHEN
OTHERWISE STATED IN WRITING THE COPYRIGHT HOLDERS AND/OR OTHER PARTIES
PROVIDE THE SOFTWARE "AS IS" WITHOUT WARRANTY OF ANY KIND, EITHER
EXPRESSED OR IMPLIED, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE. THE
ENTIRE RISK AS TO THE QUALITY AND PERFORMANCE OF THE SOFTWARE IS WITH
YOU. SHOULD THE SOFTWARE PROVE DEFECTIVE, YOU ASSUME THE COST OF ALL
NECESSARY SERVICING, REPAIR, OR CORRECTION.

IN NO EVENT UNLESS REQUIRED BY APPLICABLE LAW OR AGREED TO IN WRITING
WILL ANY COPYRIGHT HOLDER, OR ANY OTHER PARTY WHO MAY MODIFY AND/OR
REDISTRIBUTE THE SOFTWARE AS PERMITTED BY THE ABOVE LICENCE, BE
LIABLE TO YOU FOR DAMAGES, INCLUDING ANY GENERAL, SPECIAL, INCIDENTAL,
OR CONSEQUENTIAL DAMAGES ARISING OUT OF THE USE OR INABILITY TO USE
THE SOFTWARE (INCLUDING BUT NOT LIMITED TO LOSS OF DATA OR DATA BEING
RENDERED INACCURATE OR LOSSES SUSTAINED BY YOU OR THIRD PARTIES OR A
FAILURE OF THE SOFTWARE TO OPERATE WITH ANY OTHER SOFTWARE), EVEN IF
SUCH HOLDER OR OTHER PARTY HAS BEEN ADVISED OF THE POSSIBILITY OF
SUCH DAMAGES.
