package CPAN::FindDependencies::InstallSequence;
use strict;
use warnings;
use CPAN::FindDependencies;


sub _trace { printf @_ }

# Accepts arguments as for CPAN::FindDependencies::finddeps, and
# returns a similar dependency list, but in the order they should be
# installed.
sub finddeps {
    my @deps = CPAN::FindDependencies::finddeps(@_);
    
    _trace "Deducing installation order...\n";
    
    # This array will be populated with hashref elements
    # with the same keys as the first (which represents $dep[0])
    my @index = ({last_seen_child => undef, 
                  prev_sibling => undef,
                  parent => undef});
    
    # This is the last dependency's depth 
    my $last_depth = $deps[0]->depth;
    
    # This records the indexes of the last dependencies seen at any given
    # depth
    my @last_seen = ($last_depth); 
    
    # We can skip the first element because it was populated above.
    foreach my $dep (@deps[1..$#deps]) {
        my $name = $dep->name;
        my $depth = $dep->depth;
        
        my $elem = {last_seen_child => undef,
                    prev_sibling => undef,
                    parent => undef};
        
        if ($depth > $last_depth) {
            # We are a child of the last elem

            # Sanity check
            _trace("$name has depth $depth, which has increased ".
                   "more than one unit from $last_depth!  ".
                   "Possibly something is wrong.")
                if $depth > $last_depth+1;
            
            # Our parent's index should have been recorded here
            my $parent_ix = $last_seen[$last_depth];
            
            # Update our parent's last_seen_child index to point to us
            $index[$parent_ix]->{last_seen_child} = @index;
            
            # Update our parent index too
            $elem->{parent} = $parent_ix;
            
            #        # Truncate @last_seen
            #        $#last_seen = $depth+1;
        }
        else {
            # Our parent's index should have been recorded here
            my $parent_ix = $last_seen[$depth-1];
            
            # We are a sibling of the last elem at the same depth
            my $sibling_ix = $last_seen[$depth];
            
            # Record our previous sibling's index and our parent index
            $elem->{prev_sibling} = $sibling_ix;
            $elem->{parent} = $parent_ix;
            
            # And our parent's last_seen_child index
            $index[$parent_ix]->{last_seen_child} = @index;
        };
        
        $last_seen[$depth] = @index;
        push @index, $elem;
        
        $last_depth = $depth;
    }
    
    # Now, we can construct a leftwards, depth-first traveral of the
    # dependecy tree:
    
    my @install_seq;
    
    
    my $traverse;
    $traverse = sub {
        my $ix = shift;
        return unless defined $ix;
        
        unshift @install_seq, $deps[$ix];
        
        my $elem = delete $index[$ix];
        
        # Traverse the tree down to the leftmost child, or if no children,
        # to the previous sibling.  Or if neither is present, stop
        # recursing.
        $traverse->($elem->{last_seen_child});
        $traverse->($elem->{prev_sibling});
    };



    # DEBUG
    # use List::Util qw(max);
    # my $dump_index = sub {
        
    #     my $max = max map length $_->name, @deps;
    #     my $index = 0;
    #     _trace "% ${max}s  % ${max}s  % ${max}s\n", 
    #         qw(name last_seen_child prev_sibling);
        
    #     for my $elem (@index) {
    #         my @names = map {
    #             defined $_?
    #                 $deps[$_]->name :
    #                     "<?>";
    #         } $index++, @$elem{qw(last_seen_child prev_sibling)};
        
    #         _trace "% ${max}s  % ${max}s  % ${max}s\n", 
    #         @names;
    #     }
    # };
        
    # #dump_index;

    $traverse->(0);
    
#    _trace $_->distribution. "\n"
#        foreach @install_seq; # DEBUG

    return @install_seq;
}


1;
