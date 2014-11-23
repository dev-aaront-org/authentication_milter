package Mail::Milter::Authentication::Handler::DMARC;

use strict;
use warnings;

our $VERSION = 0.3;

use Mail::Milter::Authentication::Config qw{ get_config };
use Mail::Milter::Authentication::Util;

use Sys::Syslog qw{:standard :macros};

use Mail::DMARC::PurePerl;

sub envfrom_callback {
    my ( $ctx, $env_from ) = @_;
    my $CONFIG = get_config();
    my $priv = $ctx->getpriv();
    return if ( !$CONFIG->{'check_dmarc'} );
    return if ( $priv->{'is_local_ip_address'} );
    return if ( $priv->{'is_trusted_ip_address'} );
    return if ( $priv->{'is_authenticated'} );
    delete $priv->{'dmarc.from_header'};
    $priv->{'dmarc.failmode'} = 0;

    $env_from = q{} if $env_from eq '<>';

    my $domain_from;
    if ( ! $env_from ) {
        $domain_from = $priv->{'core.helo_name'};
    }
    else {
        $domain_from = get_domain_from($env_from);
    }

    my $dmarc;
    eval {
        $dmarc = Mail::DMARC::PurePerl->new();
        $dmarc->verbose(1);
        $dmarc->source_ip($priv->{'core.ip_address'})
    };
    if ( my $error = $@ ) {
        log_error( $ctx, 'DMARC IP Error ' . $error );
        add_auth_header( $ctx, 'dmarc=temperror' );
        $priv->{'dmarc.failmode'} = 1;
        return;
    }
    $priv->{'dmarc.is_list'} = 0;
    $priv->{'dmarc.obj'}     = $dmarc;
    eval {
        $dmarc->envelope_from($domain_from);
    };
    if ( my $error = $@ ) {
        log_error( $ctx, 'DMARC Mail From Error for <' . $domain_from . '> ' . $error );
        log_error( $ctx, 'DMARC Debug Helo: ' . $priv->{'core.helo_name'} );
        log_error( $ctx, 'DMARC Debug Envfrom: ' . $env_from );
        add_auth_header( $ctx, 'dmarc=temperror' );
        $priv->{'dmarc.failmode'} = 1;
        return;
    }
}

sub envrcpt_callback {
    my ( $ctx, $env_to ) = @_;
    my $CONFIG = get_config();
    my $priv = $ctx->getpriv();
    return if ( !$CONFIG->{'check_dmarc'} );
    return if ( $priv->{'is_local_ip_address'} );
    return if ( $priv->{'is_trusted_ip_address'} );
    return if ( $priv->{'is_authenticated'} );
    return if ( $priv->{'dmarc.failmode'} );
    my $dmarc = $priv->{'dmarc.obj'};
    my $envelope_to = get_domain_from($env_to);
    eval { $dmarc->envelope_to($envelope_to) };
    if ( my $error = $@ ) {
        log_error( $ctx, 'DMARC Rcpt To Error ' . $error );
        add_auth_header( $ctx, 'dmarc=temperror' );
        $priv->{'dmarc.failmode'} = 1;
        return;
    }
}

