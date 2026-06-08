package Plugins::GlowSonic::API::Async;

# Non-blocking Subsonic API client using Slim::Networking::SimpleAsyncHTTP
# All UI/browsing calls use this — LMS is single-threaded

use strict;
use warnings;
use base qw(Plugins::GlowSonic::API);

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Log;

my $log = Slim::Utils::Log::logger('plugin.glowsonic');

# ---------------------------------------------------------------------------
# Perform an async API call
# Args:
#   endpoint   => 'ping' (without .view suffix)
#   params     => { id => '...' }  (extra query params)
#   success_cb => sub { my ($data, $raw) = @_; ... }
#   error_cb   => sub { my ($error, $http_code) = @_; ... }
#   timeout    => 15 (optional, default 15)
# ---------------------------------------------------------------------------
sub call {
	my ($self, %args) = @_;

	my $endpoint   = delete $args{endpoint};
	my $params     = delete $args{params}     || {};
	my $success_cb = delete $args{success_cb} || sub {};
	my $error_cb   = delete $args{error_cb}   || sub {};
	my $timeout    = delete $args{timeout}    || 15;

	unless ($self->is_configured) {
		$error_cb->('GlowSonic server is not configured', 0);
		return;
	}

	# Build URL
	my $url = $self->build_url($endpoint, %$params);

	$log->debug("Async call: " . $self->_redact_url($url)) if $log->is_debug;

	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			# HTTP response handler
			my $http = shift;

			my $content = $http->content;
			my $code    = $http->code;

			# Handle non-200 HTTP codes
			unless ($code == 200) {
				if ($code == 401 || $code == 403) {
					# Auth failure → clear cached token, notify
					$self->{token} = undef;
					$self->{salt}  = undef;
					$error_cb->("Authentication failed", $code);
				} else {
					$error_cb->("HTTP error $code", $code);
				}
				return;
			}

			# Parse the subsonic-response envelope
			my ($status, $data) = $self->parse_response($content);

			if ($status eq 'ok') {
				my $ok = eval { $success_cb->($data); 1 };
				unless ($ok) {
					my $err = $@ || 'unknown callback error';
					$log->error("Error processing $endpoint response: $err");
					$error_cb->("Internal error processing API response", $code);
				}
			} elsif ($status eq 'failed') {
				$log->error("API error: $data");
				$error_cb->($data, $code);
			} else {
				$log->error("Parse error: $data");
				$error_cb->($data, $code);
			}
		},
		sub {
			# Network error handler
			my ($http, $error) = @_;
			$error ||= 'unknown error';
			$log->error("Network error calling $endpoint: $error");
			$error_cb->("Network error: $error", 0);
		},
		{
			timeout => $timeout,
		}
	)->get($url);
}

sub _redact_url {
	my ($self, $url) = @_;
	return '' unless defined $url;
	$url =~ s/([?&](?:p|pass|t|s)=)[^&]*/$1REDACTED/gi;
	return $url;
}

# ---------------------------------------------------------------------------
# Ping the server to verify connection
# ---------------------------------------------------------------------------
sub ping {
	my ($self, %args) = @_;

	my $success_cb = delete $args{success_cb};
	my $error_cb   = delete $args{error_cb};

	$self->call(
		endpoint => 'ping',
		success_cb => sub {
			my $data = shift;
			my $status = $data->{status} || 'ok';
			my $version = $data->{version} || 'unknown';
			my $type = $data->{type} || 'subsonic';
			my $server_version = $data->{serverVersion} || 'unknown';
			my $open_subsonic = $data->{openSubsonic} || JSON::XS::false;

			$log->info("Connected to $type v$server_version (API $version, OpenSubsonic: " . ($open_subsonic ? 'yes' : 'no') . ")");

			$success_cb->({
				version        => $version,
				type           => $type,
				serverVersion  => $server_version,
				openSubsonic   => $open_subsonic,
			}) if $success_cb;
		},
		error_cb => sub {
			my ($error, $code) = @_;
			$log->error("Ping failed: $error (code: $code)");
			$error_cb->($error, $code) if $error_cb;
		},
	);
}

# ---------------------------------------------------------------------------
# Verify authentication using the configured auth mode.
# ---------------------------------------------------------------------------
sub authenticate {
	my ($self, %args) = @_;

	my $success_cb = delete $args{success_cb};
	my $error_cb   = delete $args{error_cb};

	$self->ping(
		success_cb => sub {
			my $data = shift;
			$log->info("Authentication ping succeeded");
			$success_cb->($data) if $success_cb;
		},
		error_cb => sub {
			my ($error, $code) = @_;
			$self->{token} = undef;
			$self->{salt}  = undef;
			$error_cb->($error, $code) if $error_cb;
		},
	);
}

