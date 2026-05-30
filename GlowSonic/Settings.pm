package Plugins::GlowSonic::Settings;

# Plugin settings page — inherits from Slim::Web::Settings for automatic registration
# Provides configuration for server connection, caching, transcoding, artwork

use strict;
use warnings;
use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string cstring);

my $prefs = preferences('plugin.glowsonic');

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
		artwork_size transcode_bitrate transcode_format scrobble_enabled));
}

# ---------------------------------------------------------------------------
# Handler — called when settings page is requested or form is submitted
# ---------------------------------------------------------------------------
sub handler {
	my ($class, $client, $params, $callback, @args) = @_;


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
	$params->{SETTINGS_ARTWORK_SIZE}      = cstring($client, 'GLOWSONIC_SETTINGS_ARTWORK_SIZE');
	$params->{SETTINGS_TRANSCODE_BITRATE} = cstring($client, 'GLOWSONIC_SETTINGS_TRANSCODE_BITRATE');
	$params->{SETTINGS_TRANSCODE_FORMAT}  = cstring($client, 'GLOWSONIC_SETTINGS_TRANSCODE_FORMAT');

	# Generic LMS strings
	$params->{SETTINGS_DISPLAY}      = string('SETTINGS_DISPLAY') || 'Display';
	$params->{SETTINGS_PIXELS}       = string('SETTINGS_PIXELS') || 'pixels';
	$params->{SETTINGS_TRANSCODING}  = string('SETTINGS_TRANSCODING') || 'Transcoding';
	$params->{SETTINGS_PLAYBACK}     = string('SETTINGS_PLAYBACK') || 'Playback';
	$params->{GLOWSONIC_SCROBBLE}    = cstring($client, 'GLOWSONIC_SCROBBLE') || 'Scrobbling enabled';
}

1;
