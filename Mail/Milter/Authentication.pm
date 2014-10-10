package Mail::Milter::Authentication;

use strict;
use warnings;

use Mail::Milter::Authentication::Handler;
use Sendmail::PMilter qw { :all };

sub start {
    my ( $args ) = @_;
    my $connection = $args->{ 'connection' };

    my $callbacks = {
      'connect' => \&Mail::Milter::Authentication::Handler::connect_callback,
      'helo'    => \&Mail::Milter::Authentication::Handler::helo_callback,
      'envfrom' => \&Mail::Milter::Authentication::Handler::envfrom_callback,
      'envrcpt' => \&Mail::Milter::Authentication::Handler::envrcpt_callback,
      'header'  => \&Mail::Milter::Authentication::Handler::header_callback,
      'eoh'     => \&Mail::Milter::Authentication::Handler::eoh_callback,
      'body'    => \&Mail::Milter::Authentication::Handler::body_callback,
      'eom'     => \&Mail::Milter::Authentication::Handler::eom_callback,
      'abort'   => \&Mail::Milter::Authentication::Handler::abort_callback,
      'close'   => \&Mail::Milter::Authentication::Handler::close_callback,
    };
    #Sendmail::PMilter::setdbg( 9 );
    my $milter = new Sendmail::PMilter;
    $milter->setconn( $connection );
    $milter->register( "authentication_milter", $callbacks, SMFI_CURR_ACTS );
    $milter->main();
    # Never reaches here, callbacks are called from Milter.
    die 'Something went wrong';
}

1;
