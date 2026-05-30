package Plugins::GlowSonic::ProtocolHandler;

# Custom protocol handler for GlowSonic URLs.
# - glows://<track_id> is an individual audio track. new() delegates to LMS's
#   built-in HTTP/HTTPS handler with the real Subsonic /rest/stream URL.
# - glowsonic://playlist/<id> and glowsonic://album/<id> are playable
#   container URLs used by favorites/presets; explodePlaylist expands them.
# The metadata methods (getMetadataFor, getFormatForURL) provide track info.
#
# glows:// URL format:
#   glows://<track_id>?server=...&apiversion=...&user=...&pass=...
#     &title=...&artist=...&album=...&coverart=...&duration=...&bitrate=...
#     &suffix=...&contentType=...&maxBitRate=...&format=...

use strict;
use warnings;

use Slim::Player::ProtocolHandlers;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Plugins::GlowSonic::API::Async;
use URI::Escape ();

my $log = Slim::Utils::Log::logger('plugin.glowsonic');
my $prefs = preferences('plugin.glowsonic');

$log->debug("GlowSonic ProtocolHandler.pm loaded") if $log->is_debug;

sub register {
	my $class = shift;
	Slim::Player::ProtocolHandlers->registerHandler(
		glows => 'Plugins::GlowSonic::ProtocolHandler',
	);
	Slim::Player::ProtocolHandlers->registerHandler(
		glowsonic => 'Plugins::GlowSonic::ProtocolHandler',
	);

	my $audio_handler = Slim::Player::ProtocolHandlers->handlerForURL('glows://registration-test');
	my $playlist_handler = Slim::Player::ProtocolHandlers->handlerForURL('glowsonic://playlist/registration-test');
	$log->info("GlowSonic protocol handlers registered; glows => " . ($audio_handler || 'undef') . ", glowsonic => " . ($playlist_handler || 'undef'));
}

# ---------------------------------------------------------------------------
# Constructor — LMS calls ProtocolHandler->new(\%args) in Song::open().
# We replace the glows:// URL with the real Subsonic stream URL and delegate
# to LMS's built-in HTTP/HTTPS handler for actual streaming.
# ---------------------------------------------------------------------------
sub new {
	my ($class, @args) = @_;

	# LMS 9 passes a hashref: { url => 'glows://...', song => ..., client => ... }
	if (ref $args[0] eq 'HASH') {
		my %http_args = %{ $args[0] };

		my $url = $http_args{url}
			|| eval { $http_args{song}->streamUrl }
			|| eval { $http_args{song}->track->url }
			|| '';

		if ($url =~ /^glows:/) {
			my $stream_url = $class->_stream_url_from_glows($url);
			my ($track_id) = $class->parse_url($url);
			my $delegate = $class->_delegate_handler_for_url($stream_url);

			$http_args{url} = $stream_url;
			eval { $http_args{song}->streamUrl($stream_url); } if $http_args{song};

			$log->debug("GlowSonic new(): track=$track_id stream=" . $class->_redact_url($stream_url) . " delegate=" . ($delegate || 'undef')) if $log->is_debug;
			my $sock = $delegate ? $delegate->new(\%http_args) : undef;
			$log->debug("GlowSonic new(): delegate returned " . ($sock ? ref($sock) : 'undef')) if $log->is_debug;

			return $sock;
		}

		my $delegate = $class->_delegate_handler_for_url($url);
		return $delegate ? $delegate->new(\%http_args) : undef;
	}

	# Fallback: raw URL string
	my $url = $args[-1] || '';
	if (!ref($url) && $url =~ /^glows:/) {
		my $stream_url = $class->_stream_url_from_glows($url);
		my ($track_id) = $class->parse_url($url);
		my $delegate = $class->_delegate_handler_for_url($stream_url);
		$log->debug("GlowSonic new(): raw track=$track_id stream=" . $class->_redact_url($stream_url) . " delegate=" . ($delegate || 'undef')) if $log->is_debug;

		$args[-1] = $stream_url;
		my $sock = $delegate ? $delegate->new(@args) : undef;
		$log->debug("GlowSonic new(): raw delegate returned " . ($sock ? ref($sock) : 'undef')) if $log->is_debug;
		return $sock;
	}

	my $delegate = $class->_delegate_handler_for_url($url);
	return $delegate ? $delegate->new(@args) : undef;
}

