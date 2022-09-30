package Mail::Milter::Authentication::Handler::XGoogleDKIM;
use 5.20.0;
use strict;
use warnings;
use Mail::Milter::Authentication::Pragmas;
# ABSTRACT: Handler class for Google specific DKIM
# VERSION
use base 'Mail::Milter::Authentication::Handler';
use Mail::DKIM 1.20200824;
use Mail::DKIM::DNS;
use Mail::DKIM::Verifier;

sub default_config {
    return {
        'hide_none'         => 0,
    };
}

sub grafana_rows {
    my ( $self ) = @_;
    my @rows;
    push @rows, $self->get_json( 'XGoogleDKIM_metrics' );
    return \@rows;
}

sub register_metrics {
    return {
        'xgoogledkim_total'      => 'The number of emails processed for X-Google-DKIM',
    };
}

sub envfrom_callback {
    my ( $self, $env_from ) = @_;
    $self->{'failmode'}     = 0;
    $self->{'headers'}      = [];
    $self->{'has_dkim'}     = 0;
    $self->{'carry'}        = q{};
    $self->destroy_object('xgdkim');
}

sub header_callback {
    my ( $self, $header, $value, $original ) = @_;
    return if ( $self->{'failmode'} );
    my $EOL        = "\015\012";
    my $dkim_chunk = $original . $EOL;
    $dkim_chunk =~ s/\015?\012/$EOL/g;

    if ( lc($header) eq 'dkim-signature' ) {
        $dkim_chunk = 'X-Orig-' . $dkim_chunk;
    }
    if ( lc($header) eq 'domainkey-signature' ) {
        $dkim_chunk = 'X-Orig-' . $dkim_chunk;
    }
    push @{$self->{'headers'}} , $dkim_chunk;

    # Add Google signatures to the mix.
    # Is this wise?
    if ( $header eq 'X-Google-DKIM-Signature' ) {
        my $x_dkim_chunk = 'DKIM-Signature: ' . $value . $EOL;
        $x_dkim_chunk =~ s/\015?\012/$EOL/g;
        push @{$self->{'headers'}} , $x_dkim_chunk;
        $self->{'has_dkim'} = 1;
        my ($domain) = $value =~ /d=([^;]*);/;
        my ($selector) = $value =~ /s=([^;]*);/;
        my $resolver = $self->get_object('resolver');
        if ( defined $selector && defined $domain ) {
            my $lookup = $selector.'._domainkey.'.$domain;
            eval{ $resolver->bgsend( $lookup, 'TXT' ) };
            $self->handle_exception( $@ );
            $self->dbgout( 'DNSEarlyLookup', "$lookup TXT", LOG_DEBUG );
        }
    }
}

sub eoh_callback {
    my ($self) = @_;
    return if ( $self->{'failmode'} );
    my $config = $self->handler_config();

    if ( $self->{'has_dkim'} == 0 ) {
        $self->metric_count( 'xgoogledkim_total', { 'result' => 'none' } );
        $self->dbgout( 'XGoogleDKIMResult', 'No X-Google-DKIM headers', LOG_DEBUG );
        if ( !( $config->{'hide_none'} ) ) {
            my $header = Mail::AuthenticationResults::Header::Entry->new()->set_key( 'x-google-dkim' )->safe_set_value( 'none' );
            $header->add_child( Mail::AuthenticationResults::Header::Comment->new()->safe_set_value( 'no signatures found' ) );
            $self->add_auth_header( $header );
        }
        delete $self->{'headers'};
    }
    else {

        my $dkim;
        eval {
            $dkim = Mail::DKIM::Verifier->new();
            my $resolver = $self->get_object('resolver');
            Mail::DKIM::DNS::resolver($resolver);
            $self->set_object('xgdkim', $dkim, 1);
        };
        if ( my $error = $@ ) {
            $self->handle_exception( $error );
            $self->log_error( 'XGoogleDKIM Setup Error ' . $error );
            $self->{'failmode'} = 1;
            $self->_check_error( $error );
            $self->metric_count( 'xgoogledkim_total', { 'result' => 'error' } );
            delete $self->{'headers'};
            return;
        }

        eval {
            $dkim->PRINT( join q{},
                @{ $self->{'headers'} },
                "\015\012",
            );
        };
        if ( my $error = $@ ) {
            $self->handle_exception( $error );
            $self->log_error( 'XGoogleDKIM Headers Error ' . $error );
            $self->{'failmode'} = 1;
            $self->_check_error( $error );
            $self->metric_count( 'xgoogledkim_total', { 'result' => 'error' } );
        }

        delete $self->{'headers'};
    }

    $self->{'carry'} = q{};
}

