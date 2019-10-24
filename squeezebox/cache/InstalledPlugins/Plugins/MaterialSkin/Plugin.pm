package Plugins::MaterialSkin::Plugin;

#
# LMS-Material
#
# Copyright (c) 2018-2019 Craig Drummond <craig.p.drummond@gmail.com>
#
# MIT license.
#

use Config;
use Slim::Music::VirtualLibraries;
use Slim::Utils::Favorites;
use Slim::Utils::Log;
use Slim::Utils::Network;
use Slim::Utils::Prefs;
use JSON::XS::VersionOneAndTwo;
use Slim::Utils::Strings qw(string cstring);
use HTTP::Status qw(RC_NOT_FOUND RC_OK);
use File::Basename;
use File::Slurp qw(read_file);

my $log = Slim::Utils::Log->addLogCategory({
    'category' => 'plugin.material-skin',
    'defaultLevel' => 'ERROR',
    'description' => 'PLUGIN_MATERIAL_SKIN'
});

my $prefs = preferences('plugin.material-skin');
my $serverprefs = preferences('server');

my $URL_PARSER_RE = qr{material/svg/([a-z0-9-]+)}i;

my $DEFAULT_COMPOSER_GENRES = 'Classical, Avant-Garde, Baroque, Chamber Music, Chant, Choral, Classical Crossover, Early Music, High Classical, Impressionist, Jazz, Medieval, Minimalism, Modern Composition, Opera, Orchestral, Renaissance, Romantic, Symphony, Wedding Music';
my $DEFAULT_CONDUCTOR_GENRES = 'Classical, Avant-Garde, Baroque, Chamber Music, Chant, Choral, Classical Crossover, Early Music, High Classical, Impressionist, Medieval, Minimalism, Modern Composition, Opera, Orchestral, Renaissance, Romantic, Symphony, Wedding Music';

my @BROWSE_MODES = ( { id=>'myMusicArtists', name=>'BROWSE_BY_ARTIST', weight=>10},
                     { id=>'myMusicArtistsAlbumArtists', name=>'BROWSE_BY_ALBUMARTIST', weight=>9},
                     { id=>'myMusicArtistsAllArtists', name=>'BROWSE_BY_ALL_ARTISTS', weight=>11},
                     { id=>'myMusicAlbums', name=>'BROWSE_BY_ALBUM', weight=>20},
                     { id=>'myMusicGenres', name=>'BROWSE_BY_GENRE', weight=>30},
                     { id=>'myMusicYears', name=>'BROWSE_BY_YEAR', weight=>40},
                     { id=>'myMusicNewMusic', name=>'BROWSE_NEW_MUSIC', weight=>50},
                     { id=>'myMusicMusicFolder', name=>'BROWSE_MUSIC_FOLDER', weight=>70},
                     { id=>'myMusicPlaylists', name=>'SAVED_PLAYLISTS', weight=>80} );

my @EXTENDED_BROWSE_MODES = ( { id=>'myMusicAlbumsVariousArtists', name=>'PLUGIN_EXTENDED_BROWSEMODES_COMPILATIONS', weight=>22},
                              { id=>'myMusicFileSystem', name=>'PLUGIN_EXTENDED_BROWSEMODES_BROWSEFS', weight=>75},
                              { id=>'myMusicRandomAlbums', name=>'PLUGIN_EXTENDED_BROWSEMODES_RANDOM_ALBUMS', weight=>21} );

my @EXTENDED_BROWSE_STATS_MODES = ( { id=>'myMusicTopTracks', name=>'PLUGIN_EXTENDED_BROWSEMODES_TOP_TRACKS', weight=>68},
                                    { id=>'myMusicFlopTracks', name=>'PLUGIN_EXTENDED_BROWSEMODES_FLOP_TRACKS', weight=>69} );

