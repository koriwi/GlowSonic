package Plugins::GlowSonic::Plugin;

# Main entry point for GlowSonic — Subsonic/OpenSubsonic client for LMS
# Extends Slim::Plugin::OPMLBased for menu tree navigation + favorites support

use strict;
use warnings;
use base qw(Slim::Plugin::OPMLBased);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(cstring);
use Slim::Menu::GlobalSearch;
use Slim::Menu::TrackInfo;
use Slim::Control::Request;
use Slim::Utils::Timers;
use Time::HiRes qw(time);
use List::Util qw(shuffle);
use URI::Escape ();

# Plugin modules
use Plugins::GlowSonic::API::Async;
use Plugins::GlowSonic::Settings;

my $log = Slim::Utils::Log::logger('plugin.glowsonic');
my $prefs = preferences('plugin.glowsonic');

# Keep album result pages below LMS/XMLBrowser's 50-item display window after
# adding previous/next navigation rows.
use constant ALBUM_PAGE_SIZE => 48;

# Global API client instance (reconfigured on settings change)
my $api;

# ===========================================================================
# Plugin initialization — called by LMS
# ===========================================================================
sub initPlugin {
	my $class = shift;

	# Initialize default preferences
	$prefs->init({
		server_url        => '',
		username          => '',
		password          => '',
		auth_type         => 'token',
		api_version       => '1.16.1',
		artwork_size      => 300,
		transcode_bitrate => 0,
		transcode_format  => '',
		scrobble_enabled  => 1,
	});

	# Build API client from current prefs
	_build_api();

	# Register settings page (inherits Slim::Web::Settings)
	require Plugins::GlowSonic::Settings;
	Plugins::GlowSonic::Settings->new();

	# Register protocol handler for glows:// URLs (stream playback + metadata)
	require Plugins::GlowSonic::ProtocolHandler;
	Plugins::GlowSonic::ProtocolHandler->register();

	# Register OPML menu
	$class->SUPER::initPlugin(
		feed   => \&_handle_feed,
		tag    => 'glowsonic',
		menu   => 'apps',      # put in "My Apps" section
		is_app => 0,
		weight => 80,
	);

	# Register global search provider
	Slim::Menu::GlobalSearch->registerInfoProvider(
		name => 'GlowSonic',
		func => \&_global_search,
	);

	# Register track info menu ("More" context menu)
	Slim::Menu::TrackInfo->registerInfoProvider(
		name => 'GLOWSONIC_MORE',
		func => \&_track_info_menu,
	);

	# Listen for track play events (scrobbling)
	Slim::Control::Request::subscribe(\&_on_play_notification, [['playlist'], ['newsong']]);

	# Listen for preference changes to rebuild API client
	$prefs->setChange(\&_on_prefs_change, 'server_url');
	$prefs->setChange(\&_on_prefs_change, 'username');
	$prefs->setChange(\&_on_prefs_change, 'password');
	$prefs->setChange(\&_on_prefs_change, 'auth_type');
	$prefs->setChange(\&_on_prefs_change, 'api_version');

	$log->info("GlowSonic plugin initialized (v0.1.0)");
}

# ---------------------------------------------------------------------------
# Build API client from current preferences
# ---------------------------------------------------------------------------
sub _build_api {
	$api = undef;
	my $server_url  = $prefs->get('server_url');
	return undef unless defined $server_url && length $server_url;

	$api = Plugins::GlowSonic::API::Async->new(
		server_url  => $server_url,
		username    => $prefs->get('username')    || '',
		password    => $prefs->get('password')    || '',
		api_version => $prefs->get('api_version') || '1.16.1',
		auth_type   => $prefs->get('auth_type')   || 'token',
	);

	return $api->is_configured ? $api : undef;
}

# ---------------------------------------------------------------------------
# Ensure API client is configured; return error item if not
# ---------------------------------------------------------------------------
sub _ensure_api {
	unless ($api && $api->is_configured) {
		_build_api();
	}
	return undef unless $api && $api->is_configured;
	return $api;
}

