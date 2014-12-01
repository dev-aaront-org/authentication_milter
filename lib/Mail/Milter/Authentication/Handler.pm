package Mail::Milter::Authentication::Handler;

use strict;
use warnings;

our $VERSION = 0.4;

use base 'Mail::Milter::Authentication::Handler::Generic';

use Sys::Syslog qw{:standard :macros};

sub connect_callback {

    # On Connect
    my ( $self, $hostname, $sockaddr_in ) = @_;
    $self->dbgout( 'CALLBACK', 'Connect', LOG_DEBUG );
    $self->set_return( $self->smfis_continue() );
    my $CONFIG = $self->config();
    eval {
        local $SIG{'ALRM'};
        if ( $CONFIG->{'connect_timeout'} ) {
            $SIG{'ALRM'} = sub{ die "Timeout\n" };
            alarm( $CONFIG->{'connect_timeout'} );
        }
        foreach my $handler (qw{ core auth trustedip localip iprev }) {
            $self->get_handler($handler)->connect_callback( $hostname, $sockaddr_in );
        }
        alarm(0);
    };
    if ( my $error = $@ ) {
        $self->log_error( 'Connect callback error ' . $error );
        $self->exit_on_close();
        $self->tempfail_on_error();
    }
    return $self->get_return();
}

sub helo_callback {

    # On HELO
    my ( $self, $helo_host ) = @_;
    $self->dbgout( 'CALLBACK', 'Helo', LOG_DEBUG );
    $self->set_return( $self->smfis_continue() );
    $helo_host = q{} if not $helo_host;
    my $CONFIG = $self->config();
    eval {
        local $SIG{'ALRM'};
        if ( $CONFIG->{'command_timeout'} ) {
            $SIG{'ALRM'} = sub{ die "Timeout\n" };
            alarm( $CONFIG->{'command_timeout'} );
        }

        # Take only the first HELO from a connection
        if ( !( $self->helo_name() ) ) {
            foreach my $handler (qw{ core ptr }) {
                $self->get_handler($handler)->helo_callback($helo_host);
            }
        }

        alarm(0);
    };
    if ( my $error = $@ ) {
        $self->log_error( 'HELO callback error ' . $error );
        $self->exit_on_close();
        $self->tempfail_on_error();
    }
    return $self->get_return();
}

sub envfrom_callback {

    # On MAILFROM
    #...
    my ( $self, $env_from ) = @_;
    $self->dbgout( 'CALLBACK', 'EnvFrom', LOG_DEBUG );
    $self->set_return( $self->smfis_continue() );
    $env_from = q{} if not $env_from;
    my $CONFIG = $self->config();
    eval {
        local $SIG{'ALRM'};
        if ( $CONFIG->{'command_timeout'} ) {
            $SIG{'ALRM'} = sub{ die "Timeout\n" };
            alarm( $CONFIG->{'command_timeout'} );
        }
        foreach my $handler (qw{ core sanitize auth dmarc spf dkim }) {
            $self->get_handler($handler)->envfrom_callback($env_from);
        }
        alarm(0);
    };
    if ( my $error = $@ ) {
        $self->log_error( 'Env From callback error ' . $error );
        $self->exit_on_close();
        $self->tempfail_on_error();
    }
    return $self->get_return();
}

sub envrcpt_callback {

    # On RCPTTO
    #...
    my ( $self, $env_to ) = @_;
    $self->dbgout( 'CALLBACK', 'EnvRcpt', LOG_DEBUG );
    $self->set_return( $self->smfis_continue() );
    $env_to = q{} if not $env_to;
    my $CONFIG = $self->config();
    eval {
        local $SIG{'ALRM'};
        if ( $CONFIG->{'command_timeout'} ) {
            $SIG{'ALRM'} = sub{ die "Timeout\n" };
            alarm( $CONFIG->{'command_timeout'} );
        }
        foreach my $handler (qw{ core dmarc }) {
            $self->get_handler($handler)->envrcpt_callback($env_to);
        }
        alarm(0);
    };
    if ( my $error = $@ ) {
        $self->log_error( 'Rcpt To callback error ' . $error );
        $self->exit_on_close();
        $self->tempfail_on_error();
    }
    return $self->get_return();
}