sub initPlugin {
    my $class = shift;

    if (my $composergenres = $prefs->get('composergenres')) {
        $prefs->set('composergenres', $DEFAULT_COMPOSER_GENRES) if $composergenres eq '';
    }

    if (my $conductorgenres = $prefs->get('conductorgenres')) {
        $prefs->set('conductorgenres', $DEFAULT_CONDUCTOR_GENRES) if $conductorgenres eq '';
    }

    $prefs->init({
        composergenres => $DEFAULT_COMPOSER_GENRES,
        conductorgenres => $DEFAULT_CONDUCTOR_GENRES
    });

    if (main::WEBUI) {
        require Plugins::MaterialSkin::Settings;
		Plugins::MaterialSkin::Settings->new();

        Slim::Web::Pages->addPageFunction( 'desktop', sub {
            my ($client, $params) = @_;
            $params->{'material_revision'} = $class->pluginVersion();
            return Slim::Web::HTTP::filltemplatefile('desktop.html', $params);
        } );
        Slim::Web::Pages->addPageFunction( 'mini', sub {
            my ($client, $params) = @_;
            $params->{'material_revision'} = $class->pluginVersion();
            return Slim::Web::HTTP::filltemplatefile('mini.html', $params);
        } );
        Slim::Web::Pages->addPageFunction( 'now-playing', sub {
            my ($client, $params) = @_;
            $params->{'material_revision'} = $class->pluginVersion();
            return Slim::Web::HTTP::filltemplatefile('now-playing.html', $params);
        } );
        Slim::Web::Pages->addPageFunction( 'mobile', sub {
            my ($client, $params) = @_;
            $params->{'material_revision'} = $class->pluginVersion();
            return Slim::Web::HTTP::filltemplatefile('mobile.html', $params);
        } );
        Slim::Web::Pages->addRawFunction($URL_PARSER_RE, \&_svgHandler);

        # make sure scanner does pre-cache artwork in the size the skin is using in browse modesl
        Slim::Control::Request::executeRequest(undef, [ 'artworkspec', 'add', '300x300_f', 'Material Skin' ]);
    }

    $class->initCLI();
}

sub pluginVersion {
    my ($class) = @_;
    my $version = Slim::Utils::PluginManager->dataForPlugin($class)->{version};
    
    if ($version eq 'DEVELOPMENT') {
        # Try to get the git revision from which we're running
        if (my ($skinDir) = grep /MaterialSkin/, @{Slim::Web::HTTP::getSkinManager()->_getSkinDirs() || []}) {
            my $revision = `cd $skinDir && git show -s --format=%h\\|%ci 2> /dev/null`;
            if ($revision =~ /^([0-9a-f]+)\|(\d{4}-\d\d-\d\d.*)/i) {
                $version = 'GIT-' . $1;
            }
        }
    }

    if ($version eq 'DEVELOPMENT') {
        use POSIX qw(strftime);
        $datestring = strftime("%Y-%m-%d-%H-%M-%S", localtime);
        $version = "DEV-${datestring}";
    }

    return $version;
}

sub initCLI {
    #                                                            |requires Client
    #                                                            |  |is a Query
    #                                                            |  |  |has Tags
    #                                                            |  |  |  |Function to call
    #                                                            C  Q  T  F
    Slim::Control::Request::addDispatch(['material-skin', '_cmd'],
                                                                [0, 0, 1, \&_cliCommand]
    );
    Slim::Control::Request::addDispatch(['material-skin-presets', '_cmd'],
                                                                [1, 0, 1, \&_cliPresetCommand]
    );
    Slim::Control::Request::addDispatch(['material-skin-modes', '_cmd'],
                                                                [1, 0, 1, \&_cliModesCommand]
    );
}

