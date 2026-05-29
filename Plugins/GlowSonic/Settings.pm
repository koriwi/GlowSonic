package Plugins::GlowSonic::Settings;

# Plugin settings page — inherits from Slim::Web::Settings for automatic registration
# Provides configuration for server connection, caching, transcoding, artwork

use strict;
use warnings;
use base qw(Slim::Web::Settings);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string cstring);

my $log   = Slim::Utils::Log::logger('plugin.glowsonic');
my $prefs = preferences('plugin.glowsonic');

my $last_test_result;
my $last_test_result_msg;

# ---------------------------------------------------------------------------
# Settings page name (displayed in LMS Settings UI)
# ---------------------------------------------------------------------------
sub name {
	return Slim::Web::HTTP::CSRF->protectName('GLOWSONIC_SETTINGS');
}

# ---------------------------------------------------------------------------
# Settings page URL path
# ---------------------------------------------------------------------------
sub page {
	return Slim::Web::HTTP::CSRF->protectURI('plugins/GlowSonic/settings/basic.html');
}

# ---------------------------------------------------------------------------
# Preference keys this settings page manages (auto-save + pre-populate)
# ---------------------------------------------------------------------------
sub prefs {
	return ($prefs, qw(server_url username password auth_type api_version
		cache_ttl_lists cache_ttl_music cache_ttl_images
		artwork_size transcode_bitrate transcode_format scrobble_enabled));
}

# ---------------------------------------------------------------------------
# Handler — called when settings page is requested or form is submitted
# ---------------------------------------------------------------------------
sub handler {
	my ($class, $client, $params, $callback, @args) = @_;

	# Handle "Test Connection" button (separate submit, not a save).
	# Some LMS skins submit button values differently, so accept a few forms and
	# make sure the base settings handler does not treat this as a save/redirect.
	if (_is_test_connection($params)) {
		delete $params->{saveSettings};

		my $result = _do_test_connection($params);
		$last_test_result     = $params->{test_result}     = $result->{success} ? 'success' : 'error';
		$last_test_result_msg = $params->{test_result_msg} = $result->{message};
	}

	# Handle saveSettings (SUPER handles the actual saving via prefs() above)
	if ($params->{saveSettings}) {
		# Mask password if unchanged
		if (defined $params->{pref_password} && $params->{pref_password} =~ /^\*+$/) {
			delete $params->{pref_password};
		}
	}

	# Let SUPER render the template and handle save logic
	$class->SUPER::handler($client, $params, sub {
		my ($client, $params, $body) = @_;
		$callback->($client, $params, $body, @args);
	}, @args);
}