sub body_callback {
    my ( $self, $body_chunk ) = @_;
    return if ( $self->{'failmode'} );
    return if ( $self->{'has_dkim'} == 0 );
    my $EOL = "\015\012";

    my $dkim_chunk;
    if ( $self->{'carry'} ne q{} ) {
        $dkim_chunk = $self->{'carry'} . $body_chunk;
        $self->{'carry'} = q{};
    }
    else {
        $dkim_chunk = $body_chunk;
    }

    if ( substr( $dkim_chunk, -1 ) eq "\015" ) {
        $self->{'carry'} = "\015";
        $dkim_chunk = substr( $dkim_chunk, 0, -1 );
    }

    $dkim_chunk =~ s/\015?\012/$EOL/g;

    my $dkim = $self->get_object('xgdkim');
    eval {
        $dkim->PRINT( $dkim_chunk );
    };
    if ( my $error = $@ ) {
        $self->handle_exception( $error );
        $self->log_error( 'XGoogleDKIM Body Error ' . $error );
        $self->{'failmode'} = 1;
        $self->_check_error( $error );
        $self->metric_count( 'xgoogledkim_total', { 'result' => 'error' } );
    }
}

sub eom_callback {
    my ($self) = @_;

    return if ( $self->{'has_dkim'} == 0 );
    return if ( $self->{'failmode'} );

    my $config = $self->handler_config();

    my $dkim = $self->get_object('xgdkim');

    eval {
        $dkim->PRINT( $self->{'carry'} );
        $dkim->CLOSE();

        my $dkim_result        = $dkim->result;
        my $dkim_result_detail = $dkim->result_detail;

        $self->metric_count( 'xgoogledkim_total', { 'result' => $dkim_result } );

        $self->dbgout( 'XGoogleDKIMResult', $dkim_result_detail, LOG_DEBUG );

        if ( !$dkim->signatures() ) {
            if ( !( $config->{'hide_none'} && $dkim_result eq 'none' ) ) {
                my $header = Mail::AuthenticationResults::Header::Entry->new()->set_key( 'x-google-dkim' )->safe_set_value( $dkim_result );
                $header->add_child( Mail::AuthenticationResults::Header::Comment->new()->safe_set_value( 'no signatures found' ) );
                $self->add_auth_header( $header );
            }
        }
        foreach my $signature ( $dkim->signatures() ) {

            my $otype = ref $signature;
            my $type =
                $otype eq 'Mail::DKIM::DkSignature' ? 'domainkeys'
              : $otype eq 'Mail::DKIM::Signature'   ? 'dkim'
              :                                       'dkim';
            $self->dbgout( 'XGoogleDKIMSignatureType', $type, LOG_DEBUG );

            $self->dbgout( 'XGoogleDKIMSignatureIdentity', $signature->identity, LOG_DEBUG );
            $self->dbgout( 'XGoogleDKIMSignatureResult',   $signature->result_detail, LOG_DEBUG );
            my $signature_result        = $signature->result();
            my $signature_result_detail = $signature->result_detail();

            if ( $signature_result eq 'invalid' ) {
                if ( $signature_result_detail =~ /DNS query timeout for (.*) at / ) {
                    my $timeout_domain = $1;
                    $self->log_error( "TIMEOUT DETECTED: in XGoogleDKIM result: $timeout_domain" );
                    $signature_result_detail = "DNS query timeout for $timeout_domain";
                }
            }

            my $result_comment = q{};
            if ( $signature_result ne 'pass' and $signature_result ne 'none' ) {
                $signature_result_detail =~ /$signature_result \((.*)\)/;
                if ( $1 ) {
                    $result_comment = $1 . ', ';
                }
            }
            if (
                !(
                    $config->{'hide_none'} && $signature_result eq 'none'
                )
              )
            {

                my $key_data = q{};
                eval {
                    my $key = $signature->get_public_key();
                    $key_data = $key->size() . '-bit ' . $key->type() . ' key';
                };

                my $header = Mail::AuthenticationResults::Header::Entry->new()->set_key( 'x-google-dkim' )->safe_set_value( $signature_result );
                $header->add_child( Mail::AuthenticationResults::Header::Comment->new()->safe_set_value( $result_comment . $key_data ) );
                $header->add_child( Mail::AuthenticationResults::Header::SubEntry->new()->set_key( 'header.d' )->safe_set_value( $signature->domain() ) );
                $header->add_child( Mail::AuthenticationResults::Header::SubEntry->new()->set_key( 'header.i' )->safe_set_value( $signature->identity() ) );
                $header->add_child( Mail::AuthenticationResults::Header::SubEntry->new()->set_key( 'header.b' )->safe_set_value( substr( $signature->data(), 0, 8 ) ) );
                $self->add_auth_header($header);
            }
        }

    };
    if ( my $error = $@ ) {
        $self->handle_exception( $error );
        # Also in DMARC module
        $self->log_error( 'XGoogleDKIM EOM Error ' . $error );
        $self->{'failmode'} = 1;
        $self->_check_error( $error );
        $self->metric_count( 'xgoogledkim_total', { 'result' => 'error' } );
        return;
    }
}