# ===========================================================================
# OPML Feed Handler — Main menu navigation
# ===========================================================================
sub _handle_feed {
	my ($client, $callback, $args, $passthrough) = @_;

	$args ||= {};
	my $params = $args->{params} || {};

	# type/id come at top level from code refs, or nested in params from web
	my $type      = $args->{type}      || $params->{type}      || '';
	my $id        = $args->{id}        || $params->{id};
	my $list_type = $args->{list_type} || $params->{list_type};
	my $query     = _extract_search_query($args, $passthrough);
	my $offset    = defined $args->{offset} ? $args->{offset} : $params->{offset};
	$offset = defined $offset && $offset =~ /^\d+$/ ? int($offset) : 0;

	my $local_api = _ensure_api();
	unless ($local_api) {
		$callback->([ _error_item($client, cstring($client, 'GLOWSONIC_ERROR_CONFIG')) ]);
		return;
	}

	# Dispatch based on type
	if ($type eq 'artists') {
		_feed_artists($client, $callback, $local_api);
	}
	elsif ($type eq 'artist' || $type eq 'artist_albums') {
		_feed_artist_albums($client, $callback, $local_api, $id);
	}
	elsif ($type eq 'album') {
		_feed_album($client, $callback, $local_api, $id);
	}
	elsif ($type eq 'genres') {
		_feed_genres($client, $callback, $local_api);
	}
	elsif ($type eq 'genre_albums') {
		_feed_genre_albums($client, $callback, $local_api, $id, $offset);
	}
	elsif ($type eq 'playlists') {
		_feed_playlists($client, $callback, $local_api);
	}
	elsif ($type eq 'playlist') {
		_feed_playlist($client, $callback, $local_api, $id);
	}
	elsif ($type eq 'albumlist') {
		_feed_album_list($client, $callback, $local_api, $list_type || 'random', $offset);
	}
	elsif ($type eq 'search') {
		_feed_search($client, $callback, $local_api, $query);
	}
	elsif ($type eq 'starred') {
		_feed_starred($client, $callback, $local_api);
	}
	elsif ($type eq 'artist_songs') {
		_feed_artist_songs($client, $callback, $local_api, $id);
	}
	elsif ($type eq 'similar_songs') {
		_feed_similar_songs($client, $callback, $local_api, $id);
	}
	elsif ($type eq 'genre_songs') {
		_feed_genre_songs($client, $callback, $local_api, $id);
	}
	else {
		# Top-level menu
		_feed_top_menu($client, $callback);
	}
}

# ===========================================================================
# Top-level menu
# ===========================================================================
sub _feed_top_menu {
	my ($client, $callback) = @_;

	my $items = [
		{
			name  => cstring($client, 'GLOWSONIC_MENU_ARTISTS'),
			type  => 'link',
			url   => _opml_url('artists'),
			image => _icon_url('artist'),
		},
		{
			name  => cstring($client, 'GLOWSONIC_MENU_ALBUMS'),
			type  => 'link',
			url   => _opml_url('albumlist', list_type => 'newest'),
			image => _icon_url('album'),
		},
		{
			name  => cstring($client, 'GLOWSONIC_MENU_GENRES'),
			type  => 'link',
			url   => _opml_url('genres'),
			image => _icon_url('genre'),
		},
		{
			name  => cstring($client, 'GLOWSONIC_MENU_PLAYLISTS'),
			type  => 'link',
			url   => _opml_url('playlists'),
			image => _icon_url('playlist'),
		},
		{
			name  => cstring($client, 'GLOWSONIC_MENU_RANDOM'),
			type  => 'link',
			url   => _opml_url('albumlist', list_type => 'random'),
			image => _icon_url('random'),
		},
		{
			name  => cstring($client, 'GLOWSONIC_MENU_NEWEST'),
			type  => 'link',
			url   => _opml_url('albumlist', list_type => 'newest'),
			image => _icon_url('newest'),
		},
		{
			name  => cstring($client, 'GLOWSONIC_MENU_RECENT'),
			type  => 'link',
			url   => _opml_url('albumlist', list_type => 'recent'),
			image => _icon_url('recent'),
		},
		{
			name  => cstring($client, 'GLOWSONIC_MENU_FREQUENT'),
			type  => 'link',
			url   => _opml_url('albumlist', list_type => 'frequent'),
			image => _icon_url('frequent'),
		},
		{
			name  => cstring($client, 'GLOWSONIC_MENU_HIGHEST'),
			type  => 'link',
			url   => _opml_url('albumlist', list_type => 'highest'),
			image => _icon_url('highest'),
		},
		{
			name  => cstring($client, 'GLOWSONIC_MENU_STARRED'),
			type  => 'link',
			url   => _opml_url('starred'),
			image => _icon_url('starred'),
		},
		{
			name => cstring($client, 'GLOWSONIC_MENU_SEARCH'),
			type => 'search',
			url  => _opml_url('search'),
		},
	];

	$callback->($items);
}

# ===========================================================================
# Artists browsing
# ===========================================================================
sub _feed_artists {
	my ($client, $callback, $api) = @_;

	_ensure_auth($api,
		on_success => sub {
			$api->get_artists(
				success_cb => sub {
					my $artists_data = $api->as_hash(shift);
					my $index = $api->as_array($artists_data->{index});
					my @items;

					for my $idx (@$index) {
						next unless ref $idx eq 'HASH';
						my $artist_list = $api->as_array($idx->{artist});
						for my $artist (@$artist_list) {
							next unless ref $artist eq 'HASH' && defined $artist->{id};
							push @items, {
								name  => $artist->{name} || 'Unknown Artist',
								type  => 'playlist',
								url   => _opml_url('artist_albums', id => $artist->{id}),
								play => $api->favorites_url('artist', $artist->{id}),
								image => $artist->{artistImageUrl} || _api_cover_url($api, $artist->{coverArt}),
								passthrough => [{ artist_id => $artist->{id}, artist_name => $artist->{name} }],
							};
						}
					}

					if (@items) {
						$callback->(\@items);
					} else {
						$callback->([ _empty_item($client) ]);
					}
				},
				error_cb => sub {
					my ($error) = @_;
					$callback->([ _error_item($client, $error) ]);
				},
			);
		},
		on_error => sub {
			my ($error) = @_;
			$callback->([ _error_item($client, $error) ]);
		},
	);
}

