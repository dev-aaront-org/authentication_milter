package Mail::Milter::Authentication::Handler::SenderID;
use 5.20.0;
use strict;
use warnings;
use Mail::Milter::Authentication::Pragmas;
# ABSTRACT: Handler class for SenderID
# VERSION
use base 'Mail::Milter::Authentication::Handler';
use Mail::Milter::Authentication::Handler::SPF;
use Mail::SPF;

sub default_config {
    return {
        'hide_none' => 1,
    };
}

sub grafana_rows {
    my ( $self ) = @_;
    my @rows;
    push @rows, $self->get_json( 'SenderID_metrics' );
    return \@rows;
}

sub setup_callback {
    my ( $self ) = @_;
    # Call connect_callback from SPF handler to setup object creation
    # Required if SenderID is enabled but SPF is disabled.
    return Mail::Milter::Authentication::Handler::SPF::setup_callback( $self );
}

sub register_metrics {
    return {
        'senderid_total'      => 'The number of emails processed for Sender ID',
    };
}

sub helo_callback {
    my ( $self, $helo_host ) = @_;
    $self->{'helo_name'} = $helo_host;
}

sub envfrom_callback {
    my ( $self, $env_from ) = @_;
    return if ( $self->is_local_ip_address() );
    return if ( $self->is_trusted_ip_address() );
    return if ( $self->is_authenticated() );
    delete $self->{'from_header'};
}

sub header_callback {
    my ( $self, $header, $value ) = @_;
    return if ( $self->is_local_ip_address() );
    return if ( $self->is_trusted_ip_address() );
    return if ( $self->is_authenticated() );
    if ( lc $header eq 'from' ) {
        $self->{'from_header'} = $value;
    }
}

sub eoh_callback {
    my ($self) = @_;
    my $config = $self->handler_config();
    return if ( $self->is_local_ip_address() );
    return if ( $self->is_trusted_ip_address() );
    return if ( $self->is_authenticated() );

    my $spf_server = $self->get_object('spf_server');
    if ( ! $spf_server ) {
        $self->log_error( 'SenderID Setup Error' );
        my $header = Mail::AuthenticationResults::Header::Entry->new()->set_key( 'senderid' )->safe_set_value( 'temperror' );
        $self->add_auth_header($header);
        $self->metric_count( 'senderid_total', { 'result' => 'error' } );
        return;
    }

    my $scope = 'pra';

    my $identity = $self->get_address_from( $self->{'from_header'} );

    if ( ! $identity ) {
        $self->log_error( 'SENDERID Error No Identity' );
        my $header = Mail::AuthenticationResults::Header::Entry->new()->set_key( 'senderid' )->safe_set_value( 'permerror' );
        $self->add_auth_header( $header );
        $self->metric_count( 'senderid_total', { 'result' => 'permerror' } );
        return;
    }

    eval {
        my $spf_request = Mail::SPF::Request->new(
            'versions'      => [2],
            'scope'         => $scope,
            'identity'      => $identity,
            'ip_address'    => $self->ip_address(),
            'helo_identity' => $self->{'helo_name'},
        );

        my $spf_result = $spf_server->process($spf_request);

        my $result_code = $spf_result->code();
        $self->metric_count( 'senderid_total',  {'result' => $result_code } );
        $self->dbgout( 'SenderIdCode', $result_code, LOG_DEBUG );

        if ( ! ( $config->{'hide_none'} && $result_code eq 'none' ) ) {
            my $auth_header = Mail::AuthenticationResults::Header::Entry->new()->set_key( 'senderid' )->safe_set_value( $result_code );
            $self->add_auth_header( $auth_header );
#my $result_local  = $spf_result->local_explanation;
#my $result_auth   = $spf_result->can( 'authority_explanation' ) ? $spf_result->authority_explanation() : '';
            my $result_header = $spf_result->received_spf_header();
            my ( $header, $value ) = split( ': ', $result_header, 2 );
            $self->prepend_header( $header, $value );
            $self->dbgout( 'SPFHeader', $result_header, LOG_DEBUG );
        }
    };
    if ( my $error = $@ ) {
        $self->handle_exception( $error );
        $self->log_error( 'SENDERID Error ' . $error );
        $self->metric_count( 'senderid_total', { 'result' => 'error' } );
        my $header = Mail::AuthenticationResults::Header::Entry->new()->set_key( 'senderid' )->safe_set_value( 'temperror' );
        $self->add_auth_header($header);
        return;
    }
}

sub close_callback {
    my ( $self ) = @_;
    delete $self->{'from_header'};
    delete $self->{'helo_name'};
}

1;

__END__

=head1 DESCRIPTION

Implements the SenderID standard checks.

=head1 CONFIGURATION

        "SenderID" : {                                  | Config for the SenderID Module
            "hide_none" : 1                             | Hide auth line if the result is 'none'
        },