sub header_callback {

    # On Each Header
    my ( $self, $header, $value ) = @_;
    $self->dbgout( 'CALLBACK', 'Header', LOG_DEBUG );
    $self->set_return( $self->smfis_continue() );
    $value = q{} if not $value;
    my $CONFIG = $self->config();
    eval {
        local $SIG{'ALRM'};
        if ( $CONFIG->{'content_timeout'} ) {
            $SIG{'ALRM'} = sub{ die "Timeout\n" };
            alarm( $CONFIG->{'content_timeout'} );
        }
        foreach my $handler (qw{ core sanitize dkim dmarc senderid }) {
            $self->get_handler($handler)->header_callback( $header, $value );
        }
        alarm(0);
    };
    if ( my $error = $@ ) {
        $self->log_error( 'Header callback error ' . $error );
        $self->exit_on_close();
        $self->tempfail_on_error();
    }
    return $self->get_return();
}

sub eoh_callback {

    # On End of headers
    my ($self) = @_;
    $self->dbgout( 'CALLBACK', 'EOH', LOG_DEBUG );
    $self->set_return( $self->smfis_continue() );
    my $CONFIG = $self->config();
    eval {
        local $SIG{'ALRM'};
        if ( $CONFIG->{'content_timeout'} ) {
            $SIG{'ALRM'} = sub{ die "Timeout\n" };
            alarm( $CONFIG->{'content_timeout'} );
        }
        foreach my $handler (qw{ dkim senderid }) {
            $self->get_handler($handler)->eoh_callback();
        }
        alarm(0);
    };
    if ( my $error = $@ ) {
        $self->log_error( 'EOH callback error ' . $error );
        $self->exit_on_close();
        $self->tempfail_on_error();
    }
    $self->dbgoutwrite();
    return $self->get_return();
}

sub body_callback {

    # On each body chunk
    my ( $self, $body_chunk ) = @_;
    $self->dbgout( 'CALLBACK', 'Body', LOG_DEBUG );
    $self->set_return( $self->smfis_continue() );
    my $CONFIG = $self->config();
    eval {
        local $SIG{'ALRM'};
        if ( $CONFIG->{'content_timeout'} ) {
            $SIG{'ALRM'} = sub{ die "Timeout\n" };
            alarm( $CONFIG->{'content_timeout'} );
        }
        $self->get_handler('dkim')->body_callback( $body_chunk );
        alarm(0);
    };
    if ( my $error = $@ ) {
        $self->log_error( 'Body callback error ' . $error );
        $self->exit_on_close();
        $self->tempfail_on_error();
    }
    $self->dbgoutwrite();
    return $self->get_return();
}

sub eom_callback {

    # On End of Message
    my ($self) = @_;
    $self->dbgout( 'CALLBACK', 'EOM', LOG_DEBUG );
    $self->set_return( $self->smfis_continue() );
    my $CONFIG = $self->config();
    eval {
        local $SIG{'ALRM'};
        if ( $CONFIG->{'content_timeout'} ) {
            $SIG{'ALRM'} = sub{ die "Timeout\n" };
            alarm( $CONFIG->{'content_timeout'} );
        }
        foreach my $handler (qw{ dkim dmarc sanitize }) {
            $self->get_handler($handler)->eom_callback();
        }
        alarm(0);
    };
    if ( my $error = $@ ) {
        $self->log_error( 'EOM callback error ' . $error );
        $self->exit_on_close();
        $self->tempfail_on_error();
    }
    $self->add_headers();
    $self->dbgoutwrite();
    return $self->get_return();
}

sub abort_callback {

    # On any out of our control abort
    my ($self) = @_;
    $self->dbgout( 'CALLBACK', 'Abort', LOG_DEBUG );
    $self->set_return( $self->smfis_continue() );
    $self->dbgoutwrite();
    return $self->get_return();
}

sub close_callback {

    # On end of connection
    my ($self) = @_;
    $self->dbgout( 'CALLBACK', 'Close', LOG_DEBUG );
    $self->set_return( $self->smfis_continue() );
    $self->dbgoutwrite();
    return $self->get_return();
}

1;