# ===========================================================================
# Artist albums (list albums for a specific artist)
# ===========================================================================
sub _feed_artist_albums {
	my ($client, $callback, $api, $artist_id) = @_;

	$api->get_artist($artist_id,
		success_cb => sub {
			my $artist = $api->as_hash(shift);
			my $albums = $api->as_array($artist->{album});
			my @items;

			# Play on an artist link starts the first playable child in LMS.
			# Keep the artist's own shuffled catalog first, then expose radio separately.
			if ($artist->{id}) {
				push @items, {
					name  => cstring($client, 'GLOWSONIC_MENU_ARTIST_SHUFFLE') . ' - ' . ($artist->{name} || ''),
					type  => 'playlist',
					url   => _opml_url('artist_songs', id => $artist->{id}),
					play => $api->favorites_url('artist', $artist->{id}),
					image => $artist->{artistImageUrl} || _api_cover_url($api, $artist->{coverArt}),
					on_select => 'play',
					passthrough => [{ artist_id => $artist->{id} }],
				};
				push @items, {
					name  => cstring($client, 'GLOWSONIC_MENU_ARTIST_RADIO') . ' - ' . ($artist->{name} || ''),
					type  => 'playlist',
					url   => _opml_url('similar_songs', id => $artist->{id}),
					play => $api->favorites_url('artist-radio', $artist->{id}),
					image => $artist->{artistImageUrl} || _api_cover_url($api, $artist->{coverArt}),
					on_select => 'play',
					passthrough => [{ artist_id => $artist->{id} }],
				};
			}

			for my $album (@$albums) {
				push @items, _album_item($client, $api, $album);
			}

			_finish_items($client, $callback, @items);
		},
		error_cb => sub {
			my ($error) = @_;
			$callback->([ _error_item($client, $error) ]);
		},
	);
}

# ===========================================================================
# Album + track listing
# ===========================================================================
sub _feed_album {
	my ($client, $callback, $api, $album_id) = @_;

	$api->get_album($album_id,
		success_cb => sub {
			my $album = $api->as_hash(shift);
			my $songs = $api->as_array($album->{song});
			my @items;

			# "Play All" item at top
			if (@$songs) {
				unshift @items, {
					name  => cstring($client, 'GLOWSONIC_PLAY_ALL'),
					type  => 'playlist',
					url   => _opml_url('album', id => $album_id),
					play => $api->favorites_url('album', $album_id),
					image => _api_cover_url($api, $album->{coverArt}),
					on_select => 'play',
					favorites_url  => $api->favorites_url('album', $album_id),
					favorites_type => 'playlist',
					passthrough => [{ album_id => $album_id }],
				};
			}

			for my $song (@$songs) {
				next unless ref $song eq 'HASH';
				push @items, _song_item($api, $song,
					album         => $album->{name},
					album_id      => $album_id,
					coverart      => $album->{coverArt} || $song->{coverArt},
				);
			}

			_finish_items($client, $callback, @items);
		},
		error_cb => sub {
			my ($error) = @_;
			$callback->([ _error_item($client, $error) ]);
		},
	);
}

# ===========================================================================
# Genres
# ===========================================================================
sub _feed_genres {
	my ($client, $callback, $api) = @_;

	$api->get_genres(
		success_cb => sub {
			my $genres = $api->as_array(shift);
			my @items;

			for my $genre (@$genres) {
				my $name = ref $genre eq 'HASH' ? ($genre->{value} || $genre->{name}) : $genre;
				next unless $name;
				push @items, {
					name  => $name,
					type  => 'playlist',
					url   => _opml_url('genre_albums', id => $name),
					play => $api->favorites_url('genre', $name),
					passthrough => [{ genre => $name }],
				};
			}

			_finish_items($client, $callback, @items);
		},
		error_cb => sub {
			my ($error) = @_;
			$callback->([ _error_item($client, $error) ]);
		},
	);
}

# ===========================================================================
# Albums by genre
# ===========================================================================
sub _feed_genre_albums {
	my ($client, $callback, $api, $genre, $offset) = @_;
	$offset ||= 0;

	$api->get_album_list('byGenre',
		genre  => $genre,
		size   => ALBUM_PAGE_SIZE + 1,
		offset => $offset,
		success_cb => sub {
			my $albums = $api->as_array(shift);
			my $has_more = @$albums > ALBUM_PAGE_SIZE;
			splice @$albums, ALBUM_PAGE_SIZE if $has_more;
			my @items = _album_list_items($client, $api, $albums);
			_add_album_pagination($client, \@items, 'genre_albums', { id => $genre }, $offset, $has_more);
			_finish_items($client, $callback, @items);
		},
		error_cb => sub {
			my ($error) = @_;
			$callback->([ _error_item($client, $error) ]);
		},
	);
}