# ---------------------------------------------------------------------------
# beforeRender — add extra template variables before rendering
# ---------------------------------------------------------------------------
sub beforeRender {
	my ($class, $params, $client) = @_;

	# Auth type dropdown
	$params->{auth_type_token}    = ($prefs->get('auth_type') eq 'token')    ? 'selected' : '';
	$params->{auth_type_password} = ($prefs->get('auth_type') eq 'password') ? 'selected' : '';

	# Transcode format dropdown
	my $fmt = $prefs->get('transcode_format') || '';
	$params->{transcode_orig_sel} = ($fmt eq '')     ? 'selected' : '';
	$params->{transcode_mp3_sel}  = ($fmt eq 'mp3')  ? 'selected' : '';
	$params->{transcode_opus_sel} = ($fmt eq 'opus') ? 'selected' : '';
	$params->{transcode_ogg_sel}  = ($fmt eq 'ogg')  ? 'selected' : '';
	$params->{transcode_aac_sel}  = ($fmt eq 'aac')  ? 'selected' : '';

	# Scrobble checkbox
	$params->{scrobble_enabled} = $prefs->get('scrobble_enabled') ? 'checked' : '';

	# i18n strings
	$params->{SETTINGS_TITLE}             = cstring($client, 'GLOWSONIC_SETTINGS');
	$params->{SETTINGS_SERVER}            = cstring($client, 'GLOWSONIC_SETTINGS_SERVER');
	$params->{SETTINGS_SERVER_URL}        = cstring($client, 'GLOWSONIC_SETTINGS_SERVER_URL');
	$params->{SETTINGS_SERVER_URL_DESC}   = cstring($client, 'GLOWSONIC_SETTINGS_SERVER_URL_DESC');
	$params->{SETTINGS_USERNAME}          = cstring($client, 'GLOWSONIC_SETTINGS_USERNAME');
	$params->{SETTINGS_PASSWORD}          = cstring($client, 'GLOWSONIC_SETTINGS_PASSWORD');
	$params->{SETTINGS_AUTH_TYPE}         = cstring($client, 'GLOWSONIC_SETTINGS_AUTH_TYPE');
	$params->{SETTINGS_AUTH_TOKEN}        = cstring($client, 'GLOWSONIC_SETTINGS_AUTH_TOKEN');
	$params->{SETTINGS_AUTH_PASSWORD}     = cstring($client, 'GLOWSONIC_SETTINGS_AUTH_PASSWORD');
	$params->{SETTINGS_API_VERSION}       = cstring($client, 'GLOWSONIC_SETTINGS_API_VERSION');
	$params->{SETTINGS_CACHE_TTL}         = cstring($client, 'GLOWSONIC_SETTINGS_CACHE_TTL');
	$params->{SETTINGS_ARTWORK_SIZE}      = cstring($client, 'GLOWSONIC_SETTINGS_ARTWORK_SIZE');
	$params->{SETTINGS_TRANSCODE_BITRATE} = cstring($client, 'GLOWSONIC_SETTINGS_TRANSCODE_BITRATE');
	$params->{SETTINGS_TRANSCODE_FORMAT}  = cstring($client, 'GLOWSONIC_SETTINGS_TRANSCODE_FORMAT');
	$params->{SETTINGS_TEST_CONNECTION}   = cstring($client, 'GLOWSONIC_SETTINGS_TEST_CONNECTION');

	# Test connection result from handler().  Keep this here as well as in
	# handler(), because Slim::Web::Settings rebuilds parts of the template params.
	if ($last_test_result) {
		$params->{test_result}     = $last_test_result;
		$params->{test_result_msg} = $last_test_result_msg;
		$last_test_result = $last_test_result_msg = undef;
	}

	# Generic LMS strings
	$params->{SETTINGS_CACHING}      = string('SETTINGS_CACHING') || 'Caching';
	$params->{SETTINGS_LISTS}        = string('SETTINGS_LISTS') || 'Lists';
	$params->{SETTINGS_MUSIC}        = string('SETTINGS_MUSIC') || 'Music Data';
	$params->{SETTINGS_IMAGES}       = string('SETTINGS_IMAGES') || 'Images';
	$params->{SETTINGS_SECONDS}      = string('SETTINGS_SECONDS') || 'seconds';
	$params->{SETTINGS_DISPLAY}      = string('SETTINGS_DISPLAY') || 'Display';
	$params->{SETTINGS_PIXELS}       = string('SETTINGS_PIXELS') || 'pixels';
	$params->{SETTINGS_TRANSCODING}  = string('SETTINGS_TRANSCODING') || 'Transcoding';
	$params->{SETTINGS_PLAYBACK}     = string('SETTINGS_PLAYBACK') || 'Playback';
	$params->{GLOWSONIC_SCROBBLE}    = cstring($client, 'GLOWSONIC_SCROBBLE') || 'Scrobbling enabled';
}

# ---------------------------------------------------------------------------
# Detect test connection submissions across LMS skins/browsers.
# ---------------------------------------------------------------------------
sub _is_test_connection {
	my ($params) = @_;
	return 1 if $params->{test_connection};
	return 1 if $params->{pref_test_connection};
	return 1 if ($params->{button} || '') eq 'test_connection';
	return 1 if ($params->{action} || '') eq 'test_connection';
	return 0;
}

# ---------------------------------------------------------------------------
# Run a connection test — called from handler when user clicks 'Test Connection'
# ---------------------------------------------------------------------------
sub _do_test_connection {
	my ($params) = @_;

	my $server_url  = $params->{pref_server_url}  || $prefs->get('server_url');
	my $username    = $params->{pref_username}     || $prefs->get('username');
	my $password    = $params->{pref_password}     || $prefs->get('password');
	my $auth_type   = $params->{pref_auth_type}    || $prefs->get('auth_type');
	my $api_version = $params->{pref_api_version}  || $prefs->get('api_version') || '1.16.1';

	if ($password && $password =~ /^\*+$/) {
		$password = $prefs->get('password');
	}

	unless ($server_url && $username) {
		return { success => 0, message => 'Please fill in server URL and username.' };
	}

	eval {
		require Plugins::GlowSonic::API::Sync;
		my $api = Plugins::GlowSonic::API::Sync->new(
			server_url  => $server_url,
			username    => $username,
			password    => $password,
			auth_type   => $auth_type || 'token',
			api_version => $api_version,
		);

		my $result = $api->ping();

		if ($result) {
			return {
				success => 1,
				message => sprintf('Connected! %s v%s, API %s',
					$result->{type}, $result->{serverVersion}, $result->{version}),
			};
		}
		return { success => 0, message => 'Connection failed. Check URL and credentials.' };
	};
	if ($@) {
		$log->error("Test connection error: $@");
		return { success => 0, message => "Error: $@" };
	}
}

1;
