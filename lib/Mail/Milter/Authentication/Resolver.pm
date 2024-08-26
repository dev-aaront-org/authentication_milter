package Mail::Milter::Authentication::Resolver;
use 5.20.0;
use strict;
use warnings;
use Mail::Milter::Authentication::Pragmas;
# ABSTRACT: DNS Recolver methods
# VERSION
use base 'Net::DNS::Resolver';
use Scalar::Util qw{ weaken };
use Time::HiRes qw{ ualarm gettimeofday };

=head1 DESCRIPTION

Subclass for Net::DNS::Resolver, Versions of Net::DNS::Resolver from 1.03 up (to at least
1.18 at time of writing) do not timeout as expected. This introduces a wrapper timeout around
the query, send, and search calls which will fire 0.1 seconds after the timeout value passed
to Net::DNS::Resolver

=cut

{
    sub new { ## no critic
        my $class = shift;
        my %args = @_;
        my $self = $class->SUPER::new( @_ );
        weaken($args{_handler});
        $self->{ _handler } = $args{_handler};
        $self->{ _timedout } = {};
        $self->{cache_dns_timeouts} = $args{cache_dns_timeouts} // 1;
        return $self;
    }
}

sub clear_error_cache {
    my $self = shift;
    $self->{ _timedout } = {};
}

sub _get_microseconds {
    my ( $self ) = @_;
    my ($seconds, $microseconds) = gettimeofday;
    return ( ( $seconds * 1000000 ) + $microseconds );
}

sub _do { ## no critic
    my $self = shift;
    my $what = shift;

    my $handler = $self->{_handler};
    my $config = $handler->config();
    my $timeout = $config->{'dns_timeout'};

    my $return;
    my $domain = $_[0];
    my $org_domain = $_[0];
    my $query = $_[1];
    if ( $handler->is_handler_loaded( 'DMARC' ) ) {
        my $dmarc_object = $handler->get_handler('DMARC')->get_dmarc_object();
        $org_domain = eval{ $dmarc_object->get_organizational_domain( $org_domain ) };
        $handler->handle_exception( $@ );
    }

    # If we have a 'cached' timeout for this org domain then return
    if ( $self->{ _timedout }->{ $org_domain } ) {
        $handler->log_error( "Lookup $query $domain aborted due to previous DNS Lookup timeout on $org_domain" );
        $self->errorstring('query timed out');
        return;
    }

    my $start_time = $self->_get_microseconds;

    eval {
        $handler->set_handler_alarm( ( $timeout + 0.2 ) * 1000000 ); # 0.2 seconds over that passed to Net::DNS::Resolver
        $return = $self->SUPER::send( @_ )   if $what eq 'send';
        $return = $self->SUPER::query( @_ )  if $what eq 'query';
        $return = $self->SUPER::search( @_ ) if $what eq 'search';
        $handler->reset_alarm();
    };

    if ( my $error = $@ ) {
        $handler->reset_alarm();
        my $type = $handler->is_exception_type( $error );
        if ( $type && $type eq 'Timeout' ) {
            # We have a timeout, is it global or is it ours?
            if ( $handler->get_time_remaining() > 0 ) {
                # We have time left, but the lookup timed out
                # Log this and move on!
                if ($self->{cache_dns_timeouts}) {
                    $handler->log_error( "DNS Lookup $query $domain error, hold set on $org_domain : Timeout calling Net::DNS::Resolver" );
                    $self->{ _timedout }->{ $org_domain } = 1;
                }
                $self->errorstring('query timed out');
                return;
            }
        }
        $handler->handle_exception( $error );
    }

    my $time_taken = $self->_get_microseconds - $start_time;
    my $servfail_timeout = exists $config->{'dns_servfail_timeout'} ? $config->{'dns_servfail_timeout'} : 1000000; # Consider a servfail as a timeout after (default) 1 second;

    # Timeouts or SERVFAIL are unlikely to recover within the lifetime of this transaction,
    # when we encounter them, don't lookup this org domain again.
    if ( $self->{cache_dns_timeouts} && (( $self->errorstring =~ /timeout/i ) || ( $self->errorstring eq 'query timed out' ) || ( $self->errorstring eq 'SERVFAIL' && $time_taken > $servfail_timeout )) ) {
        $self->{ _timedout }->{ $org_domain } = 1;
        $handler->log_error( "DNS Lookup $query $domain error, hold set on $org_domain : ".$self->errorstring );
      }

    return $return;
}

sub query { ## no critic
    my $self = shift;
    return $self->_do( 'query', @_ );
}

sub search { ## no critic
    my $self = shift;
    return $self->_do( 'search', @_ );
}

sub send { ## no critic
    my $self = shift;
    return $self->_do( 'send', @_ );
}

1;