# ===========================================================================
# Playlists
# ===========================================================================
sub _feed_playlists {
	my ($client, $callback, $api) = @_;

	$api->get_playlists(
		success_cb => sub {
			my $playlists = $api->as_array(shift);
			my @items;

			for my $pl (@$playlists) {
				next unless ref $pl eq 'HASH' && defined $pl->{id};
				push @items, {
					name  => $pl->{name} || 'Unknown Playlist',
					type  => 'playlist',
					url   => _opml_url('playlist', id => $pl->{id}),
					play => $api->favorites_url('playlist', $pl->{id}),
					image => _api_cover_url($api, $pl->{coverArt}),
					passthrough => [{ playlist_id => $pl->{id}, playlist_name => $pl->{name} }],
					favorites_url  => $api->favorites_url('playlist', $pl->{id}),
					favorites_type => 'playlist',
				};
			}

			_finish_items($client, $callback, @items);
		},
		error_cb => sub {
			my ($error) = @_;
			$callback->([ _error_item($client, $error) ]);
		},
	);
}

# ===========================================================================
# Playlist tracks
# ===========================================================================
sub _feed_playlist {
	my ($client, $callback, $api, $playlist_id) = @_;

	$api->get_playlist($playlist_id,
		success_cb => sub {
			my $playlist = $api->as_hash(shift);
			my $entries = $api->as_array($playlist->{entry});
			my @items;

			if (@$entries) {
				unshift @items, {
					name  => cstring($client, 'GLOWSONIC_PLAY_ALL'),
					type  => 'playlist',
					url   => _opml_url('playlist', id => $playlist_id),
					play => $api->favorites_url('playlist', $playlist_id),
					image => _api_cover_url($api, $playlist->{coverArt}),
					on_select => 'play',
					favorites_url  => $api->favorites_url('playlist', $playlist_id),
					favorites_type => 'playlist',
					passthrough => [{ playlist_id => $playlist_id }],
				};
			}

			for my $entry (@$entries) {
				next unless ref $entry eq 'HASH';
				push @items, _song_item($api, $entry,
					coverart      => $entry->{coverArt} || $entry->{albumId} || $playlist->{coverArt},
				);
			}

			_finish_items($client, $callback, @items);
		},
		error_cb => sub {
			my ($error) = @_;
			$callback->([ _error_item($client, $error) ]);
		},
	);
}

# ===========================================================================
# Album lists (random, newest, recent, frequent, highest)
# ===========================================================================
sub _feed_album_list {
	my ($client, $callback, $api, $list_type, $offset) = @_;
	$offset ||= 0;

	$api->get_album_list($list_type,
		size   => ALBUM_PAGE_SIZE + 1,
		offset => $offset,
		success_cb => sub {
			my $albums = $api->as_array(shift);
			my $has_more = @$albums > ALBUM_PAGE_SIZE;
			splice @$albums, ALBUM_PAGE_SIZE if $has_more;
			my @items = _album_list_items($client, $api, $albums);
			_add_album_pagination($client, \@items, 'albumlist', { list_type => $list_type }, $offset, $has_more);
			_finish_items($client, $callback, @items);
		},
		error_cb => sub {
			my ($error) = @_;
			$callback->([ _error_item($client, $error) ]);
		},
	);
}