sub _delegate_handler_for_url {
	my ($class, $stream_url) = @_;

	return undef unless $stream_url && $stream_url =~ m{^https?://}i;

	# Let LMS choose and load the correct built-in protocol class.  This is
	# critical for Navidrome HTTPS URLs: HTTP.pm cannot open TLS sockets, while
	# HTTPS.pm inherits HTTP behavior and adds SSL connection handling.
	return Slim::Player::ProtocolHandlers->handlerForURL($stream_url);
}

sub _redact_url {
	my ($class, $url) = @_;
	return '' unless defined $url;

	$url =~ s/([?&](?:p|pass|t|s)=)[^&]*/$1REDACTED/gi;
	return $url;
}

# ---------------------------------------------------------------------------
# Build the real Subsonic /rest/stream HTTP URL from glows:// params
# ---------------------------------------------------------------------------
sub _stream_url_from_glows {
	my ($class, $url) = @_;

	my ($track_id, $params) = $class->parse_url($url);

	my $server_url = $params->{server} || '';
	$server_url =~ s{/+$}{};

	my $stream_url = "$server_url/rest/stream?"
		. 'id=' . URI::Escape::uri_escape_utf8($track_id)
		. '&v=' . URI::Escape::uri_escape_utf8($params->{apiversion} || '1.16.1')
		. '&c=GlowSonic'
		. '&u=' . URI::Escape::uri_escape_utf8($params->{user} || '')
		. '&p=' . URI::Escape::uri_escape_utf8($params->{pass} || '');

	$stream_url .= '&maxBitRate=' . URI::Escape::uri_escape_utf8($params->{maxBitRate})
		if $params->{maxBitRate};

	$stream_url .= '&format=' . URI::Escape::uri_escape_utf8($params->{format})
		if $params->{format};

	return $stream_url;
}

# ---------------------------------------------------------------------------
# Protocol handler API — always remote, never direct-playable.
# LMS must go through new()+HTTP/HTTPS streaming.
# ---------------------------------------------------------------------------
sub isRemote { 1 }
sub canDirectStream { return 0; }
sub canDirectStreamSong { return 0; }

# ---------------------------------------------------------------------------
# Expand glowsonic://playlist/<id> or glowsonic://album/<id> preset/favorite
# container URLs into a real OPML playlist of glows:// audio items.
# ---------------------------------------------------------------------------
sub explodePlaylist {
	my ($class, $client, $url, $cb) = @_;

	my ($container_type, $container_id) = $class->_parse_container_url($url);
	unless ($container_type && $container_id) {
		$log->error("GlowSonic explodePlaylist(): unsupported URL $url");
		return $cb->({ type => 'opml', title => 'GlowSonic', items => [] });
	}

	my $api = $class->_api_client_from_prefs;
	my $success_cb = sub {
		my $container = shift || {};
		my $entries = $container_type eq 'album'
			? ($container->{song}  || [])
			: ($container->{entry} || []);

		my @items = map { $class->_audio_item_from_entry($api, $_, $container) } @$entries;

		$log->debug("GlowSonic explodePlaylist(): $container_type/$container_id returned " . scalar(@items) . " tracks") if $log->is_debug;

		$cb->({
			type  => 'opml',
			title => $container->{name} || $container->{title} || 'GlowSonic',
			items => \@items,
		});
	};

	my $error_cb = sub {
		my ($error) = @_;
		$log->error("GlowSonic explodePlaylist(): failed loading $container_type/$container_id: " . ($error || 'unknown error'));
		$cb->({ type => 'opml', title => 'GlowSonic', items => [] });
	};

	if ($container_type eq 'album') {
		return $api->get_album($container_id, success_cb => $success_cb, error_cb => $error_cb);
	}

	return $api->get_playlist($container_id, success_cb => $success_cb, error_cb => $error_cb);
}

sub _parse_container_url {
	my ($class, $url) = @_;

	my ($type, $id) = $url =~ m{^glowsonic://(playlist|album)/([^?]+)}i;
	return unless $type && defined $id;

	return (lc($type), URI::Escape::uri_unescape($id));
}

sub _api_client_from_prefs {
	return Plugins::GlowSonic::API::Async->new(
		server_url  => $prefs->get('server_url')  || '',
		username    => $prefs->get('username')    || '',
		password    => $prefs->get('password')    || '',
		api_version => $prefs->get('api_version') || '1.16.1',
		auth_type   => $prefs->get('auth_type')   || 'token',
	);
}

sub _audio_item_from_entry {
	my ($class, $api, $entry, $container) = @_;

	my $coverart = $entry->{coverArt} || $entry->{albumId} || $container->{coverArt};
	my $album = $entry->{album} || $container->{name} || $container->{title} || '';
	my $stream_url = $api->stream_url($entry->{id},
		maxBitRate  => $prefs->get('transcode_bitrate') || undef,
		format      => $prefs->get('transcode_format') || undef,
		title       => $entry->{title},
		artist      => $entry->{artist},
		album       => $album,
		coverart    => $coverart,
		duration    => $entry->{duration},
		bitrate     => $entry->{bitRate},
		suffix      => $entry->{suffix},
		contentType => $entry->{contentType},
	);

	my (undef, $params) = $class->parse_url($stream_url);
	my $cover = $class->_cover_url($params);

	return {
		name  => $entry->{title} || 'Unknown',
		type  => 'audio',
		url   => $stream_url,
		image => $cover,
		cover => $cover,
		title  => $entry->{title} || '',
		artist => $entry->{artist} || '',
		album  => $album,
		duration => $entry->{duration},
		secs     => $entry->{duration},
		bitrate  => $entry->{bitRate},
		content_type => $entry->{contentType},
	};
}

# ---------------------------------------------------------------------------
# Return the audio format so LMS knows which decoder to use.
# Considers transcoding: if format=mp3 was requested, the actual stream is MP3.
# LMS uses 'flc' internally for FLAC.
# ---------------------------------------------------------------------------
sub getFormatForURL {
	my ($class, @args) = @_;
	my $url = $args[-1];

	my ($track_id, $params) = $class->parse_url($url);

	my $fmt = lc($params->{format} || $params->{suffix} || 'mp3');
	$fmt = 'flc' if $fmt eq 'flac';

	return $fmt;
}

# ---------------------------------------------------------------------------
# getNextTrack — LMS calls this before opening the stream.
# ---------------------------------------------------------------------------
sub getNextTrack {
	my ($class, $song, $success_cb, $error_cb) = @_;

	my $url = $song->track->url;
	my ($track_id, $params) = $class->parse_url($url);

	my $stream_url = $class->_stream_url_from_glows($url);
	my $fmt = $class->getFormatForURL($url);

	$log->debug("GlowSonic getNextTrack(): track=$track_id fmt=$fmt stream=" . $class->_redact_url($stream_url)) if $log->is_debug;
	eval { $song->streamUrl($stream_url); };

	if ($params->{duration} && $params->{duration} =~ /^\d+(?:\.\d+)?$/) {
		eval { $song->duration($params->{duration} + 0); };
		eval { $song->track->duration($params->{duration} + 0); };
	}

	eval { $song->track->content_type($fmt); };

	$success_cb->();
}

# ---------------------------------------------------------------------------
# Called by LMS to get now-playing metadata (title, artist, album, etc.)
# ---------------------------------------------------------------------------
sub getMetadataFor {
	my ($class, $client, $url) = @_;

	my ($track_id, $params) = $class->parse_url($url);

	my $duration = $params->{duration};
	$duration = 0 unless defined $duration && $duration =~ /^\d+(?:\.\d+)?$/;

	my $cover = $class->_cover_url($params);

	return {
		title    => $params->{title}  || 'Unknown',
		artist   => $params->{artist} || '',
		album    => $params->{album}  || '',
		duration => $duration,
		secs     => $duration,
		bitrate  => $params->{bitrate},
		type     => $class->getFormatForURL($url),
		cover    => $cover,
		icon     => $cover,
		content_type => $params->{contentType},
	};
}

# ---------------------------------------------------------------------------
# Parse glows:// URL into (track_id, \%params)
# ---------------------------------------------------------------------------
sub parse_url {
	my ($class, $url) = @_;

	my ($track_id, $query) = $url =~ m{^glows?://([^?]+)(?:\?(.*))?$};
	$track_id = URI::Escape::uri_unescape($track_id || '');

	my %params;
	if ($query) {
		for my $pair (split /&/, $query) {
			my ($k, $v) = split /=/, $pair, 2;
			if (defined $k) {
				$params{$k} = URI::Escape::uri_unescape($v // '');
			}
		}
	}
	return ($track_id, \%params);
}

# ---------------------------------------------------------------------------
# Build cover art URL from params, stripping Navidrome prefix/suffix.
# ---------------------------------------------------------------------------
sub _cover_url {
	my ($class, $params) = @_;

	my $cover_art_id = $params->{coverart};
	return '' unless $cover_art_id;

	my $id = Plugins::GlowSonic::API::normalize_cover_art_id($cover_art_id);
	return '' unless $id;

	my $server_url = $params->{server} || '';
	$server_url =~ s{/+$}{};

	return "$server_url/rest/getCoverArt?"
		. 'id='   . URI::Escape::uri_escape_utf8($id)
		. '&size=300'
		. '&v='   . URI::Escape::uri_escape_utf8($params->{apiversion} || '1.16.1')
		. '&c=GlowSonic'
		. '&u='   . URI::Escape::uri_escape_utf8($params->{user} || '')
		. '&p='   . URI::Escape::uri_escape_utf8($params->{pass} || '');
}

1;
