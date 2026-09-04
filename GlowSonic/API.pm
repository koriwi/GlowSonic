package Plugins::GlowSonic::API;

# Base class for Subsonic/OpenSubsonic API communication
# Subclasses: API::Async (non-blocking via SimpleAsyncHTTP), API::Sync (blocking via LWP)
# All IDs from Navidrome are strings (MD5 hashes) — never integer-cast

use strict;
use warnings;

use Digest::MD5 qw(md5_hex);
use JSON::XS;
# Use fully qualified calls for URI::Escape to avoid import issues
use URI::Escape ();
use Scalar::Util qw(looks_like_number);
use Time::HiRes qw(time);

# ---------------------------------------------------------------------------
# Constructor
# ---------------------------------------------------------------------------
sub new {
	my ($class, %opts) = @_;

	my $self = {
		server_url  => $opts{server_url}  || '',
		username    => $opts{username}    || '',
		password    => $opts{password}    || '',
		api_version => $opts{api_version} || '1.16.1',
		auth_type   => $opts{auth_type}   || 'token',   # 'token' or 'password'
		salt        => undef,
		token       => undef,
	};
	bless($self, $class);
	$self->_normalize_config;

	return $self;
}

# ---------------------------------------------------------------------------
# Reconfigure on the fly
# ---------------------------------------------------------------------------
sub configure {
	my ($self, %opts) = @_;
	$self->{server_url}  = $opts{server_url}  if defined $opts{server_url};
	$self->{username}    = $opts{username}    if defined $opts{username};
	$self->{password}    = $opts{password}    if defined $opts{password};
	$self->{api_version} = $opts{api_version} if defined $opts{api_version};
	$self->{auth_type}   = $opts{auth_type}   if defined $opts{auth_type};
	$self->_normalize_config;
	# Reset cached auth
	$self->{salt}  = undef;
	$self->{token} = undef;
}

# ---------------------------------------------------------------------------
# Normalize user-provided configuration values.
# ---------------------------------------------------------------------------
sub _normalize_config {
	my $self = shift;

	for my $key (qw(server_url username api_version auth_type)) {
		next unless defined $self->{$key};
		$self->{$key} =~ s/^\s+|\s+$//g;
	}

	$self->{server_url} =~ s{/+$}{} if defined $self->{server_url};
	$self->{auth_type} = 'token' unless $self->{auth_type} && $self->{auth_type} eq 'password';
}

