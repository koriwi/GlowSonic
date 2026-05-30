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
	$self->{server_url} =~ s{/+$}{};   # strip trailing slashes

	return bless($self, $class);
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
	$self->{server_url}  =~ s{/+$}{};
	# Reset cached auth
	$self->{salt}  = undef;
	$self->{token} = undef;
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
# Build query parameters with auth
# ---------------------------------------------------------------------------
sub _build_params {
	my ($self, %extra) = @_;

	my %params = (
		v => $self->{api_version},
		c => 'GlowSonic',
		f => 'json',
		%extra,
	);

	if ($self->{auth_type} eq 'token' && $self->{token} && $self->{salt}) {
		$params{u} = $self->{username};
		$params{t} = $self->{token};
		$params{s} = $self->{salt};
	} elsif ($self->{auth_type} eq 'password') {
		$params{u} = $self->{username};
		$params{p} = $self->{password};
	} else {
		# Fallback: no auth params yet; caller should ping first
		$params{u} = $self->{username};
		$params{p} = $self->{password};
	}

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
# Build full URL for an endpoint
# ---------------------------------------------------------------------------
sub build_url {
	my ($self, $endpoint, %extra) = @_;
	my $params = $self->_build_params(%extra);
	my $qs     = $self->_encode_params($params);
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
# Build a glows:// stream URL that the ProtocolHandler will resolve.
# The handler parses the metadata, builds the real HTTP stream URL, and
# sets track metadata (title/artist/album/duration) on the LMS song object.
# ---------------------------------------------------------------------------
sub stream_url {
	my ($self, $track_id, %opts) = @_;

	# Connection params (needed by ProtocolHandler to build the real URL)
	my %params = (
		server     => $self->{server_url},
		apiversion => $self->{api_version},
		user       => $self->{username},
		pass       => $self->{password},
	);

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
# Helper: build a cover art URL
# IMPORTANT: getCoverArt must NOT use f=json because that makes Subsonic
# return base64-encoded image data wrapped in JSON instead of raw binary.
# We need raw binary image bytes for LMS to display correctly.
#
# Always use password auth for cover art URLs (more reliable for
# browser-side image fetching since token may not be set yet).
# ---------------------------------------------------------------------------
sub cover_art_url {
	my ($self, $cover_art_id, $size) = @_;
	$cover_art_id = $self->normalize_cover_art_id($cover_art_id);
	return undef unless $cover_art_id;
	$size ||= 300;

	# Build params WITHOUT f=json so we get raw binary image
	my %params = (
		v     => $self->{api_version},
		c     => 'GlowSonic',
		id    => $cover_art_id,
		size  => $size,
		# Always use password auth for image URLs (browser fetches directly)
		u     => $self->{username},
		p     => $self->{password},
	);

	my $qs = $self->_encode_params(\%params);
	return $self->_rest_url . '/getCoverArt?' . $qs;
}

# ---------------------------------------------------------------------------
# Helper: build favorites_url for OPML passthrough
# ---------------------------------------------------------------------------
sub favorites_url {
	my ($self, $type, $id) = @_;
	return "glowsonic://$type/$id";
}

1;