sub _cliCommand {
    my $request = shift;

    # check this is the correct query.
    if ($request->isNotCommand([['material-skin']])) {
        $request->setStatusBadDispatch();
        return;
    }

    my $cmd = $request->getParam('_cmd');

    if ($request->paramUndefinedOrNotOneOf($cmd, ['moveplayer', 'info', 'movequeue', 'favorites', 'map', 'add-podcast', 'delete-podcast', 'plugins', 'plugins-status', 'plugins-update', 'delete-vlib']) ) {
        $request->setStatusBadParams();
        return;
    }

    if ($cmd eq 'moveplayer') {
        my $id = $request->getParam('id');
        my $serverurl = $request->getParam('serverurl');
        if (!$id || !$serverurl) {
            $request->setStatusBadParams();
            return;
        }

        # curl 'http://192.168.1.16:9000/jsonrpc.js' --data-binary '{"id":1,"method":"slim.request","params":["aa:aa:b5:38:e2:d7",["connect","192.168.1.66"]]}'
        my $http = Slim::Networking::SimpleAsyncHTTP->new(
            \&_connectDone,
            \&_connectError,
            {
                timeout => 10,
                server  => $server,
            }
        );

        my $postdata = to_json({
            id     => 1,
            method => 'slim.request',
            params => [ $id, ['connect', Slim::Utils::Network::serverAddr()] ]
        });

        main::INFOLOG && $log->is_info && $log->info('Connect player ${id} from ${serverurl} to this server');
        $http->post( $serverurl . 'jsonrpc.js', $postdata);
        $request->setStatusDone();
        return;
    }

    if ($cmd eq 'info') {
        my $osDetails = Slim::Utils::OSDetect::details();
        my $prefs = preferences('server');
        $request->addResult('info', '{"server":'
                                .'[ {"label":"' . cstring('', 'INFORMATION_VERSION') . '", "text":"' . $::VERSION . ' - ' . $::REVISION . ' @ ' . $::BUILDDATE . '"},'
                                .  '{"label":"' . cstring('', 'INFORMATION_HOSTNAME') . '", "text":"' . Slim::Utils::Network::hostName() . '"},'
                                .  '{"label":"' . cstring('', 'INFORMATION_SERVER_IP') . '", "text":"' . Slim::Utils::Network::serverAddr() . '"},'
                                .  '{"label":"' . cstring('', 'INFORMATION_OPERATINGSYSTEM') . '", "text":"' . $osDetails->{'osName'} . ' - ' . $prefs->get('language') . ' - ' . Slim::Utils::Unicode::currentLocale() . '"},'
                                .  '{"label":"' . cstring('', 'INFORMATION_ARCHITECTURE') . '", "text":"' . ($osDetails->{'osArch'} ? $osDetails->{'osArch'} : '?') . '"},'
                                .  '{"label":"' . cstring('', 'PERL_VERSION') . '", "text":"' . $Config{'version'} . ' - ' . $Config{'archname'} . '"},'
                                .  '{"label":"Audio::Scan", "text":"' . $Audio::Scan::VERSION . '"},'
                                .  '{"label":"IO::Socket::SSL", "text":"' . (Slim::Networking::Async::HTTP->hasSSL() ? $IO::Socket::SSL::VERSION : cstring($client, 'BLANK')) . '"}'

                                . ( Slim::Schema::hasLibrary() ? ', {"label":"' . cstring('', 'DATABASE_VERSION') . '", "text":"' . Slim::Utils::OSDetect->getOS->sqlHelperClass->sqlVersionLong( Slim::Schema->dbh ) . '"}' : '')

                                .']}');
        $request->setStatusDone();
        return;
    }

    if ($cmd eq 'movequeue') {
        my $fromId = $request->getParam('from');
        my $toId = $request->getParam('to');
        if (!$fromId || !$toId) {
            $request->setStatusBadParams();
            return;
        }
        my $from = Slim::Player::Client::getClient($fromId);
        my $to = Slim::Player::Client::getClient($toId);
        if (!$from || !$to) {
            $request->setStatusBadParams();
            return;
        }

        $to->execute(['power', 1]) unless $to->power;
        $from->execute(['sync', $toId]);
        if ( exists $INC{'Slim/Plugin/RandomPlay/Plugin.pm'} && (my $mix = Slim::Plugin::RandomPlay::Plugin::active($from)) ) {
            $to->execute(['playlist', 'addtracks', 'listRef', ['randomplay://' . $mix] ]);
        }
        $from->execute(['sync', '-']);
        $from->execute(['playlist', 'clear']);
        $from->execute(['power', 0]);

        $request->setStatusDone();
        return;
    }

    if ($cmd eq 'favorites') {
        my $cnt = 0;
        if (my $favsObject = Slim::Utils::Favorites->new()) {
            foreach my $fav (@{$favsObject->all}) {
                $request->addResultLoop("favs_loop", $cnt, "url", $fav->{url});
                $cnt++;
            }
        }
        $request->setStatusDone();
        return;
    }

    if ($cmd eq 'map') {
        my $genre = $request->getParam('genre');
        my $genre_id = $request->getParam('genre_id');
        my @list;
        my $sql;
        my $resp = "";
        my $resp_name;
        my $count = 0;
        my $dbh = Slim::Schema->dbh;
        my $col;
        if ($genre) {
            @list = split(/,/, $genre);
            $sql = $dbh->prepare_cached( qq{SELECT genres.id FROM genres WHERE name = ? LIMIT 1} );
            $resp_name = "genre_id";
            $col = 'id';
        } elsif ($genre_id) {
            @list = split(/,/, $genre_id);
            $sql = $dbh->prepare_cached( qq{SELECT genres.name FROM genres WHERE id = ? LIMIT 1} );
            $resp_name = "genre";
            $col = 'name';
        } else {
            $request->setStatusBadParams();
            return;
        }

        foreach my $g (@list) {
            $sql->execute($g);
            if ( my $result = $sql->fetchall_arrayref({}) ) {
                my $val = $result->[0]->{$col} if ref $result && scalar @$result;
                if ($val) {
                    if ($count>0) {
                        $resp = $resp . ",";
                    }
                    $resp=$resp . $val;
                    $count++;
                }
            }
        }
        $request->addResult($resp_name, $resp);
        $request->setStatusDone();
        return;
    }

    if ($cmd eq 'add-podcast') {
        my $name = $request->getParam('name');
        my $url = $request->getParam('url');
        if ($name && $url) {
            my $prefs = preferences('plugin.podcast');
            my $feeds = $prefs->get('feeds');
            push @{$feeds}, { 'name' => $name, 'value' => $url };
            $prefs->set(feeds => $feeds);
            $request->setStatusDone();
            return;
        }
    }

    if ($cmd eq 'delete-podcast') {
        my $pos = $request->getParam('pos');
        if ($pos) {
            my $prefs = preferences('plugin.podcast');
            my $feeds = $prefs->get('feeds');
            if ($pos < scalar @{$feeds}) {
                splice @{$feeds}, $pos, 1;
                $prefs->set(feeds => $feeds);
                $request->setStatusDone();
                return;
            }
        }
    }

    if ($cmd eq 'plugins') {
        my ($current, $active, $inactive, $hide) = Slim::Plugin::Extensions::Plugin::getCurrentPlugins();
        my $cnt = 0;
        foreach my $plugin (@{$active}) {
            $request->addResultLoop("plugins_loop", $cnt, "name", $plugin->{name});
            $request->addResultLoop("plugins_loop", $cnt, "title", $plugin->{title});
            $request->addResultLoop("plugins_loop", $cnt, "descr", $plugin->{desc});
            $request->addResultLoop("plugins_loop", $cnt, "creator", $plugin->{creator});
            $request->addResultLoop("plugins_loop", $cnt, "homepage", $plugin->{homepage});
            $request->addResultLoop("plugins_loop", $cnt, "email", $plugin->{email});
            $request->addResultLoop("plugins_loop", $cnt, "version", $plugin->{version});
            $cnt++;
        }
        $request->setStatusDone();
        return;
    }

    if ($cmd eq 'plugins-status') {
        $request->addResult("needs_restart", Slim::Utils::PluginManager->needsRestart ? 1 : 0);
        $request->addResult("downloading", Slim::Utils::PluginDownloader->downloading ? 1 : 0);
        $request->setStatusDone();
        return;
    }

    if ($cmd eq 'plugins-update') {
        my $json = $request->getParam('plugins');
        if ($json) {
            my $updating = 0;
            my $plugins = eval { from_json( $json ) };
            for my $plugin (@{$plugins}) {
                Slim::Utils::PluginDownloader->install({ name => $plugin->{'name'}, url => $plugin->{'url'}, sha => $plugin->{'sha'} });
                $updating++;
            }
            $request->addResult("updating", $updating);
            $request->setStatusDone();
            return;
        }
    }

    if ($cmd eq 'delete-vlib') {
        my $id = $request->getParam('id');
        if ($id) {
            Slim::Music::VirtualLibraries->unregisterLibrary($id);
            $request->setStatusDone();
            return;
        }
    }

    $request->setStatusBadParams();
}

