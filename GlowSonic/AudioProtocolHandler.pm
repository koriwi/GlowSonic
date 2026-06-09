package Plugins::GlowSonic::AudioProtocolHandler;

use strict;
use warnings;

use Plugins::GlowSonic::ProtocolHandler;

# Separate class for glows:// single-track audio URLs. LMS attempts to load the
# registered protocol handler class from its matching .pm path, so this wrapper
# must exist as its own module rather than only as a package inside
# ProtocolHandler.pm.
sub new                 { shift; Plugins::GlowSonic::ProtocolHandler->new(@_) }
sub isRemote            { Plugins::GlowSonic::ProtocolHandler->isRemote(@_) }
sub canDirectStream     { Plugins::GlowSonic::ProtocolHandler->canDirectStream(@_) }
sub canDirectStreamSong { Plugins::GlowSonic::ProtocolHandler->canDirectStreamSong(@_) }
sub getFormatForURL     { shift; Plugins::GlowSonic::ProtocolHandler->getFormatForURL(@_) }
sub getNextTrack        { shift; Plugins::GlowSonic::ProtocolHandler->getNextTrack(@_) }
sub getMetadataFor      { shift; Plugins::GlowSonic::ProtocolHandler->getMetadataFor(@_) }

1;
