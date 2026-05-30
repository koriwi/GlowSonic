package Plugins::GlowSonic::API::Sync;

# Blocking Subsonic API client using LWP::UserAgent
# Used for scanner/importer operations where async isn't needed

use strict;
use warnings;
use base qw(Plugins::GlowSonic::API);

use LWP::UserAgent;
use Slim::Utils::Log;

my $log = Slim::Utils::Log::logger('plugin.glowsonic');

# ---------------------------------------------------------------------------
# Constructor — adds LWP UA
# ---------------------------------------------------------------------------
sub new {
	my ($class, %opts) = @_;
	my $self = $class->SUPER::new(%opts);

	$self->{_ua} = LWP::UserAgent->new(
		agent   => 'GlowSonic/' . ($opts{plugin_version} || '0.1.0'),
		timeout => $opts{timeout} || 30,
	);

	return $self;
}

# ---------------------------------------------------------------------------
# Perform a blocking API call
# Returns: ($status, $data) where $status is 'ok', 'failed', or 'error'
# ---------------------------------------------------------------------------
sub call {
	my ($self, %args) = @_;

	my $endpoint = delete $args{endpoint};
	my $params   = delete $args{params} || {};
	my $timeout  = delete $args{timeout} || 30;

	my $url = $self->build_url($endpoint, %$params);

	$log->debug("Sync call: $url") if $log->is_debug;

	$self->{_ua}->timeout($timeout);

	my $response = $self->{_ua}->get($url);

	unless ($response->is_success) {
		my $code = $response->code;
		$log->error("HTTP error $code calling $endpoint: " . $response->status_line);
		return ('error', "HTTP error $code: " . $response->status_line);
	}

	my $content = $response->decoded_content;

	my ($status, $data) = $self->parse_response($content);
	return ($status, $data);
}

# ---------------------------------------------------------------------------
# Ping (blocking)
# ---------------------------------------------------------------------------
sub ping {
	my $self = shift;
	my ($status, $data) = $self->call(endpoint => 'ping');

	if ($status eq 'ok') {
		return {
			version       => $data->{version}       || 'unknown',
			type          => $data->{type}          || 'subsonic',
			serverVersion => $data->{serverVersion} || 'unknown',
			openSubsonic  => $data->{openSubsonic}  || JSON::XS::false,
		};
	}
	return undef;
}

# ---------------------------------------------------------------------------
# getAlbumList2 (blocking) — for importer
# ---------------------------------------------------------------------------
sub get_album_list {
	my ($self, $type, %args) = @_;
	my $size   = $args{size}   || 50;
	my $offset = $args{offset} || 0;

	my %params = ( type => $type, size => $size, offset => $offset );
	$params{genre}    = $args{genre}    if $args{genre};
	$params{fromYear} = $args{fromYear} if $args{fromYear};
	$params{toYear}   = $args{toYear}   if $args{toYear};

	my ($status, $data) = $self->call(
		endpoint => 'getAlbumList2',
		params   => \%params,
	);

	if ($status eq 'ok') {
		return $data->{albumList2} || $data->{albumList} || [];
	}
	return [];
}

# ---------------------------------------------------------------------------
# getAlbum (blocking)
# ---------------------------------------------------------------------------
sub get_album {
	my ($self, $id) = @_;
	my ($status, $data) = $self->call(
		endpoint => 'getAlbum',
		params   => { id => $id },
	);
	if ($status eq 'ok') {
		return $data->{album};
	}
	return undef;
}

# ---------------------------------------------------------------------------
# getArtists (blocking)
# ---------------------------------------------------------------------------
sub get_artists {
	my $self = shift;
	my ($status, $data) = $self->call(endpoint => 'getArtists');
	if ($status eq 'ok') {
		return $data->{artists};
	}
	return undef;
}

# ---------------------------------------------------------------------------
# getCoverArt — fetch cover art binary data
# ---------------------------------------------------------------------------
sub get_cover_art {
	my ($self, $cover_art_id, $size) = @_;
	$size ||= 300;

	my $url = $self->cover_art_url($cover_art_id, $size);
	my $response = $self->{_ua}->get($url);

	if ($response->is_success) {
		return $response->decoded_content;
	}
	return undef;
}

# ---------------------------------------------------------------------------
# Stream a track — get raw audio data
# ---------------------------------------------------------------------------
sub stream_track {
	my ($self, $track_id, %opts) = @_;

	my $url = $self->build_url('stream', id => $track_id,
		($opts{maxBitRate} ? (maxBitRate => $opts{maxBitRate}) : ()),
		($opts{format}     ? (format     => $opts{format})     : ()),
	);

	my $response = $self->{_ua}->get($url);

	if ($response->is_success) {
		return {
			content      => $response->decoded_content,
			content_type => $response->header('Content-Type'),
			duration     => $response->header('X-Content-Duration'),
			length       => $response->header('Content-Length'),
		};
	}
	return undef;
}

# ---------------------------------------------------------------------------
# scrobble (blocking)
# ---------------------------------------------------------------------------
sub scrobble {
	my ($self, $id, %args) = @_;
	my $submission = $args{submission} || 'true';

	my %params = ( id => $id, submission => $submission );
	$params{time} = $args{time} if $args{time};

	my ($status, $data) = $self->call(
		endpoint => 'scrobble',
		params   => \%params,
	);

	return $status eq 'ok';
}

1;