sub _cliPresetCommand {
    my $request = shift;

    # check this is the correct query.
    if ($request->isNotCommand([['material-skin-presets']])) {
        $request->setStatusBadDispatch();
        return;
    }

    my $cmd = $request->getParam('_cmd');
    my $client = $request->client();
    if ($request->paramUndefinedOrNotOneOf($cmd, ['list', 'set', 'clear']) ) {
        $request->setStatusBadParams();
        return;
    }

    if ($cmd eq 'list') {
        my $presets = $serverprefs->client($client)->get('presets');
        my $cnt = 0;
        my $id = 1;
        foreach my $preset (@{$presets}) {
            if ($preset->{URL} && $preset->{type} eq 'audio') {
               $request->addResultLoop("presets_loop", $cnt, "url", $preset->{URL});
               $request->addResultLoop("presets_loop", $cnt, "text", $preset->{text});
               $request->addResultLoop("presets_loop", $cnt, "id", $client->id . '-' . $id);
               $request->addResultLoop("presets_loop", $cnt, "num", $id);
               $cnt++;
            }
            $id++;
        }
        $request->setStatusDone();
        return;
    }

    if ($cmd eq 'set') {
        my $presets = $serverprefs->client($client)->get('presets');
        my $num = $request->getParam('num');
        my $prev = $request->getParam('prev');
        my $text = $request->getParam('text');
        my $url = $request->getParam('url');
        if (!$num || !$url) {
            $request->setStatusBadParams();
            return;
        }
        my $val = int($num);
        if ($val<1 || $val>10) {
            $request->setStatusBadParams();
            return;
        }
        if ($prev) {
            # If this is a move, then copy contents at destination to source
            my $prevval = int($prev);
            if ($prevval>=1 && $prevval<=10) {
                $presets->[$prevval-1] = $presets->[$val-1];
            }
        }
        $presets->[$val-1] = { URL => $url, text => $text || '', type => 'audio'};
        $serverprefs->client($client)->set('presets', $presets);
        $request->setStatusDone();
        return;
    }

    if ($cmd eq 'clear') {
        my $presets = $serverprefs->client($client)->get('presets');
        my $num = $request->getParam('num');
        if (!$num) {
            $request->setStatusBadParams();
            return;
        }
        my $val = int($num);
        if ($val<1 || $val>10) {
            $request->setStatusBadParams();
            return;
        }
        $presets->[$val-1] = { };
        $serverprefs->client($client)->set('presets', $presets);
        $request->setStatusDone();
        return;
    }

    $request->setStatusBadParams()
}

