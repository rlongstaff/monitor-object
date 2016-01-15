package Monitor::Object;

use warnings;
use strict;

use Exporter;
use base qw{Exporter};

use Symbol qw{qualify_to_ref};

use Data::Dumper;

use constant {
    OK       => 0,
    WARNING  => 1,
    CRITICAL => 2,
    UNKNOWN  => 3,
};

our @EXPORT_OK = qw(OK WARNING CRITICAL UNKNOWN);
our %EXPORT_TAGS = (
    state => [qw(OK WARNING CRITICAL UNKNOWN)],
);

our $TIMEOUT       = 40; # Default timeout for run(), in seconds;
our $MAX_MSG_LEN   = 1024; # Nagios default max message length
our $MSG_STATE_SEP = ': '; # String to concat between state and message
our $EXIT          = 1; # Flag for whether or not to call CORE::exit
                        #  Useful for testing / debugging or if we're part of
                        #  a larger framework that doesn't exit the process at
                        #  the end of a run

sub new {
    my $proto = shift;
    my $class = ref($proto) || $proto;

    my $self = bless({}, $class);

    $self->{_state}   = undef;
    $self->{_msg}     = undef;
    $self->{_timeout} = $TIMEOUT;

    return $self->_init(@_);
}

sub _init {
    my $self = shift;
    my %args = @_;

    $self->{_args} = \%args;

    if(exists $self->{_args}{Timeout}) {
        $self->timeout($self->{_args}{Timeout});
    }

    return $self;
}

#TODO arg handling 100% experimental and WILL change in the very near future
sub args {
    my $self = shift;

    return %{$self->{_args}};
}

sub arg {
    my $self = shift;
    my ($name, $val) = @_;

    return
        unless defined $name;

    my $oldval = $self->{_args}{$name};
    if (scalar @_ > 1) {
        $self->{_args}{$name} = $val;
    }

    return $oldval;
}

sub STATE {
    return {
        OK       => 0,
        WARNING  => 1,
        CRITICAL => 2,
        UNKNOWN  => 3,
    };
}

sub STATE_CODE {
    return { reverse %{STATE()} };
}

sub STATE_PRIORITY {
    return {
        OK       => 0,
        UNKNOWN  => 1,
        WARNING  => 2,
        CRITICAL => 3,
    };
}

sub STATE_CODE_PRIORITY {
    return {
       map {
            STATE()->{$_} => STATE_PRIORITY()->{$_}
        } keys %{STATE_PRIORITY()}
    };
}

# Given any input, return a valid numeric state code
sub _state_to_code {
    my $self = shift;
    my ($state) = @_;

    $state = UNKNOWN
        unless defined $state;

    $state = uc $state;

    if ($state =~ /^\d+$/) {
        if (!exists STATE_CODE->{$state}) {
            $state = UNKNOWN;
        }
    } else {
        if (!exists STATE->{$state}) {
            $state = UNKNOWN;
        } else {
            $state = STATE->{$state};
        }
    }

    return $state;
}

# Given any input, return a valid text state
sub _state_to_text {
    my $self = shift;
    my ($state) = @_;

    return STATE_CODE->{$self->_state_to_code($state)};
}

sub run {
    my $self = shift;
    my ($cmd, @args) = @_;

    my @ret;
    my $prev_alarm = 0;

    eval {
        local $SIG{ALRM} = sub {
            die "alarm\n";
        };

        $prev_alarm = alarm($self->timeout);
        if (!defined $cmd) {
            #TODO should we force an exit_state here?
            @ret = $self->handler;
        } elsif (ref($cmd) eq 'SUBREF') {
            @ret = &cmd(@args);
        } else {
            @ret = $self->execute_cmd($cmd, @args);
        }
        alarm($prev_alarm);
    };

    alarm($prev_alarm);

    if ($@) {
        if ($@ eq "alarm\n") {
            $self->state(UNKNOWN, "Timeout while executing check");
        } else {
            $self->state(UNKNOWN, "Unknown error encountered in run(): $@");
        }
        return $self->exit_state;
    }

    return @ret;
}