# ---------------------------------------------------------------------------
# Basic config sanity check for code paths that need a reachable server.
# ---------------------------------------------------------------------------
sub is_configured {
	my $self = shift;
	return $self->{server_url} && $self->{server_url} =~ m{^https?://}i && length($self->{username} || '');
}

# ---------------------------------------------------------------------------
# Build the REST API base URL
# ---------------------------------------------------------------------------
sub _rest_url {
	my $self = shift;
	return $self->{server_url} . '/rest';
}

# ---------------------------------------------------------------------------
# Compute authentication token: md5(password + salt)
# ---------------------------------------------------------------------------
sub _compute_token {
	my ($self, $salt) = @_;
	# Navidrome: token = md5(password + salt)
	return md5_hex($self->{password} . $salt);
}

# ---------------------------------------------------------------------------
# Auth params. For token auth the Subsonic salt is generated client-side.
# ---------------------------------------------------------------------------
sub auth_params {
	my $self = shift;

	if (($self->{auth_type} || 'token') eq 'password') {
		return (
			u => $self->{username},
			p => $self->{password},
		);
	}

	unless ($self->{salt} && $self->{token}) {
		$self->{salt}  = md5_hex(join(':', time, rand(), $$, $self->{username} || ''));
		$self->{token} = $self->_compute_token($self->{salt});
	}

	return (
		u => $self->{username},
		t => $self->{token},
		s => $self->{salt},
	);
}

# ---------------------------------------------------------------------------
# Build query parameters with auth
# ---------------------------------------------------------------------------
sub _build_params {
	my ($self, %extra) = @_;

	my %params = (
		v => $self->{api_version},
		c => 'GlowSonic',
		f => 'json',
		%extra,
		$self->auth_params,
	);

	return \%params;
}

# ---------------------------------------------------------------------------
# Encode params into URL query string
# ---------------------------------------------------------------------------
sub _encode_params {
	my ($self, $params) = @_;
	my @parts;
	for my $key (sort keys %$params) {
		my $val = $params->{$key};
		next unless defined $val;
		push @parts, $key . '=' . URI::Escape::uri_escape_utf8($val);
	}
	return join('&', @parts);
}

# ---------------------------------------------------------------------------
# Build full JSON API URL for an endpoint
# ---------------------------------------------------------------------------
sub build_url {
	my ($self, $endpoint, %extra) = @_;
	my $params = $self->_build_params(%extra);
	my $qs     = $self->_encode_params($params);
	return $self->_rest_url . '/' . $endpoint . '?' . $qs;
}

# ---------------------------------------------------------------------------
# Build full binary/non-JSON API URL for stream/getCoverArt endpoints.
# ---------------------------------------------------------------------------
sub build_binary_url {
	my ($self, $endpoint, %extra) = @_;
	my %params = (
		v => $self->{api_version},
		c => 'GlowSonic',
		%extra,
		$self->auth_params,
	);
	my $qs = $self->_encode_params(\%params);
	return $self->_rest_url . '/' . $endpoint . '?' . $qs;
}

# ---------------------------------------------------------------------------
# Parse the subsonic-response envelope
# Returns: (status, data_or_error, raw_json)
# ---------------------------------------------------------------------------
sub parse_response {
	my ($self, $json_text) = @_;

	return ('error', 'Empty response') unless defined $json_text && length $json_text;

	my $data;
	eval {
		$data = JSON::XS::decode_json($json_text);
	};
	if ($@) {
		return ('error', "JSON parse error: $@");
	}

	my $response = $data->{'subsonic-response'};
	unless ($response) {
		return ('error', 'Missing subsonic-response envelope');
	}

	my $status = $response->{status};
	if ($status && $status eq 'ok') {
		return ('ok', $response, $json_text);
	}

	# status == 'failed'
	my $error_msg = 'Unknown error';
	if ($response->{error}) {
		$error_msg = $response->{error}->{message} || 'Unknown error';
		if ($response->{error}->{code}) {
			$error_msg = "Error " . $response->{error}->{code} . ": $error_msg";
		}
	}
	return ('failed', $error_msg);
}

# ---------------------------------------------------------------------------
# Extract data payload from a successful response for a given key
# ---------------------------------------------------------------------------
sub extract_data {
	my ($self, $response, $key) = @_;
	# Navigate: subsonic-response -> {key}
	return $response->{$key};
}

# ---------------------------------------------------------------------------
# Helper: format duration (seconds) to mm:ss or hh:mm:ss
# ---------------------------------------------------------------------------
sub format_duration {
	my $seconds = shift;
	return '' unless defined $seconds && looks_like_number($seconds);
	my $h = int($seconds / 3600);
	my $m = int(($seconds % 3600) / 60);
	my $s = $seconds % 60;
	if ($h > 0) {
		return sprintf("%d:%02d:%02d", $h, $m, $s);
	}
	return sprintf("%d:%02d", $m, $s);
}

# ---------------------------------------------------------------------------
# Helper: safely get a value, using a default
# ---------------------------------------------------------------------------
sub safe_get {
	my ($hash, $key, $default) = @_;
	return $default unless ref($hash) eq 'HASH';
	my $val = $hash->{$key};
	return defined $val ? $val : $default;
}

# ---------------------------------------------------------------------------
# Helpers for tolerant response-shape handling across Subsonic servers.
# ---------------------------------------------------------------------------
sub as_hash {
	my ($self_or_value, $maybe_value) = @_;
	my $value = @_ > 1 ? $maybe_value : $self_or_value;
	return ref($value) eq 'HASH' ? $value : {};
}

sub as_array {
	my ($self_or_value, $maybe_value) = @_;
	my $value = @_ > 1 ? $maybe_value : $self_or_value;
	return [] unless defined $value;
	return $value if ref($value) eq 'ARRAY';
	return [ $value ] if ref($value) eq 'HASH';
	return [ $value ] unless ref($value);
	return [];
}

# ---------------------------------------------------------------------------
# Build a glows:// stream URL that the ProtocolHandler will resolve.
# The handler parses the metadata, builds the real HTTP stream URL, and
# sets track metadata (title/artist/album/duration) on the LMS song object.
# ---------------------------------------------------------------------------
sub stream_url {
	my ($self, $track_id, %opts) = @_;

	return undef unless defined $track_id && length $track_id;

	# Do not put credentials in glows:// URLs. The protocol handler resolves
	# streams from current LMS prefs when playback starts.
	my %params;

	# Transcode options
	$params{maxBitRate} = $opts{maxBitRate} if $opts{maxBitRate};
	$params{format}     = $opts{format}     if $opts{format};

	# Metadata (used by ProtocolHandler->getMetadataFor)
	$params{title}       = $opts{title}       if defined $opts{title};
	$params{artist}      = $opts{artist}      if defined $opts{artist};
	$params{album}       = $opts{album}       if defined $opts{album};
	$params{coverart}    = $opts{coverart}    if defined $opts{coverart};
	$params{duration}    = $opts{duration}    if defined $opts{duration};
	$params{bitrate}     = $opts{bitrate}     if defined $opts{bitrate};
	$params{suffix}      = $opts{suffix}      if defined $opts{suffix};
	$params{contentType} = $opts{contentType} if defined $opts{contentType};

	return 'glows://' . URI::Escape::uri_escape_utf8($track_id) . '?'
		. $self->_encode_params(\%params);
}

# ---------------------------------------------------------------------------
# Helper: normalize Navidrome coverArt IDs.
# Navidrome often returns IDs like al-{id}_{hash}, ar-{id}_0, mf-{id}_{hash};
# getCoverArt wants the base ID.
# ---------------------------------------------------------------------------
sub normalize_cover_art_id {
	my ($self_or_id, $maybe_id) = @_;
	my $id = defined $maybe_id ? $maybe_id : $self_or_id;
	return undef unless defined $id && length $id;

	$id =~ s/^[a-z]+-//;
	$id =~ s/_[^_]*$//;
	return $id;
}

# ---------------------------------------------------------------------------
# Helper: build the real Subsonic stream URL.
# ---------------------------------------------------------------------------
sub stream_http_url {
	my ($self, $track_id, %opts) = @_;
	return undef unless $self->is_configured && defined $track_id && length $track_id;

	my %params = ( id => $track_id );
	$params{maxBitRate} = $opts{maxBitRate} if $opts{maxBitRate};
	$params{format}     = $opts{format}     if $opts{format};

	return $self->build_binary_url('stream', %params);
}

# ---------------------------------------------------------------------------
# Helper: build a cover art URL
# IMPORTANT: getCoverArt must NOT use f=json because that makes Subsonic
# return base64-encoded image data wrapped in JSON instead of raw binary.
# We need raw binary image bytes for LMS to display correctly.
# ---------------------------------------------------------------------------
sub cover_art_url {
	my ($self, $cover_art_id, $size) = @_;
	return undef unless $self->is_configured;
	$cover_art_id = $self->normalize_cover_art_id($cover_art_id);
	return undef unless $cover_art_id;
	$size ||= 300;

	return $self->build_binary_url('getCoverArt', id => $cover_art_id, size => $size);
}

# ---------------------------------------------------------------------------
# Helper: build favorites_url for OPML passthrough
# ---------------------------------------------------------------------------
sub favorites_url {
	my ($self, $type, $id) = @_;
	return undef unless defined $type && length $type && defined $id && length $id;
	return 'glowsonic://' . URI::Escape::uri_escape_utf8($type) . '/'
		. URI::Escape::uri_escape_utf8($id);
}

1;
