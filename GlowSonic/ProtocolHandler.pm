package Plugins::GlowSonic::ProtocolHandler;

# Custom protocol handler for GlowSonic URLs.
# - glows://<track_id> is an individual audio track. new() delegates to LMS's
#   built-in HTTP/HTTPS handler with the real Subsonic /rest/stream URL.
# - glowsonic://<container>/<id> URLs are stable, playable container URLs
#   used by menu play actions and favorites; explodePlaylist expands them.
# The metadata methods (getMetadataFor, getFormatForURL) provide track info.
#
# glows:// URL format:
#   glows://<track_id>?title=...&artist=...&album=...&coverart=...
#     &duration=...&bitrate=...&suffix=...&contentType=...
#     &maxBitRate=...&format=...
# Credentials are intentionally not stored in playable URLs; current LMS prefs
# are used when the stream is opened.

use strict;
use warnings;

use Slim::Player::ProtocolHandlers;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Plugins::GlowSonic::API::Async;
use Encode ();
use List::Util qw(shuffle);
use URI::Escape ();

my $log = Slim::Utils::Log::logger('plugin.glowsonic');
my $prefs = preferences('plugin.glowsonic');

# Reuse one API client for a given configuration. Creating a client generates a
# new Subsonic auth salt, which used to make every cover-art URL unique. That
# defeated LMS's image cache and could repeatedly exhaust memory on artwork-
# capable players such as Squeezebox Radio.
my ($prefs_api, $prefs_api_signature);

$log->debug("GlowSonic ProtocolHandler.pm loaded") if $log->is_debug;

