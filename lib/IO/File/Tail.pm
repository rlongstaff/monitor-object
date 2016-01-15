#############################################################################
#
#
#
#
#############################################################################

package IO::File::Tail;

use warnings;
use strict;

use Fcntl qw{:seek}; # For SEEK_SET

use base qw{IO::File};

#sub new {
#    my $proto = shift;
#    my $class = ref($proto)||$proto;
#    my $self = $class->SUPER::new(@_);
#
#    ${*$self}{_bookmark_file} = undef;
#
#    return $self;
#}

sub bookmark_file {
    my $self = shift;
    my ($bookmark_file) = @_;

    if (defined $bookmark_file) {
        ${*$self}{_bookmark_file} = $bookmark_file;
    }

    return ${*$self}{_bookmark_file};
}

sub open {
    my $self = shift;

    my $ret = $self->SUPER::open(@_);
    unless ($ret) {
        $self->_set_error_message(
            "Could not open $_[0]: ". $!
        );
        return $ret;
    }

    return $self->_load_bookmark;
}

sub close {
    my $self = shift;

    my $ret = $self->_save_bookmark;
    unless ($ret) {
        return $ret;
    }

    $ret = $self->SUPER::close(@_);
    unless ($ret) {
        $self->_set_error_message(
            "Could not close $_[0]: ". $!
        );
    }
    return $ret;
}

sub error_message {
    my $self = shift;

    return ${*$self}{_error_msg};
}

#############################################################################
#
# Returns the status of the attempt to load a bookmark
#   1     - Bookmark loaded and position adjusted
#   0     - Failed to seek to the proper location
#   undef - There was an error loading the bookmark or seeking
#   -1    - The bookmark file was loaded, but the file described is not the
#           file we have open
#
#############################################################################
sub _load_bookmark {
    my $self = shift;

    # If no bookmark file exists, assume we're in a first-run situation
    unless ( -f $self->bookmark_file) {
        return 1;
    }

    my $bm_fh = IO::File->new;

    unless ($bm_fh->open($self->bookmark_file, '<')) {
        $self->_set_error_message(
            "Could not open bookmark " .
            $self->bookmark_file . ": $!"
        );
        return undef;
    }

    my ($bm_inode, $bm_pos) = split(/,/, $bm_fh->getline);

    unless ($bm_fh->close) {
        $self->_set_error_message(
            "Could not close bookmark " .
            $self->bookmark_file . ": $!"
        );
        return undef;
    }

    unless (defined $bm_inode) {
        $self->_set_error_message("Failed to parse inode information");
        return undef;
    }

    my ($inode, $fsize) = ($self->stat)[1,7];
    if ($inode != $bm_inode) {
        # This is not the file you're looking for *handwave*
        return -1;
    }

    unless (defined $bm_pos) {
        $self->_set_error_message(
            "Found valid inode, but failed to parse position"
        );
        return undef;
    }

    if ($bm_pos > $fsize) {
        # Somebody truncated the file; we have the same inode but our position
        # is past EOF
        return -1;
    }

    return $self->seek($bm_pos, SEEK_SET);
}

sub _save_bookmark {
    my $self = shift;

    my $msg;

    my $inode = ($self->stat)[1];
    my $pos = $self->tell;

    my $bm_fh = IO::File->new;
    unless ($bm_fh->open($self->bookmark_file, '>')) {
        $self->_set_error_message(
            "Could not open " . $self->bookmark_file .  ": $!"
        );
        return undef;
    }

    $bm_fh->print(
        join(',', $inode, $pos),
        "\n"
    );

    unless ($bm_fh->close) {
        $self->_set_error_message(
            "Could not close " . $self->bookmark_file .  ": $!"
        );
        return undef;
    }

    return 1;
}

sub _set_error_message {
    my $self = shift;
    my ($message) = @_;

    ${*$self}{_error_msg} = $message;

    return;
}

1;