sub close_callback {
    my ( $self ) = @_;
    delete $self->{'failmode'};
    delete $self->{'headers'};
    delete $self->{'body'};
    delete $self->{'carry'};
    delete $self->{'has_dkim'};
    $self->destroy_object('xgdkim');
}

sub _check_error {
    my ( $self, $error ) = @_;
    if ( $error =~ /^DNS error: query timed out/
            or $error =~ /^DNS query timeout/
    ){
        $self->log_error( 'Temp XGoogleDKIM Error - ' . $error );
        my $header = Mail::AuthenticationResults::Header::Entry->new()->set_key( 'x-google-dkim' )->safe_set_value( 'temperror' );
        $header->add_child( Mail::AuthenticationResults::Header::Comment->new()->safe_set_value( 'dns timeout' ) );
        $self->add_auth_header( $header );
    }
    elsif ( $error =~ /^no domain to fetch policy for$/
            or $error =~ /^policy syntax error$/
            or $error =~ /^empty domain label/
            or $error =~ /^invalid name /
    ){
        $self->log_error( 'Perm XGoogleDKIM Error - ' . $error );
        my $header = Mail::AuthenticationResults::Header::Entry->new()->set_key( 'x-google-dkim' )->safe_set_value( 'perlerror' );
        $header->add_child( Mail::AuthenticationResults::Header::Comment->new()->safe_set_value( 'syntax or domain error' ) );
        $self->add_auth_header( $header );
    }
    else {
        $self->exit_on_close( 'Unexpected XGoogleDKIM Error - ' . $error );
        my $header = Mail::AuthenticationResults::Header::Entry->new()->set_key( 'x-google-dkim' )->safe_set_value( 'temperror' );
        $self->add_auth_header( $header );
        # Fill these in as they occur, but for unknowns err on the side of caution
        # and tempfail/exit
        $self->tempfail_on_error();
    }
}

1;

__END__

=head1 DESCRIPTION

Module for validation of X-Google-DKIM signatures.

=head1 CONFIGURATION

        "XGoogleDKIM" : {                               | Config for the X-Google-DKIM Module
            "hide_none"         : 0,                    | Hide auth line if the result is 'none'
        },