# ===========================================================================
# Search
# ===========================================================================
sub _feed_search {
	my ($client, $callback, $api, $query) = @_;

	# URL-decode query
	$query = URI::Escape::uri_unescape($query // '');
	$query =~ s/\+/ /g;

	return $callback->([]) unless $query;

	$api->search($query,
		success_cb => sub {
			my $results = $api->as_hash(shift);
			my @items;

			# Artists
			my $artists = $api->as_array($results->{artist});
			for my $artist (@$artists) {
				next unless ref $artist eq 'HASH' && defined $artist->{id};
				push @items, {
					name  => cstring($client, 'GLOWSONIC_ARTIST') . ': ' . ($artist->{name} || 'Unknown'),
					type  => 'playlist',
					url   => _opml_url('artist_albums', id => $artist->{id}),
					play => $api->favorites_url('artist', $artist->{id}),
					image => $artist->{artistImageUrl} || _api_cover_url($api, $artist->{coverArt}),
					passthrough => [{ artist_id => $artist->{id}, artist_name => $artist->{name} }],
				};
			}

			# Albums
			my $albums = $api->as_array($results->{album});
			for my $album (@$albums) {
				push @items, _album_item($client, $api, $album);
			}

			# Songs
			my $songs = $api->as_array($results->{song});
			for my $song (@$songs) {
				push @items, _song_item($api, $song);
			}

			_finish_items($client, $callback, @items);
		},
		error_cb => sub {
			my ($error) = @_;
			$callback->([ _error_item($client, $error) ]);
		},
	);
}

# ===========================================================================
# Starred items
# ===========================================================================
sub _feed_starred {
	my ($client, $callback, $api) = @_;

	$api->get_starred(
		success_cb => sub {
			my $starred = $api->as_hash(shift);
			my @items;

			my $artists = $api->as_array($starred->{artist});
			for my $a (@$artists) {
				next unless ref $a eq 'HASH' && defined $a->{id};
				push @items, {
					name  => '★ ' . ($a->{name} || 'Unknown Artist'),
					type  => 'playlist',
					url   => _opml_url('artist_albums', id => $a->{id}),
					play => $api->favorites_url('artist', $a->{id}),
					image => $a->{artistImageUrl} || _api_cover_url($api, $a->{coverArt}),
				};
			}

			my $albums = $api->as_array($starred->{album});
			for my $a (@$albums) {
				push @items, _album_item($client, $api, $a);
			}

			my $songs = $api->as_array($starred->{song});
			for my $s (@$songs) {
				push @items, _song_item($api, $s, name_prefix => '★ ');
			}

			_finish_items($client, $callback, @items);
		},
		error_cb => sub {
			my ($error) = @_;
			$callback->([ _error_item($client, $error) ]);
		},
	);
}

# ===========================================================================
# All artist songs, shuffled from every album returned by getArtist/getAlbum
# ===========================================================================
sub _feed_artist_songs {
	my ($client, $callback, $api, $artist_id) = @_;

	$api->get_artist($artist_id,
		success_cb => sub {
			my $artist = $api->as_hash(shift);
			my @albums = grep { ref $_ eq 'HASH' && defined $_->{id} && length $_->{id} }
				@{ $api->as_array($artist->{album}) };

			unless (@albums) {
				$callback->([ _empty_item($client) ]);
				return;
			}

			my @songs;
			my %seen;
			my $first_error;
			my $fetch_next;
			$fetch_next = sub {
				my $album_ref = shift @albums;
				unless ($album_ref) {
					my @items = map { _song_item($api, $_) } shuffle @songs;
					@items = grep { ref $_ eq 'HASH' } @items;
					if (@items) {
						$callback->(\@items);
					} elsif ($first_error) {
						$callback->([ _error_item($client, $first_error) ]);
					} else {
						$callback->([ _empty_item($client) ]);
					}
					return;
				}

				$api->get_album($album_ref->{id},
					success_cb => sub {
						my $album = $api->as_hash(shift);
						for my $song (@{ $api->as_array($album->{song}) }) {
							next unless ref $song eq 'HASH' && defined $song->{id} && length $song->{id};
							next if $seen{ $song->{id} }++;
							my %song = %$song;
							$song{album}    ||= $album->{name} || $album_ref->{name};
							$song{albumId}  ||= $album->{id} || $album_ref->{id};
							$song{coverArt} ||= $album->{coverArt} || $album_ref->{coverArt};
							push @songs, \%song;
						}
						$fetch_next->();
					},
					error_cb => sub {
						my ($error) = @_;
						$first_error ||= $error;
						$fetch_next->();
					},
				);
			};
			$fetch_next->();
		},
		error_cb => sub {
			my ($error) = @_;
			$callback->([ _error_item($client, $error) ]);
		},
	);
}

# ===========================================================================
# Artist Radio (similar songs)
# ===========================================================================
sub _feed_similar_songs {
	my ($client, $callback, $api, $artist_id) = @_;

	$api->get_similar_songs($artist_id,
		count => 100,
		success_cb => sub {
			my $songs = $api->as_array(shift);
			my @items = map { _song_item($api, $_) } @$songs;
			_finish_items($client, $callback, @items);
		},
		error_cb => sub {
			my ($error) = @_;
			$callback->([ _error_item($client, $error) ]);
		},
	);
}

# ===========================================================================
# Genre Radio (songs by genre)
# ===========================================================================
sub _feed_genre_songs {
	my ($client, $callback, $api, $genre) = @_;

	$api->get_songs_by_genre($genre,
		count => 100,
		success_cb => sub {
			my $songs = $api->as_array(shift);
			my @items = map { _song_item($api, $_) } @$songs;
			_finish_items($client, $callback, @items);
		},
		error_cb => sub {
			my ($error) = @_;
			$callback->([ _error_item($client, $error) ]);
		},
	);
}

# ===========================================================================
# Global Search integration
# ===========================================================================
sub _global_search {
	my ($client, $search_string, $callback, $search_args) = @_;

	my $local_api = _ensure_api();
	unless ($local_api) {
		$callback->([]);
		return;
	}

	$local_api->search($search_string,
		artistCount => 5,
		albumCount  => 5,
		songCount   => 10,
		success_cb => sub {
			my $results = $local_api->as_hash(shift);
			my @items;

			for my $song (@{ $local_api->as_array($results->{song}) }) {
				push @items, _song_item($local_api, $song,
					line2 => ($song->{artist} || ''),
					line3 => ($song->{album} || ''),
				);
			}

			for my $artist (@{ $local_api->as_array($results->{artist}) }) {
				next unless ref $artist eq 'HASH' && defined $artist->{id};
				push @items, {
					name   => cstring($client, 'GLOWSONIC_ARTIST') . ': ' . ($artist->{name} || ''),
					type   => 'playlist',
					url    => _opml_url('artist_albums', id => $artist->{id}),
					play => $local_api->favorites_url('artist', $artist->{id}),
					image  => _api_cover_url($local_api, $artist->{coverArt}),
				};
			}

			for my $album (@{ $local_api->as_array($results->{album}) }) {
				next unless ref $album eq 'HASH' && defined $album->{id};
				push @items, {
					name   => cstring($client, 'GLOWSONIC_ALBUM') . ': ' . ($album->{name} || ''),
					line2  => ($album->{artist} || ''),
					type   => 'playlist',
					url    => _opml_url('album', id => $album->{id}),
					play => $local_api->favorites_url('album', $album->{id}),
					image  => _api_cover_url($local_api, $album->{coverArt}),
				};
			}

			@items = grep { ref $_ eq 'HASH' } @items;
			$callback->(\@items);
		},
		error_cb => sub {
			$callback->([]);
		},
	);
}

# ===========================================================================
# Track Info ("More") context menu
# ===========================================================================
sub _track_info_menu {
	my ($client, $url, $track, $remoteMeta, $tags, $items) = @_;

	# Only add menu for GlowSonic tracks (glows:// URLs)
	return unless defined $url && $url =~ /^glows/;

	my $local_api = _ensure_api();
	return unless $local_api;

	# Parse track info from passthrough when present, otherwise fall back to
	# metadata encoded in the glows:// URL (common for restored playlists).
	my $pt = eval { $track->pluginData->{passthrough} } || undef;
	$pt = $pt->[0] if ref $pt eq 'ARRAY';
	$pt = {} unless ref $pt eq 'HASH';

	my (undef, $url_params) = Plugins::GlowSonic::ProtocolHandler->parse_url($url);
	$url_params ||= {};

	my $artist   = $pt->{artist}   || $url_params->{artist};
	my $album    = $pt->{album}    || $url_params->{album};
	my $title    = $pt->{title}    || $url_params->{title};
	my $album_id = $pt->{album_id} || $url_params->{album_id};

	# Search this artist
	if ($artist) {
		push @$items, {
			name => cstring($client, 'GLOWSONIC_SEARCH_ARTIST') . ': ' . $artist,
			type => 'link',
			url  => \&_track_info_search_artist,
			passthrough => [{ query => $artist }],
		};
	}

	# Search this album
	if ($album) {
		push @$items, {
			name => cstring($client, 'GLOWSONIC_SEARCH_ALBUM') . ': ' . $album,
			type => 'link',
			url  => \&_track_info_search_album,
			passthrough => [{ query => $album }],
		};
	}

	# Search this title
	if ($title) {
		push @$items, {
			name => cstring($client, 'GLOWSONIC_SEARCH_TITLE') . ': ' . $title,
			type => 'link',
			url  => \&_track_info_search,
			passthrough => [{ query => $title }],
		};
	}

	# Go to album (if we have album_id)
	if ($album_id) {
		push @$items, {
			name => cstring($client, 'GLOWSONIC_ALBUM') . ': ' . ($album || ''),
			type => 'playlist',
			url  => _opml_url('album', id => $album_id),
			play => $local_api->favorites_url('album', $album_id),
		};
	}
}

sub _track_info_search_artist {
	my ($client, $callback, $args) = @_;
	my $query = _passthrough_query($args);
	my $local_api = _ensure_api();
	return $callback->([]) unless $local_api && defined $query && length $query;
	$local_api->search($query, artistCount => 20, albumCount => 0, songCount => 0,
		success_cb => sub {
			my $results = $local_api->as_hash(shift);
			my @items;
			for my $a (@{ $local_api->as_array($results->{artist}) }) {
				next unless ref $a eq 'HASH' && defined $a->{id};
				push @items, {
					name => $a->{name},
					type => 'playlist',
					url  => _opml_url('artist_albums', id => $a->{id}),
					play => $local_api->favorites_url('artist', $a->{id}),
				};
			}
			$callback->(\@items);
		},
		error_cb => sub { $callback->([]) },
	);
}

sub _track_info_search_album {
	my ($client, $callback, $args) = @_;
	my $query = _passthrough_query($args);
	my $local_api = _ensure_api();
	return $callback->([]) unless $local_api && defined $query && length $query;
	$local_api->search($query, artistCount => 0, albumCount => 20, songCount => 0,
		success_cb => sub {
			my $results = $local_api->as_hash(shift);
			my @items;
			for my $a (@{ $local_api->as_array($results->{album}) }) {
				next unless ref $a eq 'HASH' && defined $a->{id};
				push @items, {
					name  => $a->{name},
					line2 => $a->{artist},
					type  => 'playlist',
					url   => _opml_url('album', id => $a->{id}),
					play => $local_api->favorites_url('album', $a->{id}),
				};
			}
			$callback->(\@items);
		},
		error_cb => sub { $callback->([]) },
	);
}

sub _track_info_search {
	my ($client, $callback, $args) = @_;
	my $query = _passthrough_query($args);
	my $local_api = _ensure_api();
	return $callback->([]) unless $local_api && defined $query && length $query;
	$local_api->search($query,
		success_cb => sub {
			my $results = $local_api->as_hash(shift);
			my @items;
			for my $s (@{ $local_api->as_array($results->{song}) }) {
				push @items, _song_item($local_api, $s,
					line2 => join(' - ', grep { length } ($s->{artist} || '', $s->{album} || '')),
				);
			}
			@items = grep { ref $_ eq 'HASH' } @items;
			$callback->(\@items);
		},
		error_cb => sub { $callback->([]) },
	);
}

sub _passthrough_query {
	my $args = shift || {};
	my $pt = ref $args eq 'HASH' ? $args->{passthrough} : undef;
	$pt = $pt->[0] if ref $pt eq 'ARRAY';
	return ref $pt eq 'HASH' ? $pt->{query} : undef;
}

# ===========================================================================
# Helper: authenticate before browsing (if first time)
# ===========================================================================
sub _ensure_auth {
	my ($api, %callbacks) = @_;
	my $on_success = $callbacks{on_success};
	my $on_error   = $callbacks{on_error} || sub {};

	$api->authenticate(
		success_cb => sub {
			$on_success->() if $on_success;
		},
		error_cb => sub {
			my ($err) = @_;
			$on_error->($err);
		},
	);
}

# ---------------------------------------------------------------------------
# Helper: finish feed callbacks consistently
# ---------------------------------------------------------------------------
sub _finish_items {
	my ($client, $callback, @items) = @_;
	@items = grep { ref $_ eq 'HASH' } @items;
	$callback->(@items ? \@items : [ _empty_item($client) ]);
}

# ---------------------------------------------------------------------------
# Helper: add previous/next links for paged album lists
# ---------------------------------------------------------------------------
sub _add_album_pagination {
	my ($client, $items, $feed_type, $url_args, $offset, $has_more) = @_;
	$offset ||= 0;

	my @nav;
	if ($offset > 0) {
		my $prev = $offset - ALBUM_PAGE_SIZE;
		$prev = 0 if $prev < 0;
		push @nav, {
			name  => cstring($client, 'GLOWSONIC_PREVIOUS_PAGE'),
			type  => 'link',
			url   => _opml_url($feed_type, %$url_args, offset => $prev),
			image => _icon_url('previous'),
		};
	}

	if ($has_more) {
		push @nav, {
			name  => cstring($client, 'GLOWSONIC_NEXT_PAGE'),
			type  => 'link',
			url   => _opml_url($feed_type, %$url_args, offset => $offset + ALBUM_PAGE_SIZE),
			image => _icon_url('next'),
		};
	}

	unshift @$items, @nav if @nav;
}

# ---------------------------------------------------------------------------
# Helper: build a playable song OPML item
# ---------------------------------------------------------------------------
sub _song_item {
	my ($api, $song, %opts) = @_;
	return undef unless ref $song eq 'HASH' && defined $song->{id} && length $song->{id};

	my $album    = defined $opts{album}    ? $opts{album}    : ($song->{album} || '');
	my $album_id = defined $opts{album_id} ? $opts{album_id} : $song->{albumId};
	my $coverart = defined $opts{coverart} ? $opts{coverart} : ($song->{coverArt} || $song->{albumId});
	my $title    = $song->{title} || 'Unknown';

	my $stream_url = $api->stream_url($song->{id},
		maxBitRate  => $prefs->get('transcode_bitrate') || undef,
		format      => $prefs->get('transcode_format')  || undef,
		title       => $song->{title},
		artist      => $song->{artist},
		album       => $album,
		coverart    => $coverart,
		duration    => $song->{duration},
		bitrate     => $song->{bitRate},
		suffix      => $song->{suffix},
		contentType => $song->{contentType},
	);
	return undef unless $stream_url;

	my %item = (
		name         => ($opts{name_prefix} || '') . $title,
		type         => 'audio',
		url          => $stream_url,
		image        => _api_cover_url($api, $coverart),
		on_select    => 'play',
		title        => $song->{title} || '',
		artist       => $song->{artist} || '',
		album        => $album,
		duration     => $song->{duration},
		secs         => $song->{duration},
		bitrate      => $song->{bitRate},
		content_type => $song->{contentType},
		passthrough  => [{
			track_id => $song->{id},
			album_id => $album_id,
			title    => $song->{title},
			artist   => $song->{artist},
			album    => $album,
			coverart => $coverart,
			duration => $song->{duration},
			bitrate  => $song->{bitRate},
			suffix   => $song->{suffix},
		}],
	);

	for my $field (qw(line2 line3 favorites_url favorites_type)) {
		$item{$field} = $opts{$field} if defined $opts{$field};
	}

	return \%item;
}

# ===========================================================================
# Helper: build an album OPML item
# ===========================================================================
sub _album_item {
	my ($client, $api, $album) = @_;
	return undef unless ref $album eq 'HASH' && defined $album->{id} && length $album->{id};
	return {
		name  => ($album->{name} || 'Unknown Album') . ' - ' . ($album->{artist} || ''),
		type  => 'playlist',
		url   => _opml_url('album', id => $album->{id}),
		play => $api->favorites_url('album', $album->{id}),
		image => _api_cover_url($api, $album->{coverArt}),
		passthrough => [{ album_id => $album->{id}, album_name => $album->{name} }],
		favorites_url  => $api->favorites_url('album', $album->{id}),
		favorites_type => 'playlist',
	};
}

# ---------------------------------------------------------------------------
# Helper: build album list items
# ---------------------------------------------------------------------------
sub _album_list_items {
	my ($client, $api, $albums) = @_;
	my @items;
	for my $album (@{ $api->as_array($albums) }) {
		my $item = _album_item($client, $api, $album);
		push @items, $item if $item;
	}
	return @items;
}

# ---------------------------------------------------------------------------
# Helper: find the search text passed by LMS/XMLBrowser. Different LMS UIs
# use different arg names, so accept the common variants and ignore the old
# literal {QUERY} placeholder.
# ---------------------------------------------------------------------------
sub _extract_search_query {
	my ($args, $passthrough) = @_;
	$args ||= {};

	my @sources = ($args);
	push @sources, $args->{params} if ref $args->{params} eq 'HASH';
	push @sources, @$passthrough if ref $passthrough eq 'ARRAY';
	push @sources, $passthrough if ref $passthrough eq 'HASH';

	for my $source (@sources) {
		next unless ref $source eq 'HASH';
		for my $key (qw(query search searchTerm search_string searchString term text value q)) {
			my $value = $source->{$key};
			next unless defined $value && length $value && $value ne '{QUERY}';
			return $value;
		}
	}

	return undef;
}

# ===========================================================================
# Helper: generate OPML feed URLs
# ===========================================================================
sub _opml_url {
	my ($type, %args) = @_;
	# Return a code ref that calls our feed handler directly.
	# String URLs require full HTTP fetch; code refs are called
	# in-process by the XMLBrowser — much faster and avoids URL issues.
	return sub {
		my ($client, $cb, $cb_args, $pt) = @_;
		$cb_args->{type} = $type;
		$cb_args->{id}   = $args{id} if defined $args{id};
		$cb_args->{list_type} = $args{list_type} if defined $args{list_type};
		if (defined $args{query}) {
			$cb_args->{query} = $args{query} eq '{QUERY}'
				? _extract_search_query($cb_args, $pt)
				: $args{query};
		}
		$cb_args->{offset} = $args{offset} if defined $args{offset};
		_handle_feed($client, $cb, $cb_args, $pt);
	};
}

# ===========================================================================
# Helper: cover art URL through API
# ===========================================================================
sub _api_cover_url {
	my ($api, $cover_art_id) = @_;
	return undef unless $cover_art_id;

	my $size = $prefs->get('artwork_size') || 300;
	$size = 300 unless $size =~ /^\d+$/ && $size > 0 && $size <= 2000;
	return $api->cover_art_url($cover_art_id, $size);
}

# ===========================================================================
# Helper: empty/no-results item
# ===========================================================================
sub _empty_item {
	my $client = shift;
	return { name => cstring($client, 'GLOWSONIC_ERROR_EMPTY'), type => 'text' };
}

# ===========================================================================
# Helper: error item
# ===========================================================================
sub _error_item {
	my ($client, $error) = @_;
	$error ||= cstring($client, 'GLOWSONIC_ERROR_LOADING');
	return { name => $error, type => 'text' };
}

# ===========================================================================
# Helper: icon URL for menu items
# ===========================================================================
sub _icon_url {
	return "/plugins/GlowSonic/html/images/icon.svg";
}

# ---------------------------------------------------------------------------
# Preference change handler — rebuild API client
# ---------------------------------------------------------------------------
sub _on_prefs_change {
	my ($pref, $value) = @_;
	$log->info("GlowSonic preference changed, rebuilding API client");
	_build_api();
}

# ---------------------------------------------------------------------------
# Track play notification — scrobble to Navidrome after a basic play threshold.
# ---------------------------------------------------------------------------
sub _on_play_notification {
	my $request = shift;
	return unless $prefs->get('scrobble_enabled');

	my $client  = $request->client;
	my $song    = $request->getResult;
	return unless $client && $song;

	my $url = eval { $song->track->url } || '';
	return unless $url && $url =~ /^glows/;

	my ($track_id, $params) = Plugins::GlowSonic::ProtocolHandler->parse_url($url);
	return unless $track_id;

	# Cancel any pending scrobble for the previous track on this player.
	eval { Slim::Utils::Timers::killTimers($client, \&_scrobble_timer_cb); };

	my $duration = $params->{duration};
	my $delay = 60;
	if (defined $duration && $duration =~ /^\d+(?:\.\d+)?$/ && $duration > 0) {
		$delay = int($duration / 2);
		$delay = 30  if $delay < 30;
		$delay = 240 if $delay > 240;
	}

	eval {
		Slim::Utils::Timers::setTimer($client, time() + $delay, \&_scrobble_timer_cb, $url, $track_id);
	};
	if ($@) {
		$log->warn("Could not schedule GlowSonic scrobble timer, scrobbling immediately: $@");
		_scrobble_track($track_id);
	}
}

sub _scrobble_timer_cb {
	my ($client, $url, $track_id) = @_;
	return unless $prefs->get('scrobble_enabled') && $track_id;

	my $current_url = eval { $client->playingSong->track->url }
		|| eval { $client->streamingSong->track->url }
		|| '';
	return unless $current_url && $current_url eq $url;

	_scrobble_track($track_id);
}

sub _scrobble_track {
	my $track_id = shift;
	my $local_api = _ensure_api();
	return unless $local_api;

	$local_api->scrobble($track_id,
		submission => 'true',
		success_cb => sub {
			$log->info("Scrobbled: $track_id") if $log->is_info;
		},
		error_cb => sub {
			my ($err) = @_;
			$err ||= 'unknown error';
			$log->warn("Scrobble failed for $track_id: $err");
		},
	);
}

1;