sub _cliModesCommand {
    my $request = shift;

    # check this is the correct query.
    if ($request->isNotCommand([['material-skin-modes']])) {
        $request->setStatusBadDispatch();
        return;
    }

    my $cmd = $request->getParam('_cmd');
    my $client = $request->client();
    if ($request->paramUndefinedOrNotOneOf($cmd, ['get', 'set', 'set-group']) ) {
        $request->setStatusBadParams();
        return;
    }

    if ($cmd eq 'get') {
        my $cnt = 0;
        my $clientPrefs = $serverprefs->client($client);
        my $pluginPrefs = preferences('plugin.extendedbrowsemodes');
        if ($pluginPrefs) {
            my $additionalMenuItems = $pluginPrefs->get('additionalMenuItems');
            if ($additionalMenuItems) {
                foreach my $additionalMenuItem (@{$additionalMenuItems}) {
                    $request->addResultLoop("modes_loop", $cnt, "id", $additionalMenuItem->{id});
                    $request->addResultLoop("modes_loop", $cnt, "name", $additionalMenuItem->{name});
                    $request->addResultLoop("modes_loop", $cnt, "weight", $additionalMenuItem->{weight});
                    $request->addResultLoop("modes_loop", $cnt, "enabled", $clientPrefs->get("disabled_" . $additionalMenuItem->{id}) ? 0 : 1);
                    $cnt++;
                }
            }
        }

        foreach my $mode (@BROWSE_MODES) {
            $request->addResultLoop("modes_loop", $cnt, "id", $mode->{id});
            $request->addResultLoop("modes_loop", $cnt, "name", cstring('', $mode->{name}));
            $request->addResultLoop("modes_loop", $cnt, "weight", $mode->{weight});
            $request->addResultLoop("modes_loop", $cnt, "enabled", $clientPrefs->get("disabled_" . $mode->{id}) ? 0 : 1);
            $cnt++;
        }

        foreach my $mode (@EXTENDED_BROWSE_MODES) {
            $request->addResultLoop("modes_loop", $cnt, "id", $mode->{id});
            $request->addResultLoop("modes_loop", $cnt, "name", cstring('', $mode->{name}));
            $request->addResultLoop("modes_loop", $cnt, "weight", $mode->{weight});
            $request->addResultLoop("modes_loop", $cnt, "enabled", $clientPrefs->get("disabled_" . $mode->{id}) ? 0 : 1);
            $cnt++;
        }

        if (main::STATISTICS) {
            foreach my $mode (@EXTENDED_BROWSE_STATS_MODES) {
                $request->addResultLoop("modes_loop", $cnt, "id", $mode->{id});
                $request->addResultLoop("modes_loop", $cnt, "name", cstring('', $mode->{name}));
                $request->addResultLoop("modes_loop", $cnt, "weight", $mode->{weight});
                $request->addResultLoop("modes_loop", $cnt, "enabled", $clientPrefs->get("disabled_" . $mode->{id}) ? 0 : 1);
                $cnt++;
            }
        }

        $request->setStatusDone();
        return;
    }

    if ($cmd eq 'set') {
        my $enabled = $request->getParam('enabled');
        my $disabled = $request->getParam('disabled');
        if ($enabled || $disabled) {
            my $clientPrefs = $serverprefs->client($client);
            if ($enabled) {
                @list = split(/,/, $enabled);
                foreach my $mode (@list) {
                    $clientPrefs->set("disabled_" . $mode, 0);
                }
            }
            if ($disabled) {
                @list = split(/,/, $disabled);
                foreach my $mode (@list) {
                    $clientPrefs->set("disabled_" . $mode, 1);
                }
            }

            $request->setStatusDone();
            return;
        }
    }

    if ($cmd eq 'set-group') {
        # Set group player's enabled browse modes to the enabled modes of all members
        my $groupsPluginPrefs = preferences('plugin.groups');
        my $group = $groupsPluginPrefs->client($client);
        if ($group) {
            my $members = $group->get('members');
            if ($members) {
                my $groupPrefs = $serverprefs->client($client);
                my $ebmPluginPrefs = preferences('plugin.extendedbrowsemodes');
                my $additionalMenuItems = $ebmPluginPrefs->get('additionalMenuItems');
                my %modes;
                # Set all modes as disabled
                if ($additionalMenuItems) {
                    foreach my $additionalMenuItem (@{$additionalMenuItems}) {
                        $modes{ $additionalMenuItem->{id} } = 1;
                    }
                }
                foreach my $mode (@BROWSE_MODES) {
                    $modes{ $mode->{id} } = 1;
                }

                foreach my $mode (@EXTENDED_BROWSE_MODES) {
                    $modes{ $mode->{id} } = 1;
                }

                if (main::STATISTICS) {
                    foreach my $mode (@EXTENDED_BROWSE_STATS_MODES) {
                        $modes{ $mode->{id} } = 1;
                    }
                }

                # iterate over all clients, and set mode to enabled if enabled for client
                foreach my $id (@{$members}) {
                    my $member = Slim::Player::Client::getClient($id);
                    my $clientPrefs = $serverprefs->client($member);
                    if ($additionalMenuItems) {
                        foreach my $additionalMenuItem (@{$additionalMenuItems}) {
                            if ($clientPrefs->get("disabled_" . $additionalMenuItem->{id})==0) {
                                $modes{ $additionalMenuItem->{id} } = 0;
                            }
                        }
                    }

                    foreach my $mode (@BROWSE_MODES) {
                        if ($clientPrefs->get("disabled_" . $mode->{id})==0) {
                            $modes{ $mode->{id} } = 0;
                        }
                    }

                    foreach my $mode (@EXTENDED_BROWSE_MODES) {
                        if ($clientPrefs->get("disabled_" . $mode->{id})==0) {
                            $modes{ $mode->{id} } = 0;
                        }
                    }

                    if (main::STATISTICS) {
                        foreach my $mode (@EXTENDED_BROWSE_STATS_MODES) {
                            if ($clientPrefs->get("disabled_" . $mode->{id})==0) {
                                $modes{ $mode->{id} } = 0;
                            }
                        }
                    }
                }

                # update group prefs
                my @keys = keys %modes;
                for my $key (@keys) {
                    $groupPrefs->set("disabled_" . $key, $modes{$key});
                }

                $request->setStatusDone();
                return;
            }
        }
    }

    $request->setStatusBadParams()
}

