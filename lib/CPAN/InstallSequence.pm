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
#    my $consumers = shift;

    my $meta_yml_path = $self->_get_meta($module_name);

    if (!$meta_yml_path) { # something failed
        _trace "# CPANPLUS->fetch($module_name)\n"; # DEBUG

        my $cpan = $self->{cpan_backend};
        my $module = $cpan->module_tree($module_name);        
        if ($module->fetch && $module->extract) {
            my $prereqs = $module->prereqs
                if $module->can('prereqs'); # CPAN::Module::Fake can't.
            return %{ $prereqs || {} }
        }
        
#        my $version = $module->package_version;
        _trace(" failed to get any version of $module_name, skipping it\n");
#               " consumers of $name-$version are: @$consumers\n");
        return;
    }

    my $data = YAML::Tiny::LoadFile($meta_yml_path);
        
    my @prereqs = map { %{ $data->{$_} || {} } }
        qw(configure_requires build_requires requires recommends);
    my $version = $data->{version} || 0;

    return $version, @prereqs;
}

# sub _is_uptodate {
#     my $self = shift;

#     my $module = shift;
#     my $versions = shift;

#     my $distro_name = $module->package_name;
#     my $distro_version = $versions->{$distro_name};
#     my $norm_version = $distro_version->normal;
    
#     # parse the distro name
#     $module = $cpan->parse_module(module => $distro_name);

    
#     my $inst_version = $module->installed_version?
#         version->new($module->installed_version)->normal :
#             "none";
    
#     _trace "Checking $distro_name-$norm_version...\n";
    
#     # skip this module if it is installed already
#     #        my %options = (version => $raw_module_version)
#     #            if $raw_module_version;
#     my $uptodate = $module->is_uptodate;
#     _trace $uptodate?
#         " require $distro_name $norm_version, as we have $inst_version\n" :
#             " $distro_name is up to date (required: $norm_version; we have $inst_version)\n" ;
    
#     return $uptodate;
# }


sub finddeps_old {
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


    my @modules = ($module_name, $version);


    # First, deduce the install order and required versions
    # for all the dependencies of $module_name-$version:
    my @distros;
    my %versions;
    my %consumers;
    while(@modules) {
        my $module_name = shift @modules;
        my $raw_module_version = shift @modules;

        # Don't try and install or analyse Perl or its dependencies.
        next if $module_name eq 'perl';

        # Construct a hypothetical distname with version, for parse_module...
        (my $distname = $module_name) =~ s/::/-/g;
        my $distname_version = $raw_module_version?
            "$distname-$raw_module_version" : $distname;

        # And so find the actual package this module belongs to
        my $module = $cpan->parse_module(module => $distname_version);
        if (!$module) {
            _trace "$distname_version: can't parse module name, skipping it\n";
            next;
        }

        my $distro_name = $module->package_name;

        # Again: don't tackle Perl.
        next if $distro_name eq 'perl';


        my $distro_version = version->new($module->package_version);
        $distname_version = "$distro_name-$distro_version";


        # Now worry about whether the required version is installed or not.

        if (defined $versions{$distro_name}) { 
            # We've seen this distro required before; if we saw a
            # newer version required we need do nothing more.
            next 
                if $distro_version <= $versions{$distro_name};

            # Otherwise, bump the version required...
            _trace("$distname_version:\n bumped minimum version from $versions{$distro_name}\n");
            $versions{$distro_name} = $distro_version;

            # Is this version or a newer one installed?  If so, we
            # need do nothing more.
            if ($module->is_uptodate(version => $distro_version)) {
                _trace " already up to date\n";
                next;
            }

            # Otherwise, continue on to get the prereqs for this
            # module
        }
        else {
            # This is a new distro, so it needs to be added to the
            # @distro list and processed.
            _trace "$distname_version:\n";                
            $versions{$distro_name} = $distro_version;
            
            # Is this version or a newer one installed?  If so, we
            # need do nothing more.
            if ($module->is_uptodate(version => $distro_version)) {
                _trace " already up to date\n";
                next;
            }

            # Otherwise, add it to the install list, and continue on
            # to get the prereqs for this module.
            _trace " adding to install list\n";

            unshift @distros, $distro_name;
        }

        # If we get here, we need to install or upgrade the module.
        # And if we need to do that, we way as well use the latest
        # version.  This also avoids needing to resolve requirements
        # for non-existing versions (as sometimes crop up).

        _trace " finding prerequisites\n";

        # Get the prerequisites, and put them at the head of the list
        # to check, so we make a depth-first traversal of the
        # dependency tree.  This is necessary to ensure dependencies
        # between modules in the same prereqs list get honoured.
#        my $consumer_list = $consumers{$distname_version} ||= [];
        my ($latest_version, %prereqs) = $self->_get_prereqs($distro_name);
        _trace join "", map "   $_-$prereqs{$_}\n", sort keys %prereqs; # DEBUG

        # The module's version may have been updated now, so update $distname_version
        # and $version{$distname}
        $latest_version = version->new($latest_version);
        $distname_version = "$distro_name-$latest_version"; 
        $versions{$distro_name} = $latest_version;

        # record this distro's consumption
#        foreach my $prereq (map "$_-$prereqs{$_}", keys %prereqs) {
#            $prereq =~ s/::/-/g;
#            my $consumer_list = $consumers{$prereq} ||= [];
#            push @$consumer_list, $distname_version;
#            _trace "# consumers are $prereq: @$consumer_list\n"; # DEBUG
#        }

        unshift @modules, %prereqs;
    }

    return map "$_-$versions{$_}", @distros;
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


    # First, deduce the install order and required versions
    # for all the dependencies of $module_name-$version:
#    my @distros;
#    while(@modules) {
#        my $module_name = shift @modules;
#        my $module_version = shift @modules;#

#    }

#    return map "$_-$versions{$_}", @distros;
    return @modules;
}




1;