# ===========================================================================
# Browsing API methods (all async)
# ===========================================================================

# getArtists — list all artists
sub get_artists {
	my ($self, %args) = @_;
	my $success_cb = delete $args{success_cb};
	my $error_cb   = delete $args{error_cb};

	$self->call(
		endpoint   => 'getArtists',
		success_cb => sub {
			my $data = shift;
			$success_cb->($self->as_hash($data->{artists})) if $success_cb;
		},
		error_cb => $error_cb || sub {},
	);
}

# getArtist — get artist details + albums
sub get_artist {
	my ($self, $id, %args) = @_;
	my $success_cb = delete $args{success_cb};
	my $error_cb   = delete $args{error_cb};

	$self->call(
		endpoint   => 'getArtist',
		params     => { id => $id },
		success_cb => sub {
			my $data = shift;
			$success_cb->($self->as_hash($data->{artist})) if $success_cb;
		},
		error_cb => $error_cb || sub {},
	);
}

# getAlbum — get album details + songs
sub get_album {
	my ($self, $id, %args) = @_;
	my $success_cb = delete $args{success_cb};
	my $error_cb   = delete $args{error_cb};

	$self->call(
		endpoint   => 'getAlbum',
		params     => { id => $id },
		success_cb => sub {
			my $data = shift;
			$success_cb->($self->as_hash($data->{album})) if $success_cb;
		},
		error_cb => $error_cb || sub {},
	);
}

# getAlbumList2 — list albums by type (random, newest, frequent, recent, highest, alphabeticalByName, alphabeticalByArtist, starred, byYear, byGenre)
sub get_album_list {
	my ($self, $type, %args) = @_;
	my $success_cb = delete $args{success_cb};
	my $error_cb   = delete $args{error_cb};
	my $size       = delete $args{size} || 50;
	my $offset     = delete $args{offset} || 0;
	my $genre      = delete $args{genre};
	my $from_year  = delete $args{fromYear};
	my $to_year    = delete $args{toYear};

	my %params = (
		type   => $type,
		size   => $size,
		offset => $offset,
	);
	$params{genre}     = $genre     if $genre;
	$params{fromYear}  = $from_year  if $from_year;
	$params{toYear}    = $to_year    if $to_year;

	$self->call(
		endpoint   => 'getAlbumList2',
		params     => \%params,
		success_cb => sub {
			my $data = shift;
			my $album_list = $self->as_hash($data->{albumList2} || $data->{albumList});
			$success_cb->($self->as_array($album_list->{album})) if $success_cb;
		},
		error_cb => $error_cb || sub {},
	);
}

# getGenres — list all genres
sub get_genres {
	my ($self, %args) = @_;
	my $success_cb = delete $args{success_cb};
	my $error_cb   = delete $args{error_cb};

	$self->call(
		endpoint   => 'getGenres',
		success_cb => sub {
			my $data = shift;
			my $genres = $self->as_hash($data->{genres});
			$success_cb->($self->as_array($genres->{genre})) if $success_cb;
		},
		error_cb => $error_cb || sub {},
	);
}

# getPlaylists — list all playlists (optionally for a user)
sub get_playlists {
	my ($self, %args) = @_;
	my $success_cb = delete $args{success_cb};
	my $error_cb   = delete $args{error_cb};
	my $username   = delete $args{username};

	my %params;
	$params{username} = $username if $username;

	$self->call(
		endpoint   => 'getPlaylists',
		params     => \%params,
		success_cb => sub {
			my $data = shift;
			my $playlists = $self->as_hash($data->{playlists});
			$success_cb->($self->as_array($playlists->{playlist})) if $success_cb;
		},
		error_cb => $error_cb || sub {},
	);
}

# getPlaylist — get playlist details + entries
sub get_playlist {
	my ($self, $id, %args) = @_;
	my $success_cb = delete $args{success_cb};
	my $error_cb   = delete $args{error_cb};

	$self->call(
		endpoint   => 'getPlaylist',
		params     => { id => $id },
		success_cb => sub {
			my $data = shift;
			$success_cb->($self->as_hash($data->{playlist})) if $success_cb;
		},
		error_cb => $error_cb || sub {},
	);
}

