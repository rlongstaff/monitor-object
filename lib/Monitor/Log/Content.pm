package Monitor::Log::Content;

use strict;
use warnings;

use IO::File::Tail;
use Monitor::Object qw{:state};

use base qw{ Monitor::Object };

use Data::Dumper;

sub handler {
    my $self = shift;

    my $fh = IO::File::Tail->new;
    $fh->bookmark_file($self->arg('BookmarkFile'));
    unless ($fh->open($self->arg('LogFile'), '<')) {
        $self->state(UNKNOWN, $fh->error_message());
        $self->exit_state;
    }

    $self->{_tail_fh} = $fh;

    $self->load_config;

    $self->check_log;

    unless ($fh->close) {
        $self->state(UNKNOWN, $fh->error_message());
        $self->exit_state;
    }

    $self->state(OK, "No errors found.");
    $self->exit_state;
}

sub load_config {
    my $self = shift;

    my $fh = IO::File->new;
    unless ($fh->open($self->arg('ConfigFile'), '<')) {
        $self->state(UNKNOWN, "Failed to open " . $self->arg('ConfigFile') . ": $!");
        $self->exit_state;
    }

    my $ordered_rules = [];
    my $rules = {};
    while(my $line = <$fh>) {
        chomp $line;
        next if (length $line == 0);
        next if ($line =~ /^\s*#/);

        my (
            $id,
            $state,
            $min,
            $max,
            $override,
            $regex,
        ) = $self->parse_config_line($line);

        # Things get a little wonky here. We need to preserve the order of the
        # regexes / rules in the config, but we want to make some basic
        # optimizations to reduce the number of attempted pattern matches. To
        # that end we create a hashref to piece together multi-line rules that
        # describe various buckets and an array ref to store the order
        if (!exists $rules->{$id}) {
            # create rule
            my $rule = {
                id       => $id,
                regex    => $regex,
                state    => {
                    $state => {
                        min      => $min,
                        max      => $max,
                        override => $override,
                    },
                },
            };

            # add to cache
            $rules->{$id} = $rule;
            # push onto rules array
            push @$ordered_rules, $rule;
        } else {
            # add bucket
            $rules->{$id}{state}{$state} = {
                min      => $min,
                max      => $max,
                override => $override,
            };

        }
    }

    # verify config
    #   make sure id/regex matches for each rule

    $fh->close;

    $self->{_rules} = $rules;
    $self->{_ordered_rules} = $ordered_rules;

    return 1;
}

sub parse_config_line {
    my $self = shift;
    my ($line) = @_;

    my (
        $id,
        $state,
        $min,
        $max,
        $override,
        $regex,
    ) = split(/,/, $line, 6);

    if (length $state == 0) {
        $self->state(UNKNOWN,
            "No state specified; " .
            $self->arg('ConfigFile') .  ", line $."
        );
        $self->exit_state;
    }

    if (!exists $self->STATE->{$state}) {
        $self->state(UNKNOWN,
            "Invalid state specified '$state'; " .
            $self->arg('ConfigFile') .  ", line $."
        );
        $self->exit_state;
    }

    unless (length $min > 0) {
        $min = 0;
    }

    unless (length $max > 0) {
        $max = undef;
    }

    unless (length $override > 0) {
        $override = 0;
    }

    unless (length $regex > 0) {
        $self->state(UNKNOWN, 
            "No regular expression found; " .
            $self->arg('ConfigFile') .  ", line $."
        );
        $self->exit_state;
    }

    $regex = qr{$regex};

    return (
        $id,
        $state,
        $min,
        $max,
        $override,
        $regex,
    );
}

sub check_log {
    my $self = shift;

    # get counts and build summary
    # cycle through rules from worst to best exception states
    #   appending ID + hit count as we go

    my %count = ();
    my $fh = $self->{_tail_fh};
    while (my $line = <$fh>) {
        chomp $line;
        foreach my $rule (@{$self->{_ordered_rules}}) {
            my $regex = $rule->{regex};
            if ( $line =~ m/$regex/ ) {
                $count{$rule->{id}}++;
                last;
            }
        }
    }

    my @state_order = sort { 
        $self->STATE_PRIORITY->{$b} <=> $self->STATE_PRIORITY->{$a} 
    } keys %{$self->STATE_PRIORITY};

    foreach my $id (keys %count) {
        my $rule = $self->{_rules}{$id};
        foreach my $state (@state_order) {
            next unless (exists $rule->{state}{$state});

            # We have a hit on this rule and we have a state defined
            #   Now check to see if we're in a bucket
            next if ($count{$id} < $rule->{state}{$state}{min});
            next if (
                    defined $rule->{state}{$state}{max} &&
                    $count{$id} > $rule->{state}{$state}{max}
            );

            my $msg = "'$id' matched " .  $count{$id} . " times";
            $self->add_state($state, $msg);
        }
    }
}

1;