sub _connectDone {
    main::INFOLOG && $log->is_info && $log->info('Connect response recieved player');
    # curl 'http://localhost:9000/jsonrpc.js' --data-binary '{"id":1,"method":"slim.request","params":["aa:aa:b5:38:e2:d7",["disconnect","192.168.1.16"]]}'
    my $http   = shift;
    my $server = $http->params('server');
    my $res = eval { from_json( $http->content ) };

    if ( $@ || ref $res ne 'HASH' || $res->{error} ) {
        $http->error( $@ || 'Invalid JSON response: ' . $http->content );
        return _players_error( $http );
    }

    my @params = @{$res->{params}};
    my $id = $params[0];
    my $buddy = Slim::Player::Client::getClient($id);
    if ($buddy) {
        main::INFOLOG && $log->is_info && $log->info('Disconnect player ' . $id . ' from ' . $server);
        $buddy->execute(["disconnect", $server]);
    }
}

sub _connectError {
    # Ignore?
}

sub _svgHandler {
    my ( $httpClient, $response ) = @_;
    return unless $httpClient->connected;

    my $request = $response->request;
    my $dir = dirname(__FILE__);
    my $filePath = $dir . "/HTML/material/html/images/" . basename($request->uri->path) . ".svg";
    my $colour = "#f00";

    if ($request->uri->can('query_param')) {
        $colour = "#" . $request->uri->query_param('c');
    } else { # Manually extract "c=colour" query parameter...
        my $uri = $request->uri->as_string;
        my $start = index($uri, "c=");

        if ($start > 0) {
            $start += 2;
            my $end = index($uri, "&", $start);
            if ($end > $start) {
                $colour = "#" . substr($uri, $start, $end-$start);
            } else {
                $colour = "#" . substr($uri, $start);
            }
        }
    }

    if (-e $filePath) {
        my $svg = read_file($filePath);
        $svg =~ s/#000/$colour/g;
        $response->code(RC_OK);
        $response->content_type('image/svg+xml');
        $response->header('Connection' => 'close');
        $response->content($svg);
    } else {
        $response->code(RC_NOT_FOUND);
    }
    $httpClient->send_response($response);
    Slim::Web::HTTP::closeHTTPSocket($httpClient);
}

1;