sub header_callback {
    my ( $ctx, $header, $value ) = @_;
    my $CONFIG = get_config();
    my $priv = $ctx->getpriv();
    return if ( !$CONFIG->{'check_dmarc'} );
    return if ( $priv->{'is_local_ip_address'} );
    return if ( $priv->{'is_trusted_ip_address'} );
    return if ( $priv->{'is_authenticated'} );
    return if ( $priv->{'dmarc.failmode'} );
    if ( lc $header eq 'list-id' ) {
        dbgout( $ctx, 'DMARCListId', 'List detected: ' . $value , LOG_INFO );
        $priv->{'dmarc.is_list'} = 1;
    }
    if ( $header eq 'From' ) {
        if ( exists $priv->{'dmarc.from_header'} ) {
            dbgout( $ctx, 'DMARCFail', 'Multiple RFC5322 from fields', LOG_INFO );
            # ToDo handle this by eveluating DMARC for each field in turn as
            # suggested in the DMARC spec part 5.6.1
            # Currently this does not give reporting feedback to the author domain, this should be changed.
            add_auth_header( $ctx, 'dmarc=fail (multiple RFC5322 from fields in message)' );
            $priv->{'dmarc.failmode'} = 1;
            return;
        }
        $priv->{'dmarc.from_header'} = $value;
        my $dmarc = $priv->{'dmarc.obj'};
        eval { $dmarc->header_from_raw( $header . ': ' . $value ) };
        if ( my $error = $@ ) {
            log_error( $ctx, 'DMARC Header From Error ' . $error );
            add_auth_header( $ctx, 'dmarc=temperror' );
            $priv->{'dmarc.failmode'} = 1;
            return;
        }
    }
}

sub eom_callback {
    my ( $ctx ) = @_;
    my $CONFIG = get_config();
    my $priv = $ctx->getpriv();
    return if ( !$CONFIG->{'check_dmarc'} );
    return if ( $priv->{'is_local_ip_address'} );
    return if ( $priv->{'is_trusted_ip_address'} );
    return if ( $priv->{'is_authenticated'} );
    return if ( $priv->{'dmarc.failmode'} );
    eval {
        my $dmarc = $priv->{'dmarc.obj'};
        if ( $priv->{'dkim.failmode'} ) {
            log_error( $ctx, 'DKIM is in failmode, Skipping DMARC' );
            add_auth_header( $ctx, 'dmarc=temperror' );
            $priv->{'dmarc.failmode'} = 1;
            return;
        }
        my $dkim  = $priv->{'dkim.obj'};
        $dmarc->dkim($dkim);
        my $dmarc_result = $dmarc->validate();
        #$ctx->progress();
        my $dmarc_code   = $dmarc_result->result;
        dbgout( $ctx, 'DMARCCode', $dmarc_code, LOG_INFO );
        if ( ! ( $CONFIG->{'check_dmarc'} == 2 && $dmarc_code eq 'none' ) ) {
            my $dmarc_policy;
            if ( $dmarc_code ne 'pass' ) {
                $dmarc_policy = eval { $dmarc_result->disposition() };
                if ( my $error = $@ ) {
                    log_error( $ctx, 'DMARCPolicyError ' . $error );
                }
                dbgout( $ctx, 'DMARCPolicy', $dmarc_policy, LOG_INFO );
            }
            my $dmarc_header = format_header_entry( 'dmarc', $dmarc_code );
            my $is_list_entry = q{};
            if ( $CONFIG->{'dmarc_detect_list_id'} && $priv->{'dmarc.is_list'} ) {
                $is_list_entry = ';has-list-id=yes';
            }
            if ($dmarc_policy) {
                $dmarc_header .= ' ('
                  . format_header_comment(
                    format_header_entry( 'p', $dmarc_policy ) )
                  . $is_list_entry
                . ')';
            }
            $dmarc_header .= ' '
              . format_header_entry( 'header.from',
                get_domain_from( $priv->{'dmarc.from_header'} ) );
            add_auth_header( $ctx, $dmarc_header );
        }
            # Try as best we can to save a report, but don't stress if it fails.
        my $rua = eval{ $dmarc_result->published()->rua(); };
        if ( $rua ) {
            eval{
                dbgout( $ctx, 'DMARCReportTo', $rua, LOG_INFO );
                $dmarc->save_aggregate();
            };
            if ( my $error = $@ ) {
                log_error( $ctx, 'DMARC Report Error ' . $error );
            }
        }
    };
    if ( my $error = $@ ) {
        log_error( $ctx, 'DMARC Error ' . $error );
        add_auth_header( $ctx, 'dmarc=temperror' );
        return;
    }
}

1;