# Abstract method to be implemented by child classes
sub handler {}

sub execute_cmd {
    my $self = shift;
    my ($cmd, @args) = @_;

    #TODO capture STDOUT/STDERR
    #TODO safety wrapping
    system($cmd, @args);
    my $ret = $? >> 8;

    return $ret;
}

sub timeout {
    my $self = shift;
    my ($timeout) = @_;

    if (scalar @_) {
        $self->{_timeout} = $timeout;
    }

    return $self->{_timeout};
}

sub _clear {
    my $self = shift;

    $self->{_state} = undef;
    $self->{_msg}   = undef;

    return 1;
}

sub message {
    my $self = shift;
    my ($msg) = @_;

    return $self->{_msg};
}

# Internal use only; set the message using the state() calls
sub _message {
    my $self = shift;
    my ($msg) = @_;

    return $self->{_msg}
        unless (scalar @_);

    return $self->{_msg}
        unless (defined $msg);

    # Our max length must take into account the length of the state, the
    # separator and 2 chars of passing for newlines / nul (JIC).
    my $effective_max_len =
        $MAX_MSG_LEN - length($self->state) - length($MSG_STATE_SEP) - 2;

    $self->{_msg} = substr($msg, 0, $effective_max_len);

    return $self->{_msg};
}

sub state {
    my $self = shift;
    my ($state, $msg) = @_;

    if (scalar @_ == 0) {
        # A little white lie to hide our internal "undef means not yet set" state
        unless (defined $self->{_state}) {
            return STATE_CODE->{UNKNOWN};
        }
        return STATE_CODE->{$self->{_state}};
    }

    return $self->_state($state, $msg);
}

sub add_state {
    my $self = shift;
    my ($state, $msg) = @_;

    return $self->_state($state, $msg, 1);
}

sub _state {
    my $self = shift;
    my ($state, $msg, $append) = @_;

    if (scalar @_ < 2) {
        $self->{_state} = UNKNOWN;
        $self->_message('Invalid use of Monitor::Object::_state()');
        $self->exit_state;
    }

    # Normalize to numeric states
    $state = $self->_state_to_code($state);

    unless (defined $msg) {
        $msg = "State was set, but no accompanying message was set in _state()";
    }

    if (!defined $self->{_state}) {
        $self->{_state} = $state;
        $self->_message($msg);
    } elsif ($self->{_state} != $state) {
        # States, they are a changin'
        if (STATE_CODE_PRIORITY->{$state} > STATE_CODE_PRIORITY->{$self->{_state}}) {
            # We've been given a "worse" state.
            $self->{_state} = $state;
            # We don't append when setting a worse state
            $self->_message($msg);
        } else {
            # We've been asked to from a bad to a better state
            #  This would cause us to lose an important failure state, so we refuse.
        }
    } else {
        # We were passed the same state that we were already in, just update the message
        if ($append) {
            $self->_message($self->message . "; " . $msg);
        } else {
            $self->_message($msg);
        }
    }

    # return textual state
    return STATE_CODE->{$self->{_state}};
}

sub exit_state {
    my $self = shift;
    my ($state, $message) = @_;

    # Firstm we see if we're being called 
    if (defined $self && ref($self) && $self->isa('Monitor::Object')) {

        if (!defined $self->{_state}) {
            if (!defined $state || !defined $message) {
                $self->state(UNKNOWN, "No state set");
            } else {
                $self->state($state, $message);
            }
        }

        $state = $self->state;
        $message = $self->_message;
        $self->_clear;
    } else {
        $state = __PACKAGE__->_state_to_text($state);
        $message ||= "No message provided";
    }

    $message = $state . $MSG_STATE_SEP . $message;
    if ($EXIT) {
        print "$message\n";
        CORE::exit STATE->{$state};
    } else {
        return (STATE->{$state}, $message);
    }
}

sub exit { exit_state(@_) }

1;

