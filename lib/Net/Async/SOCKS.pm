package Net::Async::SOCKS;
# ABSTRACT: basic SOCKS5 connection support for IO::Async
use strict;
use warnings;

our $VERSION = '0.001';

=head1 NAME

Net::Async::SOCKS - some degree of SOCKS5 proxy support in L<IO::Async>

=head1 DESCRIPTION

Currently provides a very basic implementation of SOCKS_connect:

 $loop->connect(
  extensions => [qw(SOCKS)],
  SOCKS_host => 'localhost',
  SOCKS_port => 1080,
  host => '1.2.3.4',
  port => 80,
 )->then(sub {
  my ($stream) = @_;
  $stream->write("GET / HTTP/1.1...");
 })

=cut

use Carp qw(croak);
use Protocol::SOCKS::Client;
use Protocol::SOCKS::Constants qw(:all);
use Syntax::Keyword::Try;
use IO::Async::Loop;
use IO::Async::Stream;
use Log::Any qw($log);

=head1 METHODS

The following methods are added to L<IO::Async::Loop>
but are not intended to be called directly - use the
extensions feature instead.

=cut

=head2 SOCKS_connect

Establish a TCP connection via SOCKS5 proxy.
Only allows IPv4 host and numerical port for now.

=cut

sub IO::Async::Loop::SOCKS_connect {
	my ($loop, %params) = @_;

	my %socks_params = map { /^SOCKS_(.*)$/ ? ($1 => delete $params{$_}) : () } keys %params;

	# Start with the usual boilerplate to Future-wrap things and apply our initial stream handle

	my $on_done;
	if(exists $params{on_connected}) {
		my $on_connected = delete $params{on_connected};
		$on_done = sub {
			my ( $stream ) = @_;
			$on_connected->( $stream->read_handle );
		};
	} elsif( exists $params{on_stream} ) {
		my $on_stream = delete $params{on_stream};
		$on_done = $on_stream;
	} else {
		croak "Expected 'on_connected' or 'on_stream' or to return a Future" unless defined wantarray;
	}

	my $on_socks_error = delete $params{on_socks_error} or defined wantarray or
		croak "Expected 'on_socks_error' or to return a Future";

	my $stream = delete $params{handle} || IO::Async::Protocol::Stream->new;

	$stream->isa( "IO::Async::Stream" ) or
		croak "Can only SOCKS_connect a handle instance of IO::Async::Stream";

	# Now we begin the SOCKS negotiation dance.
	# * Connect to SOCKS5 host:port
	# * Authenticate if required
	# * Send connect request
	# * Accept server response - this may have the proxied server endpoint,
	# in practice (ssh socks5) the endpoint could be blank
	# * use this stream for TCP traffic
	my $f;
    $log->tracef("Establishing SOCKS connection to %s:%s", $socks_params{host}, $socks_params{port} || 1080);
	$f = $loop->connect(
		# The ->connect API has many ways of specifying
		# the connection endpoint. More may be added in
		# future. This makes passing the original parameters
		# risky - they might override the SOCKS host/port
		# details.
		socktype   => 'stream',
		host       => delete $socks_params{host},
		service    => delete $socks_params{port} || 1080,
	)->then(sub {
		my ($sock) = @_;
        try {
            $log->tracef("We now have a sock (%s)", ref($sock));

            # We're delegating most of the real work to the protocol here
            my $proto = Protocol::SOCKS::Client->new(
                version => 5,
                writer => sub {
                    $log->tracef("Writing [%s]", $_[0]);
                    $sock->write(shift)
                },
                %socks_params,
            );

            # Proxy any read traffic into our protocol handler.
            # Once we've negotiated the stream, we'll take over.
            $stream->configure(
                handle => $sock,
                on_read => sub {
                    my ($stream, $buffref, $eof) = @_;
                    $log->tracef("Reading [%s]", $$buffref);
                    $proto->on_read($buffref);
                    if($eof) {
                        $stream->close;
                        $f->fail('connect' => 'something broke');
                    }
                }
            );
            # $loop->add($stream);

            # Version and auth header goes first
            $log->tracef("Requesting init packet write");
            $stream->write($proto->init_packet);

            # Push the read handler - if we were
            # given a prefab stream there may be a
            # read handler in place already
            # We're ready now - let's start the auth
            # process.
            return $proto->auth(
            )->then(sub {
                $log->tracef("Auth complete");
                $proto->connect(
                    ATYPE_IPV4,
                    $params{host},
                    $params{service},
                )->transform(
                    done => sub {
                        $log->tracef("SOCKS protocol connection complete");
                        # $loop->remove($stream);
                        $stream
                    }
                )
            })
        } catch {
            $log->errorf("Failure - %s", $@);
            return Future->fail($@, 'socks');
        }
	});
	$f->on_done($on_done) if $on_done;
	$f->on_fail(sub {
        $log->tracef("Error: %s", join ' ', @_);
		$on_socks_error->($_[0]) if defined $_[1] and $_[1] eq "socks";
	}) if $on_socks_error;

	$f->on_ready(sub { undef $f });# unless defined wantarray;
	my %ssl_params = map { /^(SSL_.*)$/ ? ($1 => delete $params{$_}) : () } keys %params;
    my $want_ssl = ($params{extensions} || [''])->[0] eq 'SSL';
    $log->tracef("Want SSL, will upgrade") if $want_ssl;
    return $f unless $want_ssl;
	$f->then(sub {
        my $stream = shift;
        try {
            $log->tracef("Upgrading to SSL with these options: %s", join ',', sort keys %ssl_params);
            return $stream->SSL_upgrade(
                %ssl_params
            )
        } catch {
            $log->errorf("failed to upgrade - %s", $@);
            return Future->fail($@, 'ssl');
        }
    });
}

1;

__END__

=head1 AUTHOR

Tom Molesworth <TEAM@cpan.org>

=head1 LICENSE

Copyright Tom Molesworth 2014-2015. Licensed under the same terms as Perl itself.