# search3 — unified search
sub search {
	my ($self, $query, %args) = @_;
	my $success_cb   = delete $args{success_cb};
	my $error_cb     = delete $args{error_cb};
	my $artist_count = defined $args{artistCount} ? delete $args{artistCount} : 20;
	my $album_count  = defined $args{albumCount}  ? delete $args{albumCount}  : 20;
	my $song_count   = defined $args{songCount}   ? delete $args{songCount}   : 20;

	$self->call(
		endpoint   => 'search3',
		params     => {
			query       => $query,
			artistCount => $artist_count,
			albumCount  => $album_count,
			songCount   => $song_count,
		},
		success_cb => sub {
			my $data = shift;
			$success_cb->($self->as_hash($data->{searchResult3})) if $success_cb;
		},
		error_cb => $error_cb || sub {},
	);
}

# getStarred2 — starred items
sub get_starred {
	my ($self, %args) = @_;
	my $success_cb = delete $args{success_cb};
	my $error_cb   = delete $args{error_cb};

	$self->call(
		endpoint   => 'getStarred2',
		success_cb => sub {
			my $data = shift;
			$success_cb->($self->as_hash($data->{starred2})) if $success_cb;
		},
		error_cb => $error_cb || sub {},
	);
}

# getSongsByGenre — songs for genre radio
sub get_songs_by_genre {
	my ($self, $genre, %args) = @_;
	my $success_cb = delete $args{success_cb};
	my $error_cb   = delete $args{error_cb};
	my $count      = delete $args{count} || 50;

	$self->call(
		endpoint   => 'getSongsByGenre',
		params     => { genre => $genre, count => $count },
		success_cb => sub {
			my $data = shift;
			my $songs = $self->as_hash($data->{songsByGenre});
			$success_cb->($self->as_array($songs->{song})) if $success_cb;
		},
		error_cb => $error_cb || sub {},
	);
}

# getSimilarSongs2 — similar songs (artist radio)
sub get_similar_songs {
	my ($self, $id, %args) = @_;
	my $success_cb = delete $args{success_cb};
	my $error_cb   = delete $args{error_cb};
	my $count      = delete $args{count} || 50;

	$self->call(
		endpoint   => 'getSimilarSongs2',
		params     => { id => $id, count => $count },
		success_cb => sub {
			my $data = shift;
			my $songs = $self->as_hash($data->{similarSongs2});
			$success_cb->($self->as_array($songs->{song})) if $success_cb;
		},
		error_cb => $error_cb || sub {},
	);
}

# star / unstar
sub star {
	my ($self, %args) = @_;
	my $success_cb = delete $args{success_cb};
	my $error_cb   = delete $args{error_cb};

	my %params;
	$params{id}       = $args{id}       if $args{id};
	$params{albumId}  = $args{albumId}  if $args{albumId};
	$params{artistId} = $args{artistId} if $args{artistId};

	$self->call(
		endpoint   => 'star',
		params     => \%params,
		success_cb => $success_cb || sub {},
		error_cb   => $error_cb   || sub {},
	);
}

sub unstar {
	my ($self, %args) = @_;
	my $success_cb = delete $args{success_cb};
	my $error_cb   = delete $args{error_cb};

	my %params;
	$params{id}       = $args{id}       if $args{id};
	$params{albumId}  = $args{albumId}  if $args{albumId};
	$params{artistId} = $args{artistId} if $args{artistId};

	$self->call(
		endpoint   => 'unstar',
		params     => \%params,
		success_cb => $success_cb || sub {},
		error_cb   => $error_cb   || sub {},
	);
}

# setRating
sub set_rating {
	my ($self, $id, $rating, %args) = @_;
	my $success_cb = delete $args{success_cb};
	my $error_cb   = delete $args{error_cb};

	$self->call(
		endpoint   => 'setRating',
		params     => { id => $id, rating => int($rating) },
		success_cb => $success_cb || sub {},
		error_cb   => $error_cb   || sub {},
	);
}

# scrobble with submission=true (required by Navidrome)
sub scrobble {
	my ($self, $id, %args) = @_;
	my $success_cb = delete $args{success_cb};
	my $error_cb   = delete $args{error_cb};
	my $time       = delete $args{time};
	my $submission = delete $args{submission} || 'true';

	my %params = ( id => $id, submission => $submission );
	$params{time} = $time if $time;

	$self->call(
		endpoint   => 'scrobble',
		params     => \%params,
		success_cb => $success_cb || sub {},
		error_cb   => $error_cb   || sub {},
	);
}

# getPodcasts
sub get_podcasts {
	my ($self, %args) = @_;
	my $success_cb = delete $args{success_cb};
	my $error_cb   = delete $args{error_cb};

	$self->call(
		endpoint   => 'getPodcasts',
		success_cb => sub {
			my $data = shift;
			$success_cb->($self->as_hash($data->{podcasts})) if $success_cb;
		},
		error_cb => $error_cb || sub {},
	);
}

1;