sub register {
	my $class = shift;
	Slim::Player::ProtocolHandlers->registerHandler(
		glows => 'Plugins::GlowSonic::AudioProtocolHandler',
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

			unless ($stream_url && $delegate) {
				$log->error("GlowSonic new(): cannot resolve stream for track " . ($track_id || 'unknown'));
				return undef;
			}

			$http_args{url} = $stream_url;
			eval { $http_args{song}->streamUrl($stream_url); } if $http_args{song};

			$log->debug("GlowSonic new(): track=$track_id stream=" . $class->_redact_url($stream_url) . " delegate=" . ($delegate || 'undef')) if $log->is_debug;
			my $sock = $delegate->new(\%http_args);
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
		unless ($stream_url && $delegate) {
			$log->error("GlowSonic new(): cannot resolve raw stream for track " . ($track_id || 'unknown'));
			return undef;
		}
		$log->debug("GlowSonic new(): raw track=$track_id stream=" . $class->_redact_url($stream_url) . " delegate=" . ($delegate || 'undef')) if $log->is_debug;

		$args[-1] = $stream_url;
		my $sock = $delegate->new(@args);
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
	return undef unless defined $track_id && length $track_id;

	my $api = $class->_api_client_from_prefs($params);
	return undef unless $api && $api->is_configured;

	return $api->stream_http_url($track_id,
		maxBitRate => $params->{maxBitRate},
		format     => $params->{format},
	);
}

# ---------------------------------------------------------------------------
# Protocol handler API — always remote, never direct-playable.
# LMS must go through new()+HTTP/HTTPS streaming.
# ---------------------------------------------------------------------------
sub isRemote { 1 }
sub canDirectStream { return 0; }
sub canDirectStreamSong { return 0; }

# ---------------------------------------------------------------------------
# Expand stable glowsonic:// container URLs into OPML playlists of glows://
# audio items. A scalar playback URL is important here: Jive players cannot
# serialize the Perl callbacks used for browsing when Play is pressed.
# ---------------------------------------------------------------------------
sub explodePlaylist {
	my ($class, $client, $url, $cb) = @_;

	if ($url && $url =~ /^glows:/i) {
		$log->warn("GlowSonic explodePlaylist(): ignoring audio URL routed as playlist: $url");
		return $cb->($class->_single_track_opml($url));
	}

	my ($container_type, $container_id) = $class->_parse_container_url($url);
	unless ($container_type && $container_id) {
		$log->error("GlowSonic explodePlaylist(): unsupported URL " . ($url || ''));
		return $cb->($class->_error_opml('Unsupported GlowSonic favorite URL'));
	}

	my $api = $class->_api_client_from_prefs;
	unless ($api && $api->is_configured) {
		return $cb->($class->_error_opml('GlowSonic is not configured'));
	}

	my $error_cb = sub {
		my ($error) = @_;
		$error ||= 'unknown error';
		$log->error("GlowSonic explodePlaylist(): failed loading $container_type/$container_id: $error");
		$cb->($class->_error_opml("Could not load GlowSonic playlist: $error"));
	};

	if ($container_type eq 'album' || $container_type eq 'playlist') {
		my $success_cb = sub {
			my $container = $api->as_hash(shift);
			my $entries = $container_type eq 'album'
				? $api->as_array($container->{song})
				: $api->as_array($container->{entry});
			$class->_finish_explode($api, $cb, $container_type, $container_id, $container, $entries);
		};

		return $container_type eq 'album'
			? $api->get_album($container_id, success_cb => $success_cb, error_cb => $error_cb)
			: $api->get_playlist($container_id, success_cb => $success_cb, error_cb => $error_cb);
	}

	if ($container_type eq 'artist') {
		return $class->_explode_artist($api, $container_id, $cb, $error_cb);
	}

	if ($container_type eq 'artist-radio') {
		return $api->get_similar_songs($container_id,
			count => 100,
			success_cb => sub {
				$class->_finish_explode($api, $cb, $container_type, $container_id,
					{ name => 'Artist Radio' }, $api->as_array(shift));
			},
			error_cb => $error_cb,
		);
	}

	return $api->get_songs_by_genre($container_id,
		count => 100,
		success_cb => sub {
			$class->_finish_explode($api, $cb, $container_type, $container_id,
				{ name => $container_id }, $api->as_array(shift));
		},
		error_cb => $error_cb,
	);
}

sub _finish_explode {
	my ($class, $api, $cb, $container_type, $container_id, $container, $entries) = @_;
	$container = $api->as_hash($container);
	$entries   = $api->as_array($entries);

	my @items = grep { $_ } map { $class->_audio_item_from_entry($api, $_, $container) } @$entries;
	$log->debug("GlowSonic explodePlaylist(): $container_type/$container_id returned " . scalar(@items) . " tracks") if $log->is_debug;

	$cb->({
		type  => 'opml',
		title => $container->{name} || $container->{title} || 'GlowSonic',
		items => \@items,
	});
}

sub _explode_artist {
	my ($class, $api, $artist_id, $cb, $error_cb) = @_;

	$api->get_artist($artist_id,
		success_cb => sub {
			my $artist = $api->as_hash(shift);
			my @albums = grep { ref $_ eq 'HASH' && defined $_->{id} && length $_->{id} }
				@{ $api->as_array($artist->{album}) };
			my (@songs, %seen);
			my $first_error;
			my $fetch_next;

			$fetch_next = sub {
				my $album_ref = shift @albums;
				unless ($album_ref) {
					return $error_cb->($first_error) if !@songs && $first_error;
					my @shuffled = shuffle @songs;
					return $class->_finish_explode($api, $cb, 'artist', $artist_id, $artist, \@shuffled);
				}

				$api->get_album($album_ref->{id},
					success_cb => sub {
						my $album = $api->as_hash(shift);
						for my $entry (@{ $api->as_array($album->{song}) }) {
							next unless ref $entry eq 'HASH' && defined $entry->{id} && length $entry->{id};
							next if $seen{ $entry->{id} }++;
							my %song = %$entry;
							$song{album}    ||= $album->{name} || $album_ref->{name};
							$song{albumId}  ||= $album->{id} || $album_ref->{id};
							$song{coverArt} ||= $album->{coverArt} || $album_ref->{coverArt};
							push @songs, \%song;
						}
						$fetch_next->();
					},
					error_cb => sub {
						my ($error) = @_;
						$first_error ||= $error || 'Could not load artist album';
						$fetch_next->();
					},
				);
			};

			$fetch_next->();
		},
		error_cb => $error_cb,
	);
}

sub _parse_container_url {
	my ($class, $url) = @_;

	my ($type, $id) = ($url || '') =~ m{^glowsonic://(playlist|album|artist-radio|artist|genre)/([^?]+)}i;
	return unless $type && defined $id;

	return (lc($type), $class->_uri_unescape_utf8($id));
}

sub _api_client_from_prefs {
	my ($class, $legacy_params) = @_;
	$legacy_params ||= {};

	# Legacy glows:// URLs from older versions may still contain connection
	# params. Prefer current prefs, but keep them as a fallback for old queues.
	my %config = (
		server_url  => $prefs->get('server_url')  || $legacy_params->{server}     || '',
		username    => $prefs->get('username')    || $legacy_params->{user}       || '',
		password    => $prefs->get('password')    || $legacy_params->{pass}       || '',
		api_version => $prefs->get('api_version') || $legacy_params->{apiversion} || '1.16.1',
		auth_type   => $prefs->get('auth_type')   || 'token',
	);

	# Length-prefix each value so different configurations cannot produce the
	# same cache key through delimiter characters in credentials or URLs.
	my $signature = join '', map {
		my $value = defined $config{$_} ? $config{$_} : '';
		length($value) . ':' . $value;
	} qw(server_url username password api_version auth_type);

	if (!$prefs_api || !defined $prefs_api_signature || $signature ne $prefs_api_signature) {
		$prefs_api = Plugins::GlowSonic::API::Async->new(%config);
		$prefs_api_signature = $signature;
	}

	return $prefs_api;
}

sub _error_opml {
	my ($class, $message) = @_;
	return {
		type  => 'opml',
		title => 'GlowSonic',
		items => [ { name => $message || 'GlowSonic error', type => 'text' } ],
	};
}

sub _single_track_opml {
	my ($class, $url) = @_;
	my (undef, $params) = $class->parse_url($url);
	my $duration = $params->{duration};
	$duration = 0 unless defined $duration && $duration =~ /^\d+(?:\.\d+)?$/;
	my $cover = $class->_cover_url($params);

	return {
		type  => 'opml',
		title => $params->{title} || 'GlowSonic',
		items => [ {
			name  => $params->{title} || 'Unknown',
			type  => 'audio',
			url   => $url,
			image => $cover,
			cover => $cover,
			title  => $params->{title}  || '',
			artist => $params->{artist} || '',
			album  => $params->{album}  || '',
			duration => $duration,
			secs     => $duration,
			bitrate  => $params->{bitrate},
			content_type => $params->{contentType},
		} ],
	};
}

sub _audio_item_from_entry {
	my ($class, $api, $entry, $container) = @_;

	return undef unless ref($entry) eq 'HASH' && defined $entry->{id};

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
	return undef unless $stream_url;

	my (undef, $params) = $class->parse_url($stream_url || '');
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

	my $url = eval { $song->track->url } || '';
	my ($track_id, $params) = $class->parse_url($url);

	my $stream_url = $class->_stream_url_from_glows($url);
	my $fmt = $class->getFormatForURL($url);

	unless ($stream_url) {
		my $err = 'Unable to resolve GlowSonic stream URL';
		$log->error("$err for track " . ($track_id || 'unknown'));
		return $error_cb ? $error_cb->($err) : undef;
	}

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
	$track_id = $class->_uri_unescape_utf8($track_id || '');

	my %params;
	if ($query) {
		for my $pair (split /&/, $query) {
			my ($k, $v) = split /=/, $pair, 2;
			if (defined $k) {
				$params{ $class->_uri_unescape_utf8($k) } = $class->_uri_unescape_utf8($v // '');
			}
		}
	}
	return ($track_id, \%params);
}

sub _uri_unescape_utf8 {
	my ($class, $value) = @_;
	$value = '' unless defined $value;

	my $bytes = URI::Escape::uri_unescape($value);
	my $decoded = eval { Encode::decode('UTF-8', $bytes, Encode::FB_CROAK()) };
	return defined $decoded ? $decoded : $bytes;
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

	my $api = $class->_api_client_from_prefs($params);
	return '' unless $api && $api->is_configured;

	# The Radio has only 64 MB RAM. Never feed its Now Playing view artwork
	# larger than the historical 300 px default, but honor smaller configured
	# sizes for especially memory-constrained setups.
	my $size = $prefs->get('artwork_size') || 300;
	$size = 300 unless $size =~ /^\d+$/ && $size > 0;
	$size = 300 if $size > 300;

	return $api->cover_art_url($id, $size) || '';
}

1;
