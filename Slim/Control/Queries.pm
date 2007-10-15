package Slim::Control::Queries;

# $Id:  $
#
# SqueezeCenter Copyright (c) 2001-2007 Logitech.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.

################################################################################

=head1 NAME

Slim::Control::Queries

=head1 DESCRIPTION

L<Slim::Control::Queries> implements most SqueezeCenter queries and is designed to 
 be exclusively called through Request.pm and the mechanisms it defines.

 Except for subscribe-able queries (such as status and serverstatus), there are no
 important differences between the code for a query and one for
 a command. Please check the commented command in Commands.pm.

=cut

use strict;

use Scalar::Util qw(blessed);
use URI::Escape;

use Slim::Utils::Misc qw( specified validMacAddress );
use Slim::Utils::Alarms;
use Slim::Utils::Log;
use Slim::Utils::Unicode;
use Slim::Utils::Prefs;

my $log = logger('control.queries');

my $prefs = preferences('server');

sub alarmsQuery {
	my $request = shift;

	$log->debug("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['alarms']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get our parameters
	my $client   = $request->client();
	my $index    = $request->getParam('_index');
	my $quantity = $request->getParam('_quantity');
	my $filter	 = $request->getParam('filter');
	my $alarmDOW = $request->getParam('dow');
	
	
	if ($request->paramNotOneOfIfDefined($filter, ['all', 'defined', 'enabled'])) {
		$request->setStatusBadParams();
		return;
	}
	
	my @results;

	if (defined $alarmDOW) {

		$results[0] = Slim::Utils::Alarms->newLoaded($client, $alarmDOW);

	} else {

		my $i = 0;

		$filter = 'enabled' if !defined $filter;

		for $alarmDOW (0..7) {

			my $alarm = Slim::Utils::Alarms->newLoaded($client, $alarmDOW);
			
			my $wanted = ( 
				($filter eq 'all') ||
				($filter eq 'defined' && !$alarm->undefined()) ||
				($filter eq 'enabled' && $alarm->enabled())
			);

			$results[$i++] = $alarm if $wanted;
		}
	}

	my $count = scalar @results;

	$request->addResult('fade', $prefs->client($client)->get('alarmfadeseconds'));
	$count += 0;
	$request->addResult('count', $count);

	my ($valid, $start, $end) = $request->normalize(scalar($index), scalar($quantity), $count);

	if ($valid) {

		my $loopname = 'alarms_loop';
		my $cnt = 0;
		
		for my $eachitem (@results[$start..$end]) {
			$request->addResultLoop($loopname, $cnt, 'dow', $eachitem->dow());
			$request->addResultLoop($loopname, $cnt, 'enabled', $eachitem->enabled());
			$request->addResultLoop($loopname, $cnt, 'time', $eachitem->time());
			$request->addResultLoop($loopname, $cnt, 'volume', $eachitem->volume());
			$request->addResultLoop($loopname, $cnt, 'url', $eachitem->playlist());
			$request->addResultLoop($loopname, $cnt, 'playlist_id', $eachitem->playlistid());
			$cnt++;
		}
	}

	$request->setStatusDone();
}


sub albumsQuery {
	my $request = shift;

	$log->debug("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['albums']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get our parameters
	my $index         = $request->getParam('_index');
	my $quantity      = $request->getParam('_quantity');
	my $tags          = $request->getParam('tags');
	my $search        = $request->getParam('search');
	my $compilation   = $request->getParam('compilation');
	my $contributorID = $request->getParam('artist_id');
	my $genreID       = $request->getParam('genre_id');
	my $trackID       = $request->getParam('track_id');
	my $year          = $request->getParam('year');
	my $sort          = $request->getParam('sort');
	my $menu          = $request->getParam('menu');
	my $insert        = $request->getParam('menu_all');
	
	if ($request->paramNotOneOfIfDefined($sort, ['new', 'album'])) {
		$request->setStatusBadParams();
		return;
	}

	# menu/jive mgmt
	my $menuMode = defined $menu;
	my $insertAll = $menuMode && defined $insert;

	if (!defined $tags) {
		$tags = 'l';
	}
	
	# get them all by default
	my $where = {};
	my $attr = {};
	
	# Normalize and add any search parameters
	if (defined $trackID) {
		$where->{'tracks.id'} = $trackID;
		push @{$attr->{'join'}}, 'tracks';
	}
	
	# ignore everything if $track_id was specified
	else {
	
		if ($sort && $sort eq 'new') {

			$attr->{'order_by'} = 'tracks.timestamp desc, tracks.disc, tracks.tracknum, tracks.titlesort';
			push @{$attr->{'join'}}, 'tracks';
		}
		
		if (specified($search)) {
			$where->{'me.titlesearch'} = {'like', Slim::Utils::Text::searchStringSplit($search)};
		}
		
		if (defined $year) {
			$where->{'me.year'} = $year;
		}
		
		# Manage joins
		if (defined $contributorID){
		
			# handle the case where we're asked for the VA id => return compilations
			if ($contributorID == Slim::Schema->variousArtistsObject->id) {
				$compilation = 1;
			}
			else {	
				$where->{'contributorAlbums.contributor'} = $contributorID;
				push @{$attr->{'join'}}, 'contributorAlbums';
				$attr->{'distinct'} = 1;
			}			
		}
	
		if (defined $genreID){
			$where->{'genreTracks.genre'} = $genreID;
			push @{$attr->{'join'}}, {'tracks' => 'genreTracks'};
			$attr->{'distinct'} = 1;
		}
	
		if (defined $compilation) {
			if ($compilation == 1) {
				$where->{'me.compilation'} = 1;
			}
			if ($compilation == 0) {
				$where->{'me.compilation'} = [ { 'is' => undef }, { '=' => 0 } ];
			}
		}
	}
	
	# use the browse standard additions, sort and filters, and complete with 
	# our stuff
	my $rs = Slim::Schema->rs('Album')->browse->search($where, $attr);

	my $count = $rs->count;

	# now build the result
	
	if ($menuMode) {

		# decide what is the next step down
		# generally, we go to tracks after albums, so we get menu:track
		# from the tracks we'll go to songinfo
		my $actioncmd = $menu . 's';
		my $nextMenu = 'songinfo';
		
		# build the base element
		my $base = {
			'actions' => {
				'go' => {
					'cmd' => [$actioncmd],
					'params' => {
						'menu' => $nextMenu,
						'menu_all' => '1',
						'sort' => 'tracknum',
					},
					'itemsParams' => 'params',
				},
				'play' => {
					'player' => 0,
					'cmd' => ['playlistcontrol'],
					'params' => {
						'cmd' => 'load',
					},
					'itemsParams' => 'params',
				},
				'add' => {
					'player' => 0,
					'cmd' => ['playlistcontrol'],
					'params' => {
						'cmd' => 'add',
					},
					'itemsParams' => 'params',
				},
			},
			'window' => {
				'titleStyle' => "album",
			}
		};
		
		# adapt actions to SS preference
		if (!$prefs->get('noGenreFilter') && defined $genreID) {
			$base->{'actions'}->{'go'}->{'params'}->{'genre_id'} = $genreID;
			$base->{'actions'}->{'play'}->{'params'}->{'genre_id'} = $genreID;
			$base->{'actions'}->{'add'}->{'params'}->{'genre_id'} = $genreID;
		}
		$request->addResult('base', $base);
		# add 1 to count if we are adding a 'Play All'
		$count++ if $insertAll;
	}
	
	if (Slim::Music::Import->stillScanning()) {
		$request->addResult('rescan', 1);
	}

	$count += 0;
	$request->addResult('count', $count);

	my ($valid, $start, $end) = $request->normalize(scalar($index), scalar($quantity), $count);

	if ($valid) {

		my $loopname = $menuMode?'item_loop':'albums_loop';
		my $cnt = 0;
		$request->addResult('offset', $start) if $menuMode;

		# first PLAY ALL item
		if ($insertAll) {
			($start, $end, $cnt) = _playAll($start, $end, $cnt, $request, $loopname);
		}

		for my $eachitem ($rs->slice($start, $end)) {
			
			# Jive result formatting
			if ($menuMode) {
				
				# we want the text to be album\nartist
				my @artists = $eachitem->artists();
				my $artist = $artists[0]->name();
				my $text = $eachitem->title;
				if (defined $artist) {
					$text = $text . "\n" . $artist;
				}
				$request->addResultLoop($loopname, $cnt, 'text', $text);
				
				my $id = $eachitem->id();
				$id += 0;
				my $params = {
					'album_id' =>  $id, 
				};
				$request->addResultLoop($loopname, $cnt, 'params', $params);

				# artwork if we have it
				if (defined(my $iconId = $eachitem->artwork())) {
					$iconId += 0;
					$request->addResultLoop($loopname, $cnt, 'icon-id', $iconId);
				}
			}
			
			# "raw" result formatting (for CLI or JSON RPC)
			else {
				$request->addResultLoop($loopname, $cnt, 'id', $eachitem->id);
				$tags =~ /l/ && $request->addResultLoop($loopname, $cnt, 'album', $eachitem->title);
				$tags =~ /y/ && $request->addResultLoopIfValueDefined($loopname, $cnt, 'year', $eachitem->year);
				$tags =~ /j/ && $request->addResultLoopIfValueDefined($loopname, $cnt, 'artwork_track_id', $eachitem->artwork);
				$tags =~ /t/ && $request->addResultLoop($loopname, $cnt, 'title', $eachitem->rawtitle);
				$tags =~ /i/ && $request->addResultLoopIfValueDefined($loopname, $cnt, 'disc', $eachitem->disc);
				$tags =~ /q/ && $request->addResultLoopIfValueDefined($loopname, $cnt, 'disccount', $eachitem->discc);
				$tags =~ /w/ && $request->addResultLoopIfValueDefined($loopname, $cnt, 'compilation', $eachitem->compilation);
				if ($tags =~ /a/) {
					my @artists = $eachitem->artists();
					$request->addResultLoopIfValueDefined($loopname, $cnt, 'artist', $artists[0]->name());
				}
			}
			
			$cnt++;
		}
	}

	$request->setStatusDone();
}


sub artistsQuery {
	my $request = shift;

	$log->debug("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['artists']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get our parameters
	my $index    = $request->getParam('_index');
	my $quantity = $request->getParam('_quantity');
	my $search   = $request->getParam('search');
	my $year     = $request->getParam('year');
	my $genreID  = $request->getParam('genre_id');
	my $trackID  = $request->getParam('track_id');
	my $albumID  = $request->getParam('album_id');
	my $menu     = $request->getParam('menu');
	my $insert   = $request->getParam('menu_all');
	
	# menu/jive mgmt
	my $menuMode = defined $menu;
	my $insertAll = $menuMode && defined $insert;
	
	# get them all by default
	my $where = {};
	
	# sort them
	my $attr = {
		'order_by' => 'me.namesort',
		'distinct' => 'me.id'
	};
	
	# same for the VA search
	my $where_va = {'me.compilation' => 1};
	my $attr_va = {};

 	# Normalize any search parameters
 	if (specified($search)) {
 
 		$where->{'me.namesearch'} = {'like', Slim::Utils::Text::searchStringSplit($search)};
 	}

	my $rs;

	# Manage joins 
	if (defined $trackID) {
		$where->{'contributorTracks.track'} = $trackID;
		push @{$attr->{'join'}}, 'contributorTracks';
		
		# don't use browse here as it filters VA...
		$rs = Slim::Schema->rs('Contributor')->search($where, $attr);
	}
	else {
		if (defined $genreID) {
			$where->{'genreTracks.genre'} = $genreID;
			push @{$attr->{'join'}}, {'contributorTracks' => {'track' => 'genreTracks'}};
			
			$where_va->{'genreTracks.genre'} = $genreID;
			push @{$attr_va->{'join'}}, {'tracks' => 'genreTracks'};
		}
		
		if (defined $albumID || defined $year) {
		
			if (defined $albumID) {
				$where->{'track.album'} = $albumID;
				
				$where_va->{'me.id'} = $albumID;
			}
			
			if (defined $year) {
				$where->{'track.year'} = $year;
				
				$where_va->{'track.year'} = $year;
			}
			
			if (!defined $genreID) {
				# don't need to add track again if we have a genre search
				push @{$attr->{'join'}}, {'contributorTracks' => 'track'};

				# same logic for VA search
				if (defined $year) {
					push @{$attr->{'join'}}, 'track';
				}
			}
		}
		
		# use browse here
		$rs = Slim::Schema->rs('Contributor')->browse->search($where, $attr);
	}
	
	# Various artist handling. Don't do if pref is off, or if we're
	# searching, or if we have a track
	my $count_va = 0;

	if ($prefs->get('variousArtistAutoIdentification') &&
		!defined $search && !defined $trackID) {

		# Only show VA item if there are any
		$count_va =  Slim::Schema->rs('Album')->search($where_va, $attr_va)->count;
	}

	my $count = $rs->count + ($count_va?1:0);


	# now build the result
	
	if ($menuMode) {

		# decide what is the next step down
		# generally, we go to albums after artists, so we get menu:album
		# from the albums we'll go to tracks
		my $actioncmd = $menu . 's';
		my $nextMenu = 'track';
		
		# build the base element
		my $base = {
			'actions' => {
				'go' => {
					'cmd' => [$actioncmd],
					'params' => {
						menu     => $nextMenu,
						menu_all => '1',
					},
					'itemsParams' => 'params'
				},
				'play' => {
					'player' => 0,
					'cmd' => ['playlistcontrol'],
					'params' => {
						'cmd' => 'load',
					},
					'itemsParams' => 'params'
				},
				'add' => {
					'player' => 0,
					'cmd' => ['playlistcontrol'],
					'params' => {
						'cmd' => 'add',
					},
					'itemsParams' => 'params'
				},
			},
			# style correctly the window that opens for the action element
			'window' => {
				'menuStyle'  => 'album',
				'titleStyle' => 'mymusic',
			}
		};
		if (!$prefs->get('noGenreFilter') && defined $genreID) {
			$base->{'actions'}->{'go'}->{'params'}->{'genre_id'} = $genreID;
			$base->{'actions'}->{'play'}->{'params'}->{'genre_id'} = $genreID;
			$base->{'actions'}->{'add'}->{'params'}->{'genre_id'} = $genreID;
		}
		$request->addResult('base', $base);

		# correct count if we insert "Play all"
		$count++ if $insertAll;

	}
	
	if (Slim::Music::Import->stillScanning()) {
		$request->addResult('rescan', 1);
	}

	$count += 0;
	$request->addResult('count', $count);

	my ($valid, $start, $end) = $request->normalize(scalar($index), scalar($quantity), $count);

	if ($valid || $count) {

		my $loopname = $menuMode?'item_loop':'artists_loop';
		my $cnt = 0;
		$request->addResult('offset', $start) if $menuMode;

		my @data = $rs->slice($start, $end);
		
		# Various artist handling. Don't do if pref is off, or if we're
		# searching, or if we have a track
		if ($count_va) {
			unshift @data, Slim::Schema->variousArtistsObject;
		}

		# first PLAY ALL item
		if ($insertAll) {
			($start, $end, $cnt) = _playAll($start, $end, $cnt, $request, $loopname);
		}

		for my $obj (@data) {

			my $id = $obj->id();
			$id += 0;

			if ($menuMode){
				$request->addResultLoop($loopname, $cnt, 'text', $obj->name);
				my $params = {
					'artist_id' => $id, 
				};
				$request->addResultLoop($loopname, $cnt, 'params', $params);
			}
			else {
				$request->addResultLoop($loopname, $cnt, 'id', $id);
				$request->addResultLoop($loopname, $cnt, 'artist', $obj->name);
			}

			$cnt++;
		}
	}

	$request->setStatusDone();
}


sub cursonginfoQuery {
	my $request = shift;
	
	$log->debug("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['duration', 'artist', 'album', 'title', 'genre',
			'path', 'remote', 'current_title']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	my $client = $request->client();

	# get the query
	my $method = $request->getRequest(0);
	my $url = Slim::Player::Playlist::url($client);
	
	if (defined $url) {

		if ($method eq 'path') {
			
			$request->addResult("_$method", $url);

		} elsif ($method eq 'remote') {
			
			$request->addResult("_$method", 
				Slim::Music::Info::isRemoteURL($url));
			
		} elsif ($method eq 'current_title') {
			
			$request->addResult("_$method", 
				Slim::Music::Info::getCurrentTitle($client, $url));

		} else {

			my $track = Slim::Schema->rs('Track')->objectForUrl($url);

			if (!blessed($track) || !$track->can('secs')) {

				logBacktrace("Couldn't fetch object for URL: [$url] - skipping track.");

			} else {

				if ($method eq 'duration') {

					$request->addResult("_$method", $track->secs() || 0);

				} elsif ($method eq 'album' || $method eq 'artist' || $method eq 'genre') {

					$request->addResult("_$method", $track->$method->name || 0);

				} else {

					$request->addResult("_$method", $track->$method() || 0);
				}
			}
		}
	}

	$request->setStatusDone();
}


sub connectedQuery {
	my $request = shift;
	
	$log->debug("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['connected']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	# get our parameters
	my $client = $request->client();
	
	$request->addResult('_connected', $client->connected() || 0);
	
	$request->setStatusDone();
}


sub debugQuery {
	my $request = shift;
	
	$log->debug("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['debug']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	# get our parameters
	my $category = $request->getParam('_debugflag');

	if ( !defined $category || !Slim::Utils::Log->isValidCategory($category) ) {

		$request->setStatusBadParams();
		return;
	}

	my $categories = Slim::Utils::Log->allCategories;
	
	if (defined $categories->{$category}) {
	
		$request->addResult('_value', $categories->{$category});
		
		$request->setStatusDone();

	} else {

		$request->setStatusBadParams();
	}
}


sub displayQuery {
	my $request = shift;
	
	$log->debug("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['display']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	# get our parameters
	my $client = $request->client();
	
	my $parsed = $client->parseLines($client->curLines());

	$request->addResult('_line1', $parsed->{line}[0] || '');
	$request->addResult('_line2', $parsed->{line}[1] || '');
		
	$request->setStatusDone();
}


sub displaynowQuery {
	my $request = shift;
	
	$log->debug("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['displaynow']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	# get our parameters
	my $client = $request->client();

	$request->addResult('_line1', $client->prevline1());
	$request->addResult('_line2', $client->prevline2());
		
	$request->setStatusDone();
}


sub displaystatusQuery_filter {
	my $self = shift;
	my $request = shift;

	# we only listen to display messages
	return 0 if !$request->isCommand([['displaynotify']]);

	# retrieve the clientid, abort if not about us
	my $clientid = $request->clientid();
	return 0 if !defined $clientid;
	return 0 if $clientid ne $self->clientid();

	my $subs  = $self->getParam('subscribe');
	my $type  = $request->getParam('_type');
	my $parts = $request->getParam('_parts');

	# check displaynotify type against subscription ('showbriefly', 'update', 'bits', 'all')
	if ($subs eq $type || ($subs eq 'bits' && $type ne 'showbriefly') || $subs eq 'all') {

		my $pd = $self->privateData;

		# display forwarding is suppressed for this subscriber source
		return 0 if exists $parts->{ $pd->{'format'} } && !$parts->{ $pd->{'format'} };

		# don't send updates if there is no change
		return 0 if ($type eq 'update' && !$self->client->display->renderCache->{'screen1'}->{'changed'});

		# store display info in subscription request so it can be accessed by displaystatusQuery
		$pd->{'type'}  = $type;
		$pd->{'parts'} = $parts;

		# execute the query immediately
		$self->__autoexecute;
	}

	return 0;
}

sub displaystatusQuery {
	my $request = shift;
	
	$log->debug("displaystatusQuery()");

	# check this is the correct query
	if ($request->isNotQuery([['displaystatus']])) {
		$request->setStatusBadDispatch();
		return;
	}

	my $subs  = $request->getParam('subscribe');

	# return any previously stored display info from displaynotify
	if (my $pd = $request->privateData) {

		my $client= $request->client;
		my $format= $pd->{'format'};
		my $type  = $pd->{'type'};
		my $parts = $type eq 'showbriefly' ? $pd->{'parts'} : $client->display->renderCache;

		$request->addResult('type', $type);

		# return screen1 info if more than one screen
		$parts = $parts->{'screen1'} if $parts->{'screen1'};

		if ($subs eq 'bits' && $parts->{'bitsref'}) {
			
			# send the display bitmap if it exists (graphics display)
			use bytes;

			my $bits = ${$parts->{'bitsref'}};
			if ($parts->{'scroll'}) {
				$bits |= substr(${$parts->{'scrollbitsref'}}, 0, $parts->{'overlaystart'}[$parts->{'scrollline'}]);
			}

			$request->addResult('bits', MIME::Base64::encode_base64($bits) );
			$request->addResult('ext', $parts->{'extent'});

		} elsif ($format eq 'cli') {

			# format display for cli
			for my $c (keys %$parts) {
				next unless $c =~ /^(line|center|overlay)$/;
				for my $l (0..$#{$parts->{$c}}) {
					$request->addResult("$c$l", $parts->{$c}[$l]) if ($parts->{$c}[$l] ne '');
				}
			}

		} elsif ($format eq 'jive') {

			# send display to jive from one of the following components
			if (my $ref = $parts->{'jive'} && ref $parts->{'jive'}) {
				if ($ref eq 'CODE') {
					$request->addResult('display', $parts->{'jive'}->() );
				} elsif($ref eq 'ARRAY') {
					$request->addResult('display', { 'text' => $parts->{'jive'} });
				} else {
					$request->addResult('display', $parts->{'jive'} );
				}
			} else {
				$request->addResult('display', { 'text' => $parts->{'line'} || $parts->{'center'} });
			}
		}

	} elsif ($subs =~ /showbriefly|update|bits|all/) {
		# new subscription request - add subscription, assume cli or jive format for the moment
		$request->privateData({ 'format' => $request->source eq 'CLI' ? 'cli' : 'jive' }); 

		if ($subs eq 'bits') {

			$request->registerAutoExecute(0, \&displaystatusQuery_filter, sub {
				$request->client->display->widthOverride(1, undef);
				$request->client->display->notifyLevel(0);
				$request->client->update;
			});
			$request->client->display->widthOverride(1, $request->getParam('width'));

		} else {

			$request->registerAutoExecute(0, \&displaystatusQuery_filter, sub {
				$request->client->display->notifyLevel(0);
			});
		}

		if ($subs eq 'showbriefly') {
			$request->client->display->notifyLevel(1);
		} else {
			$request->client->display->notifyLevel(2);
			$request->client->update;
		}
	}
	
	$request->setStatusDone();
}


sub genresQuery {
	my $request = shift;

	$log->debug("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['genres']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get our parameters
	my $index         = $request->getParam('_index');
	my $quantity      = $request->getParam('_quantity');
	my $search        = $request->getParam('search');
	my $year          = $request->getParam('year');
	my $contributorID = $request->getParam('artist_id');
	my $albumID       = $request->getParam('album_id');
	my $trackID       = $request->getParam('track_id');
	my $menu          = $request->getParam('menu');
	my $insert        = $request->getParam('menu_all');
	
	# menu/jive mgmt
	my $menuMode  = defined $menu;
	my $insertAll = $menuMode && defined $insert;
		
	# get them all by default
	my $where = {};
	
	# sort them
	my $attr = {
		'distinct' => 'me.id'
	};

	# Normalize and add any search parameters
	if (specified($search)) {

		$where->{'me.namesearch'} = {'like', Slim::Utils::Text::searchStringSplit($search)};
	}

	# Manage joins
	if (defined $trackID) {
			$where->{'genreTracks.track'} = $trackID;
			push @{$attr->{'join'}}, 'genreTracks';
	}
	else {
		# ignore those if we have a track. 
		
		if (defined $contributorID){
		
			# handle the case where we're asked for the VA id => return compilations
			if ($contributorID == Slim::Schema->variousArtistsObject->id) {
				$where->{'album.compilation'} = 1;
				push @{$attr->{'join'}}, {'genreTracks' => {'track' => 'album'}};
			}
			else {	
				$where->{'contributorTracks.contributor'} = $contributorID;
				push @{$attr->{'join'}}, {'genreTracks' => {'track' => 'contributorTracks'}};
			}
		}
	
		if (defined $albumID || defined $year){
			if (defined $albumID) {
				$where->{'track.album'} = $albumID;
			}
			if (defined $year) {
				$where->{'track.year'} = $year;
			}
			push @{$attr->{'join'}}, {'genreTracks' => 'track'};
		}
	}

	my $rs = Slim::Schema->resultset('Genre')->browse->search($where, $attr);

	my $count = $rs->count;

	# now build the result
	
	if ($menuMode) {

		# decide what is the next step down
		# generally, we go to artists after genres, so we get menu:artist
		# from the artists we'll go to albums
		my $actioncmd = $menu . 's';
		my $nextMenu = 'album';
		
		# build the base element
		my $base = {
			'actions' => {
				'go' => {
					'cmd' => [$actioncmd],
					'params' => {
						menu     => $nextMenu,
						menu_all => '1',
					},
					'itemsParams' => 'params',
				},
				'play' => {
					'player' => 0,
					'cmd' => ['playlistcontrol'],
					'params' => {
						'cmd' => 'load',
					},
					'itemsParams' => 'params',
				},
				'add' => {
					'player' => 0,
					'cmd' => ['playlistcontrol'],
					'params' => {
						'cmd' => 'add',
					},
					'itemsParams' => 'params',
				},
			},
			window => { titleStyle => 'mymusic', },
		};
		$request->addResult('base', $base);
		$count++ if $insertAll;
	}
	
	if (Slim::Music::Import->stillScanning()) {
		$request->addResult('rescan', 1);
	}

	$count += 0;
	$request->addResult('count', $count);

	my ($valid, $start, $end) = $request->normalize(scalar($index), scalar($quantity), $count);

	if ($valid) {

		my $loopname = $menuMode?'item_loop':'genres_loop';
		my $cnt = 0;
		$request->addResult('offset', $start) if $menuMode;
		
		if ($insertAll) {
			($start, $end, $cnt) = _playAll($start, $end, $cnt, $request, $loopname);
		}
		for my $eachitem ($rs->slice($start, $end)) {
			
			my $id = $eachitem->id();
			$id += 0;
			
			if ($menuMode) {
				$request->addResultLoop($loopname, $cnt, 'text', $eachitem->name);
				
				my $params = {
					'genre_id' =>  $id, 
				};
				$request->addResultLoop($loopname, $cnt, 'params', $params);
			}
			else {
				$request->addResultLoop($loopname, $cnt, 'id', $id);
				$request->addResultLoop($loopname, $cnt, 'genre', $eachitem->name);
			}
			$cnt++;
		}
	}

	$request->setStatusDone();
}


sub infoTotalQuery {
	my $request = shift;
	
	$log->debug("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['info'], ['total'], ['genres', 'artists', 'albums', 'songs']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	# get our parameters
	my $entity = $request->getRequest(2);

	if ($entity eq 'albums') {
		$request->addResult("_$entity", Slim::Schema->count('Album'));
	}

	if ($entity eq 'artists') {
		$request->addResult("_$entity", Slim::Schema->rs('Contributor')->browse->count);
	}

	if ($entity eq 'genres') {
		$request->addResult("_$entity", Slim::Schema->count('Genre'));
	}

	if ($entity eq 'songs') {
		$request->addResult("_$entity", Slim::Schema->rs('Track')->browse->count);
	}
	
	$request->setStatusDone();
}


sub linesperscreenQuery {
	my $request = shift;
	
	$log->debug("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['linesperscreen']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	# get our parameters
	my $client = $request->client();

	$request->addResult('_linesperscreen', $client->linesPerScreen());
	
	$request->setStatusDone();
}


sub mixerQuery {
	my $request = shift;
	
	$log->debug("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['mixer'], ['volume', 'muting', 'treble', 'bass', 'pitch']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get our parameters
	my $client = $request->client();
	my $entity = $request->getRequest(1);

	if ($entity eq 'muting') {
		$request->addResult("_$entity", $prefs->client($client)->get("mute"));
	}
	elsif ($entity eq 'volume') {
		$request->addResult("_$entity", $prefs->client($client)->get("volume"));
	} else {
		$request->addResult("_$entity", $client->$entity());
	}
	
	$request->setStatusDone();
}


sub modeQuery {
	my $request = shift;
	
	$log->debug("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['mode']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	# get our parameters
	my $client = $request->client();

	$request->addResult('_mode', Slim::Player::Source::playmode($client));
	
	$request->setStatusDone();
}


sub musicfolderQuery {
	my $request = shift;
	
	$log->debug("musicfolderQuery()");

	# check this is the correct query.
	if ($request->isNotQuery([['musicfolder']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	# get our parameters
	my $index    = $request->getParam('_index');
	my $quantity = $request->getParam('_quantity');
	my $folderId = $request->getParam('folder_id');
	my $url      = $request->getParam('url');
	my $menu     = $request->getParam('menu');
	my $insert   = $request->getParam('menu_all');
	
	# menu/jive mgmt
	my $menuMode  = defined $menu;
	my $insertAll = $menuMode && defined $insert;
	
	# url overrides any folderId
	my $params = ();
	
	if (defined $url) {
		$params->{'url'} = $url;
	} else {
		# findAndScanDirectory sorts it out if $folderId is undef
		$params->{'id'} = $folderId;
	}
	
	# Pull the directory list, which will be used for looping.
	my ($topLevelObj, $items, $count) = Slim::Utils::Misc::findAndScanDirectoryTree($params);

	# create filtered data
	
	my $topPath = $topLevelObj->path;
	my $osName  = Slim::Utils::OSDetect::OS();
	my @data;

	for my $relPath (@$items) {

		$log->debug("relPath: $relPath" );
		
		my $url  = Slim::Utils::Misc::fixPath($relPath, $topPath) || next;

		$log->debug("url: $url" );

		# Amazingly, this just works. :)
		# Do the cheap compare for osName first - so non-windows users
		# won't take the penalty for the lookup.
		if ($osName eq 'win' && Slim::Music::Info::isWinShortcut($url)) {
			$url = Slim::Utils::Misc::fileURLFromWinShortcut($url);
		}
	
		my $item = Slim::Schema->rs('Track')->objectForUrl({
			'url'      => $url,
			'create'   => 1,
			'readTags' => 1,
		});
	
		if (!blessed($item) || !$item->can('content_type')) {

			next;
		}

		# Bug: 1360 - Don't show files referenced in a cuesheet
		next if ($item->content_type eq 'cur');

		push @data, $item;
	}

	$count = scalar(@data);

	# now build the result
	
	if ($menuMode) {

		# decide what is the next step down
		# assume we have a folder, for other types we will override in the item
		# we go to musicfolder from musicfolder :)

		# build the base element
		my $base = {
			'actions' => {
				'go' => {
					'cmd' => ["musicfolder"],
					'params' => {
						menu     => 'musicfolder',
						menu_all => '1',
					},
					'itemsParams' => 'params',
				},
				'play' => {
					'player' => 0,
					'cmd' => ['playlistcontrol'],
					'params' => {
						'cmd' => 'load',
					},
					'itemsParams' => 'params',
				},
				'add' => {
					'player' => 0,
					'cmd' => ['playlistcontrol'],
					'params' => {
						'cmd' => 'add',
					},
					'itemsParams' => 'params',
				},
			},
			window => {
				titleStyle => 'mymusic',
			},
		};
		$request->addResult('base', $base);
		$count++ if $insertAll;
	}

	if (Slim::Music::Import->stillScanning()) {
		$request->addResult("rescan", 1);
	}

	$count += 0;
	$request->addResult('count', $count);

	my ($valid, $start, $end) = $request->normalize(
		scalar($index), scalar($quantity), $count
	);

	if ($valid) {
		
		my $loopname =  $menuMode?'item_loop':'folder_loop';
		my $cnt = 0;
		$request->addResult('offset', $start) if $menuMode;
		
		if ($insertAll) {
			($start, $end, $cnt) = _playAll($start, $end, $cnt, $request, $loopname);
		}
		for my $eachitem (@data[$start..$end]) {
			
			my $filename = Slim::Music::Info::fileName($eachitem->url());
			my $id = $eachitem->id();
			$id += 0;
			
			if ($menuMode) {
				$request->addResultLoop($loopname, $cnt, 'text', $filename);
				
				# each item is different, but most items are folders
				# the base assumes so above, we override it here
				

				# assumed case, folder
				if (Slim::Music::Info::isDir($eachitem)) {

					my $params = {
						'folder_id' => $id, 
					};
					$request->addResultLoop($loopname, $cnt, 'params', $params);

				# playlist
				} elsif (Slim::Music::Info::isPlaylist($eachitem)) {
					
					my $actions = {
						'go' => {
							'cmd' => ['playlists', 'tracks'],
							'params' => {
								menu        => 'songinfo',
								menu_all    => '1',
								playlist_id => $id,
							},
						},
						'play' => {
							'player' => 0,
							'cmd' => ['playlistcontrol'],
							'params' => {
								'cmd' => 'load',
								'playlist_id' => $id,
							},
						},
						'add' => {
							'player' => 0,
							'cmd' => ['playlistcontrol'],
							'params' => {
								'cmd' => 'add',
								'playlist_id' => $id,
							},
						},
					};
					$request->addResultLoop($loopname, $cnt, 'actions', $actions);

				# song
				} elsif (Slim::Music::Info::isSong($eachitem)) {
					
					my $actions = {
						'go' => {
							'cmd' => ['songinfo'],
							'params' => {
								'menu' => 'nowhere',
								'track_id' => $id,
							},
						},
						'play' => {
							'player' => 0,
							'cmd' => ['playlistcontrol'],
							'params' => {
								'cmd' => 'load',
								'track_id' => $id,
							},
						},
						'add' => {
							'player' => 0,
							'cmd' => ['playlistcontrol'],
							'params' => {
								'cmd' => 'add',
								'track_id' => $id,
							},
						},
					};
					$request->addResultLoop($loopname, $cnt, 'actions', $actions);

				# not sure
				} else {
					
					# don't know what that is, abort!
					my $actions = {
						'go' => {
							'cmd' => ["musicfolder"],
							'params' => {
								'menu' => 'musicfolder',
							},
							'itemsParams' => 'params',
						},
						'play' => {
							'player' => 0,
							'cmd' => ['playlistcontrol'],
							'params' => {
								'cmd' => 'load',
							},
							'itemsParams' => 'params',
						},
						'add' => {
							'player' => 0,
							'cmd' => ['playlistcontrol'],
							'params' => {
								'cmd' => 'add',
							},
							'itemsParams' => 'params',
						},
					};
					$request->addResultLoop($loopname, $cnt, 'actions', $actions);
				}
			}
			else {
				$request->addResultLoop($loopname, $cnt, 'id', $id);
				$request->addResultLoop($loopname, $cnt, 'filename', $filename);
			
				if (Slim::Music::Info::isDir($eachitem)) {
					$request->addResultLoop($loopname, $cnt, 'type', 'folder');
				} elsif (Slim::Music::Info::isPlaylist($eachitem)) {
					$request->addResultLoop($loopname, $cnt, 'type', 'playlist');
				} elsif (Slim::Music::Info::isSong($eachitem)) {
					$request->addResultLoop($loopname, $cnt, 'type', 'track');
				} else {
					$request->addResultLoop($loopname, $cnt, 'type', 'unknown');
				}
			}
			$cnt++;
		}
	}

	# we might have changed - flush to the db to be in sync.
	$topLevelObj->update;
	
	$request->setStatusDone();
}


sub nameQuery {
	my $request = shift;

	$log->debug("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['name']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	# get our parameters
	my $client = $request->client();

	$request->addResult("_value", $client->name());
	
	$request->setStatusDone();
}


sub playerXQuery {
	my $request = shift;

	$log->debug("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['player'], ['count', 'name', 'address', 'ip', 'id', 'model', 'displaytype']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	# get our parameters
	my $entity;
	$entity      = $request->getRequest(1);
	# if element 1 is 'player', that means next element is the entity
	$entity      = $request->getRequest(2) if $entity eq 'player';  
	my $clientparam = $request->getParam('_IDorIndex');
	
	if ($entity eq 'count') {
		$request->addResult("_$entity", Slim::Player::Client::clientCount());

	} else {	
		my $client;
		
		# were we passed an ID?
		if (defined $clientparam && Slim::Utils::Misc::validMacAddress($clientparam)) {

			$client = Slim::Player::Client::getClient($clientparam);

		} else {
		
			# otherwise, try for an index
			my @clients = Slim::Player::Client::clients();

			if (defined $clientparam && defined $clients[$clientparam]) {
				$client = $clients[$clientparam];
			}
		}
		
		if (defined $client) {

			if ($entity eq "name") {
				$request->addResult("_$entity", $client->name());
			} elsif ($entity eq "address" || $entity eq "id") {
				$request->addResult("_$entity", $client->id());
			} elsif ($entity eq "ip") {
				$request->addResult("_$entity", $client->ipport());
			} elsif ($entity eq "model") {
				$request->addResult("_$entity", $client->model());
			} elsif ($entity eq "displaytype") {
				$request->addResult("_$entity", $client->vfdmodel());
			}
		}
	}
	
	$request->setStatusDone();
}

sub playersQuery {
	my $request = shift;

	$log->debug("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['players']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	# get our parameters
	my $index    = $request->getParam('_index');
	my $quantity = $request->getParam('_quantity');
	
	my @prefs;
	
	if (defined(my $pref_list = $request->getParam('playerprefs'))) {

		# split on commas
		@prefs = split(/,/, $pref_list);
	}
	
	my $count = Slim::Player::Client::clientCount();
	$count += 0;
	$request->addResult('count', $count);

	my ($valid, $start, $end) = $request->normalize(scalar($index), scalar($quantity), $count);

	if ($valid) {
		my $idx = $start;
		my $cnt = 0;
		my @players = Slim::Player::Client::clients();

		if (scalar(@players) > 0) {

			for my $eachclient (@players[$start..$end]) {
				$request->addResultLoop('players_loop', $cnt, 
					'playerindex', $idx);
				$request->addResultLoop('players_loop', $cnt, 
					'playerid', $eachclient->id());
				$request->addResultLoop('players_loop', $cnt, 
					'ip', $eachclient->ipport());
				$request->addResultLoop('players_loop', $cnt, 
					'name', $eachclient->name());
				$request->addResultLoop('players_loop', $cnt, 
					'model', $eachclient->model());
				$request->addResultLoop('players_loop', $cnt, 
					'displaytype', $eachclient->vfdmodel())
					unless ($eachclient->model() eq 'http');
				$request->addResultLoop('players_loop', $cnt, 
					'connected', ($eachclient->connected() || 0));

				for my $pref (@prefs) {
					if (defined(my $value = $prefs->client($eachclient)->get($pref))) {
						$request->addResultLoop('players_loop', $cnt, 
							$pref, $value);
					}
				}
					
				$idx++;
				$cnt++;
			}	
		}
	}
	
	$request->setStatusDone();
}


sub playlistPlaylistsinfoQuery {
	my $request = shift;
	
	$log->debug("Begin Function");

	# check this is the correct query
	if ($request->isNotQuery([['playlist'], ['playlistsinfo']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	# get the parameters
	my $client = $request->client();

	my $playlistObj = $client->currentPlaylist();
	
	if (blessed($playlistObj)) {
		if ($playlistObj->can('id')) {
			$request->addResult("id", $playlistObj->id());
		}

		$request->addResult("name", $playlistObj->title());
				
		$request->addResult("modified", $client->currentPlaylistModified());

		$request->addResult("url", $playlistObj->url());
	}
	
	$request->setStatusDone();
}


sub playlistXQuery {
	my $request = shift;
	
	$log->debug("Begin Function");

	# check this is the correct query
	if ($request->isNotQuery([['playlist'], ['name', 'url', 'modified', 
			'tracks', 'duration', 'artist', 'album', 'title', 'genre', 'path', 
			'repeat', 'shuffle', 'index', 'jump', 'remote']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	# get the parameters
	my $client = $request->client();
	my $entity = $request->getRequest(1);
	my $index  = $request->getParam('_index');
		
	if ($entity eq 'repeat') {
		$request->addResult("_$entity", Slim::Player::Playlist::repeat($client));

	} elsif ($entity eq 'shuffle') {
		$request->addResult("_$entity", Slim::Player::Playlist::shuffle($client));

	} elsif ($entity eq 'index' || $entity eq 'jump') {
		$request->addResult("_$entity", Slim::Player::Source::playingSongIndex($client));

	} elsif ($entity eq 'name' && defined(my $playlistObj = $client->currentPlaylist())) {
		$request->addResult("_$entity", Slim::Music::Info::standardTitle($client, $playlistObj));

	} elsif ($entity eq 'url') {
		my $result = $client->currentPlaylist();
		$request->addResult("_$entity", $result);

	} elsif ($entity eq 'modified') {
		$request->addResult("_$entity", $client->currentPlaylistModified());

	} elsif ($entity eq 'tracks') {
		$request->addResult("_$entity", Slim::Player::Playlist::count($client));

	} elsif ($entity eq 'path') {
		my $result = Slim::Player::Playlist::url($client, $index);
		$request->addResult("_$entity",  $result || 0);

	} elsif ($entity eq 'remote') {
		if (defined (my $url = Slim::Player::Playlist::url($client, $index))) {
			$request->addResult("_$entity", Slim::Music::Info::isRemoteURL($url));
		}
		
	} elsif ($entity =~ /(duration|artist|album|title|genre)/) {

		my $track = Slim::Schema->rs('Track')->objectForUrl({
			'url'      => Slim::Player::Playlist::song($client, $index),
			'create'   => 1,
			'readTags' => 1,
		});

		if (blessed($track) && $track->can('secs')) {

			# Just call the method on Track
			if ($entity eq 'duration') {

				$request->addResult("_$entity", $track->secs());
			
			} elsif ($entity eq 'album' || $entity eq 'artist' || $entity eq 'genre') {

				$request->addResult("_$entity", $track->$entity->name || 0);

			} else {

				$request->addResult("_$entity", $track->$entity());
			}
		}
	}
	
	$request->setStatusDone();
}


sub playlistsTracksQuery {
	my $request = shift;

	$log->debug("Begin Function");

	# check this is the correct query.
	# "playlisttracks" is deprecated (July 06).
	if ($request->isNotQuery([['playlisttracks']]) &&
		$request->isNotQuery([['playlists'], ['tracks']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get our parameters
	my $tags       = 'gald';
	my $index      = $request->getParam('_index');
	my $quantity   = $request->getParam('_quantity');
	my $tagsprm    = $request->getParam('tags');
	my $playlistID = $request->getParam('playlist_id');

	if (!defined $playlistID) {
		$request->setStatusBadParams();
		return;
	}
	my $menu          = $request->getParam('menu');
	
	# menu/jive mgmt
	my $menuMode = defined $menu;
		
	# did we have override on the defaults?
	$tags = $tagsprm if defined $tagsprm;

	my $iterator;
	my @tracks;

	my $playlistObj = Slim::Schema->find('Playlist', $playlistID);

	if (blessed($playlistObj) && $playlistObj->can('tracks')) {
		$iterator = $playlistObj->tracks();
	}

	# now build the result
	
	if ($menuMode) {

		# decide what is the next step down
		# generally, we go to songingo after playlists tracks, so we get menu:songinfo
		# from the artists we'll go to albums

		# build the base element
		my $base = {
			'actions' => {
				'go' => {
					'cmd' => ['songinfo'],
					'params' => {
						'menu' => 'nowhere',
					},
					'itemsParams' => 'params',
				},
				'play' => {
					'player' => 0,
					'cmd' => ['playlistcontrol'],
					'params' => {
						'cmd' => 'load',
					},
					'itemsParams' => 'params',
				},
				'add' => {
					'player' => 0,
					'cmd' => ['playlistcontrol'],
					'params' => {
						'cmd' => 'add',
					},
					'itemsParams' => 'params',
				},
			},
		};
		$request->addResult('base', $base);
	}

	if (Slim::Music::Import->stillScanning()) {
		$request->addResult("rescan", 1);
	}

	if (defined $iterator) {

		my $count = $iterator->count();

		$count += 0;
		$request->addResult("count", $count);
		
		my ($valid, $start, $end) = $request->normalize(scalar($index), scalar($quantity), $count);

		if ($valid) {

			my $format = $prefs->get('titleFormat')->[ $prefs->get('titleFormatWeb') ];
			my $cur = $start;
			my $loopname = $menuMode?'item_loop':'playlisttracks_loop';
			my $cnt = 0;
			$request->addResult('offset', $start) if $menuMode;
			
			for my $eachitem ($iterator->slice($start, $end)) {

				if ($menuMode) {
					
					my $text = Slim::Music::TitleFormatter::infoFormat($eachitem, $format, 'TITLE');
					$request->addResultLoop($loopname, $cnt, 'text', $text);
					my $id = $eachitem->id();
					$id += 0;
					my $params = {
						'track_id' =>  $id, 
					};
					$request->addResultLoop($loopname, $cnt, 'params', $params);

				}
				else {
					_addSong($request, $loopname, $cnt, $eachitem, $tags, 
							"playlist index", $cur);
				}
				
				$cur++;
				$cnt++;
			}
		}

	} else {

		$request->addResult("count", 0);
	}

	$request->setStatusDone();	
}


sub playlistsQuery {
	my $request = shift;

	$log->debug("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['playlists']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get our parameters
	my $index    = $request->getParam('_index');
	my $quantity = $request->getParam('_quantity');
	my $search	 = $request->getParam('search');
	my $tags     = $request->getParam('tags') || '';
	my $menu     = $request->getParam('menu');
	my $insert   = $request->getParam('menu_all');
	
	# menu/jive mgmt
	my $menuMode  = defined $menu;
	my $insertAll = $menuMode && defined $insert;

	# Normalize any search parameters
	if (defined $search) {
		$search = Slim::Utils::Text::searchStringSplit($search);
	}

	my $rs = Slim::Schema->rs('Playlist')->getPlaylists('all', $search);

	# now build the result
	my $count = $rs->count;
	
	if ($menuMode) {

		# decide what is the next step down
		# generally, we go to playlists tracks after playlists, so we get menu:track
		# from the tracks we'll go to songinfo
		
		# build the base element
		my $base = {
			'actions' => {
				'go' => {
					'cmd' => ['playlists', 'tracks'],
					'params' => {
						menu     => 'songinfo',
						menu_all => '1',
					},
					'itemsParams' => 'params',
				},
				'play' => {
					'player' => 0,
					'cmd' => ['playlistcontrol'],
					'params' => {
						'cmd' => 'load',
					},
					'itemsParams' => 'params',
				},
				'add' => {
					'player' => 0,
					'cmd' => ['playlistcontrol'],
					'params' => {
						'cmd' => 'add',
					},
					'itemsParams' => 'params',
				},
			},
			window => {
				titleStyle => 'mymusic',
			},
		};
		$request->addResult('base', $base);
		$count++ if $insertAll;
	}

	if (Slim::Music::Import->stillScanning()) {
		$request->addResult("rescan", 1);
	}

	if (defined $rs) {

	
		$count += 0;
		$request->addResult("count", $count);
		
		my ($valid, $start, $end) = $request->normalize(
			scalar($index), scalar($quantity), $count);

		if ($valid) {
			
			my $loopname = $menuMode?'item_loop':'playlists_loop';
			my $cnt = 0;
			$request->addResult('offset', $start) if $menuMode;

			if ($insertAll) {
				($start, $end, $cnt) = _playAll($start, $end, $cnt, $request, $loopname);
			}

			for my $eachitem ($rs->slice($start, $end)) {

				my $id = $eachitem->id();
				$id += 0;

				if ($menuMode) {
					$request->addResultLoop($loopname, $cnt, 'text', $eachitem->title);
					my $params = {
						'playlist_id' =>  $id, 
					};
					$request->addResultLoop($loopname, $cnt, 'params', $params);
				}
				else {
					$request->addResultLoop($loopname, $cnt, "id", $id);
					$request->addResultLoop($loopname, $cnt, "playlist", $eachitem->title);
					$request->addResultLoop($loopname, $cnt, "url", $eachitem->url) if ($tags =~ /u/);
				}
				$cnt++;
			}
		}
	}
	else {
		$request->addResult("count", 0);
	} 
	
	$request->setStatusDone();
}


sub playerprefQuery {
	my $request = shift;
	
	$log->debug("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['playerpref']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	# get the parameters
	my $client   = $request->client();
	my $prefName = $request->getParam('_prefname');

	# split pref name from namespace: name.space.pref:
	my $namespace = 'server';
	if ($prefName =~ /^(.*):(\w+)$/) {
		$namespace = $1;
		$prefName = $2;
	}
	
	if (!defined $prefName || !defined $namespace) {
		$request->setStatusBadParams();
		return;
	}

	$request->addResult('_p2', preferences($namespace)->client($client)->get($prefName));
	
	$request->setStatusDone();
}


sub playerprefValidateQuery {
	my $request = shift;
	
	$log->debug("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['playerpref'], ['validate']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get our parameters
	my $client   = $request->client();
	my $prefName = $request->getParam('_prefname');
	my $newValue = $request->getParam('_newvalue');

	# split pref name from namespace: name.space.pref:
	my $namespace = 'server';
	if ($prefName =~ /^(.*):(\w+)$/) {
		$namespace = $1;
		$prefName = $2;
	}
	
	if (!defined $prefName || !defined $namespace || !defined $newValue) {
		$request->setStatusBadParams();
		return;
	}

	$request->addResult('valid', preferences($namespace)->client($client)->validate($prefName, $newValue) ? 1 : 0);
	
	$request->setStatusDone();
}


sub powerQuery {
	my $request = shift;
	
	$log->debug("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['power']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	# get the parameters
	my $client = $request->client();

	$request->addResult('_power', $client->power());
	
	$request->setStatusDone();
}


sub prefQuery {
	my $request = shift;
	
	$log->debug("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['pref']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	# get the parameters
	my $prefName = $request->getParam('_prefname');

	# split pref name from namespace: name.space.pref:
	my $namespace = 'server';
	if ($prefName =~ /^(.*):(\w+)$/) {
		$namespace = $1;
		$prefName = $2;
	}
	
	if (!defined $prefName || !defined $namespace) {
		$request->setStatusBadParams();
		return;
	}

	$request->addResult('_p2', preferences($namespace)->get($prefName));
	
	$request->setStatusDone();
}


sub prefValidateQuery {
	my $request = shift;
	
	$log->debug("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['pref'], ['validate']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get our parameters
	my $prefName = $request->getParam('_prefname');
	my $newValue = $request->getParam('_newvalue');

	# split pref name from namespace: name.space.pref:
	my $namespace = 'server';
	if ($prefName =~ /^(.*):(\w+)$/) {
		$namespace = $1;
		$prefName = $2;
	}
	
	if (!defined $prefName || !defined $namespace || !defined $newValue) {
		$request->setStatusBadParams();
		return;
	}

	$request->addResult('valid', preferences($namespace)->validate($prefName, $newValue) ? 1 : 0);
	
	$request->setStatusDone();
}


sub rateQuery {
	my $request = shift;
	
	$log->debug("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['rate']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	# get the parameters
	my $client = $request->client();

	$request->addResult('_rate', Slim::Player::Source::rate($client));
	
	$request->setStatusDone();
}


sub readDirectoryQuery {
	my $request = shift;

	$log->debug("readDirectoryQuery");

	# check this is the correct query.
	if ($request->isNotQuery([['readdirectory']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get our parameters
	my $index        = $request->getParam('_index');
	my $quantity     = $request->getParam('_quantity');
	my $folder       = $request->getParam('folder');
	my $filter       = $request->getParam('filter');

	use File::Spec::Functions qw(catdir);
	my @fsitems;
	if ($folder eq '/' && Slim::Utils::OSDetect::OS() eq 'win') {
		@fsitems = map { "$_:" } grep /^[^AB]/i, Win32::DriveInfo::DrivesInUse();
		$folder = '';
	}
	else {
		$filter ||= '';

		my $filterRE = qr/./;

		# search within filename
		if ($filter =~ /^filename:(.*)/) {
			$filterRE = qr/$1/i;
		}
		elsif ($filter =~ /^filetype:(.*)/) {
			$filterRE = qr/\.(?:$1)$/;
		}

		# get file system items in $folder
		@fsitems = Slim::Utils::Misc::readDirectory(catdir($folder), $filterRE);

		if ($filter =~ /^foldersonly$/) {
			@fsitems = grep { -d catdir($folder, $_) } @fsitems;
		}
		elsif ($filter =~ /^filesonly$/) {
			@fsitems = grep { -f catdir($folder, $_) } @fsitems;
		}
		# search anywhere within path/filename
		elsif ($filter && $filter !~ /^(?:filename|filetype):/) {
			@fsitems = grep { catdir($folder, $_) =~ /$filter/i } @fsitems;
		}
	}

	my $count = @fsitems;
	$count += 0;
	$request->addResult('count', $count);

	my ($valid, $start, $end) = $request->normalize(scalar($index), scalar($quantity), $count);

	if ($valid) {
		my $idx = $start;
		my $cnt = 0;

		if (scalar(@fsitems) > 0) {
			# sort folders < files
			@fsitems = sort { 
				my $aa = catdir($folder, $a);
				my $bb = catdir($folder, $b);
		
				if (-d $aa) {
					if (-d $bb) { uc($a) cmp uc($b) }
					else { -1 }
				}
				else {
					if (-d $bb) { 1 }
					else { uc($a) cmp uc($b) }
				}
			} @fsitems;

			my $path;
			for my $item (@fsitems[$start..$end]) {
				$path = $folder ? catdir($folder, $item) : $item;

				$request->addResultLoop('fsitems_loop', $cnt, 'path', $path);
				$request->addResultLoop('fsitems_loop', $cnt, 'name', $item );
				$request->addResultLoop('fsitems_loop', $cnt, 'isfolder', -d $path || 0);

				$idx++;
				$cnt++;
			}	
		}
	}

	$request->setStatusDone();	
}


sub rescanQuery {
	my $request = shift;
	
	$log->debug("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['rescan']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# no params for the rescan query

	$request->addResult('_rescan', Slim::Music::Import->stillScanning() ? 1 : 0);
	
	$request->setStatusDone();
}


sub rescanprogressQuery {
	my $request = shift;
	
	$log->debug("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['rescanprogress']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# no params for the rescanprogress query

	if (Slim::Music::Import->stillScanning) {
		$request->addResult('rescan', 1);

		# get progress from DB
		my $args = {
			'type' => 'importer',
		};

		my @progress = Slim::Schema->rs('Progress')->search( $args, { 'order_by' => 'start,id' } )->all;

		# calculate total elapsed time
		my $total_time = 0;
		for my $p (@progress) {
			my $runtime = ($p->finish || time()) - $p->start;
			$total_time += $runtime;
		}

		# report it
		my $hrs  = int($total_time / 3600);
		my $mins = int(($total_time - $hrs * 60)/60);
		my $sec  = $total_time - 3600 * $hrs - 60 * $mins;
		$request->addResult('totaltime', sprintf("%02d:%02d:%02d", $hrs, $mins, $sec));

		# now indicate % completion for all importers
		for my $p (@progress) {

			my $percComplete = $p->finish ? 100 : $p->total ? $p->done / $p->total * 100 : -1;
			$request->addResult($p->name(), int($percComplete));
		}
	
	# if we're not scanning, just say so...
	} else {
		$request->addResult('rescan', 0);
	}

	$request->setStatusDone();
}


sub searchQuery {
	my $request = shift;

	$log->debug("Begin Function");

	# check this is the correct query
	if ($request->isNotQuery([['search']])) {
		$request->setStatusBadDispatch();
		return;
	}

	my $index    = $request->getParam('_index');
	my $quantity = $request->getParam('_quantity');
	my $query    = $request->getParam('term');

	if (!defined $query || $query eq '') {
		$request->setStatusBadParams();
		return;
	}

	if (Slim::Music::Import->stillScanning) {
		$request->addResult('rescan', 1);
	}

	my $totalCount = 0;
	my $search     = Slim::Utils::Text::searchStringSplit($query);
	my %results    = ();
	my @types      = Slim::Schema->searchTypes;

	# Ugh - we need two loops here, as "count" needs to come first.
	for my $type (@types) {

		my $rs      = Slim::Schema->rs($type)->searchNames($search);
		my $count   = $rs->count || 0;

		$results{$type}->{'rs'}    = $rs;
		$results{$type}->{'count'} = $count;

		$totalCount += $count;
	}

	$totalCount += 0;
	$request->addResult('count', $totalCount);

	for my $type (@types) {

		my $count = $results{$type}->{'count'};

		$count += 0;
		$request->addResult("${type}s_count", $count);

		my $loopName  = "${type}s_loop";
		my $loopCount = 0;

		for my $result ($results{$type}->{'rs'}->slice(0, $quantity)) {

			# add result to loop
			$request->addResultLoop($loopName, $loopCount, "${type}_id", $result->id);
			$request->addResultLoop($loopName, $loopCount, $type, $result->name);

			$loopCount++;
		}
	}
	
	$request->setStatusDone();
}


# the filter function decides, based on a notified request, if the serverstatus
# query must be re-executed.
sub serverstatusQuery_filter {
	my $self = shift;
	my $request = shift;
	
	# we want to know about rescan and all client notifs, as well as power on/off
	# FIXME: wipecache and rescan are synonyms...
	if ($request->isCommand([['wipecache', 'rescan', 'client', 'power']])) {
		return 1.3;
	}
	
	# FIXME: prefset???
	# we want to know about any pref in our array
	if (defined(my $prefsPtr = $self->privateData()->{'server'})) {
		if ($request->isCommand([['pref']])) {
			if (defined(my $reqpref = $request->getParam('_prefname'))) {
				if (grep($reqpref, @{$prefsPtr})) {
					return 1.3;
				}
			}
		}
	}
	if (defined(my $prefsPtr = $self->privateData()->{'player'})) {
		if ($request->isCommand([['playerpref']])) {
			if (defined(my $reqpref = $request->getParam('_prefname'))) {
				if (grep($reqpref, @{$prefsPtr})) {
					return 1.3;
				}
			}
		}
	}
	if ($request->isCommand([['name']])) {
		return 1.3;
	}
	
	return 0;
}


sub serverstatusQuery {
	my $request = shift;
	
	$log->debug("serverstatusQuery()");

	# check this is the correct query
	if ($request->isNotQuery([['serverstatus']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	if (Slim::Music::Import->stillScanning()) {
		$request->addResult('rescan', "1");
		if (my $p = Slim::Schema->rs('Progress')->search({ 'type' => 'importer', 'active' => 1 })->first) {

			$request->addResult('progressname', Slim::Utils::Strings::string($p->name."_PROGRESS"));
			$request->addResult('progressdone', $p->done);
			$request->addResult('progresstotal', $p->total);
		}
	}
	
	# add version
	$request->addResult('version', $::VERSION);

	# add totals
	$request->addResult("info total albums", Slim::Schema->count('Album'));
	$request->addResult("info total artists", Slim::Schema->rs('Contributor')->browse->count);
	$request->addResult("info total genres", Slim::Schema->count('Genre'));
	$request->addResult("info total songs", Slim::Schema->rs('Track')->browse->count);

	my %savePrefs;
	if (defined(my $pref_list = $request->getParam('prefs'))) {

		# split on commas
		my @prefs = split(/,/, $pref_list);
		$savePrefs{'server'} = \@prefs;
	
		for my $pref (@{$savePrefs{'server'}}) {
			if (defined(my $value = $prefs->get($pref))) {
				$request->addResult($pref, $value);
			}
		}
	}
	if (defined(my $pref_list = $request->getParam('playerprefs'))) {

		# split on commas
		my @prefs = split(/,/, $pref_list);
		$savePrefs{'player'} = \@prefs;
		
	}


	# get our parameters
	my $index    = $request->getParam('_index');
	my $quantity = $request->getParam('_quantity');
	
	my $count = Slim::Player::Client::clientCount();
	$count += 0;
	$request->addResult('player count', $count);

	my ($valid, $start, $end) = $request->normalize(scalar($index), scalar($quantity), $count);

	if ($valid) {
		my $cnt = 0;
		my @players = Slim::Player::Client::clients();

		if (scalar(@players) > 0) {

			for my $eachclient (@players[$start..$end]) {
				$request->addResultLoop('players_loop', $cnt, 
					'playerid', $eachclient->id());
				$request->addResultLoop('players_loop', $cnt, 
					'ip', $eachclient->ipport());
				$request->addResultLoop('players_loop', $cnt, 
					'name', $eachclient->name());
				$request->addResultLoop('players_loop', $cnt, 
					'model', $eachclient->model());
				$request->addResultLoop('players_loop', $cnt, 
					'power', $eachclient->power());
				$request->addResultLoop('players_loop', $cnt, 
					'displaytype', $eachclient->vfdmodel())
					unless ($eachclient->model() eq 'http');
				$request->addResultLoop('players_loop', $cnt, 
					'connected', ($eachclient->connected() || 0));
				$request->addResultLoop('players_loop', $cnt, 
					'player_needs_upgrade', "1")
					if ($eachclient->needsUpgrade());

				for my $pref (@{$savePrefs{'player'}}) {
					if (defined(my $value = $prefs->client($eachclient)->get($pref))) {
						$request->addResultLoop('players_loop', $cnt, 
							$pref, $value);
					}
				}
					
				$cnt++;
			}	
		}
	}
	
	# manage the subscription
	if (defined(my $timeout = $request->getParam('subscribe'))) {
	
		# store the prefs array as private data so our filter above can find it back
		$request->privateData(\%savePrefs);
		
		# register ourselves to be automatically re-executed on timeout or filter
		$request->registerAutoExecute($timeout, \&serverstatusQuery_filter);
	}
	
	$request->setStatusDone();
}


sub signalstrengthQuery {
	my $request = shift;
	
	$log->debug("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['signalstrength']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	# get the parameters
	my $client = $request->client();

	$request->addResult('_signalstrength', $client->signalStrength() || 0);
	
	$request->setStatusDone();
}


sub sleepQuery {
	my $request = shift;
	
	$log->debug("Begin Function");

	# check this is the correct query
	if ($request->isNotQuery([['sleep']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	# get the parameters
	my $client = $request->client();

	my $isValue = $client->sleepTime() - Time::HiRes::time();
	if ($isValue < 0) {
		$isValue = 0;
	}
	
	$request->addResult('_sleep', $isValue);
	
	$request->setStatusDone();
}


# the filter function decides, based on a notified request, if the status
# query must be re-executed.
sub statusQuery_filter {
	my $self = shift;
	my $request = shift;
	
	# retrieve the clientid, abort if not about us
	my $clientid = $request->clientid();
	return 0 if !defined $clientid;
	return 0 if $clientid ne $self->clientid();
	
	# commands we ignore
	return 0 if $request->isCommand([['ir', 'button', 'debug', 'pref', 'display', 'prefset', 'playerpref']]);
	return 0 if $request->isCommand([['playlist'], ['open', 'jump']]);

	# special case: the client is gone!
	if ($request->isCommand([['client'], ['forget']])) {
		
		# pretend we do not need a client, otherwise execute() fails
		# and validate() deletes the client info!
		$self->needClient(0);
		
		# we'll unsubscribe above if there is no client
		return 1;
	}

	# don't delay for newsong
	if ($request->isCommand([['playlist'], ['newsong']])) {

		return 1;
	}

	# suppress frequent updates during volume changes
	if ($request->isCommand([['mixer'], ['volume']])) {

		return 3;
	}

	# send everyother notif with a small delay to accomodate
	# bursts of commands
	return 1.3;
}


sub statusQuery {
	my $request = shift;
	
	$log->debug("statusQuery()");

	# check this is the correct query
	if ($request->isNotQuery([['status']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	# get the initial parameters
	my $client = $request->client();
	my $menu = $request->getParam('menu');
	
	# menu/jive mgmt
	my $menuMode = defined $menu;

	# accomodate the fact we can be called automatically when the client is gone
	if (!defined($client)) {
		$request->addResult('error', "invalid player");
		$request->registerAutoExecute('-');
		$request->setStatusDone();
		return;
	}
		
	my $SP3  = ($client->model() eq 'slimp3');
	my $SQ   = ($client->model() eq 'softsqueeze');
	my $SB   = ($client->model() eq 'squeezebox');
	my $SB2  = ($client->model() eq 'squeezebox2');
	my $TS   = ($client->model() eq 'transporter');
	my $RSC  = ($client->model() eq 'http');
	
	my $connected = $client->connected() || 0;
	my $power     = $client->power();
	my $repeat    = Slim::Player::Playlist::repeat($client);
	my $shuffle   = Slim::Player::Playlist::shuffle($client);
	my $songCount = Slim::Player::Playlist::count($client);
	my $idx = 0;


	# now add the data...

	if (Slim::Music::Import->stillScanning()) {
		$request->addResult('rescan', "1");
	}

	if ($client->needsUpgrade()) {
		$request->addResult('player_needs_upgrade', "1");
	}
	
	# add player info...
	$request->addResult("player_name", $client->name());
	$request->addResult("player_connected", $connected);
	
	if (!$RSC) {
		$power += 0;
		$request->addResult("power", $power);
	}
	
	if ($SB || $SB2 || $TS) {
		$request->addResult("signalstrength", ($client->signalStrength() || 0));
	}
	
	my $playlist_cur_index;
	# this will be true for http class players
	if ($power) {
	
		$request->addResult('mode', Slim::Player::Source::playmode($client));

		if (my $song = Slim::Player::Playlist::url($client)) {

			if (Slim::Music::Info::isRemoteURL($song)) {
				$request->addResult('remote', 1);
				$request->addResult('current_title', 
					Slim::Music::Info::getCurrentTitle($client, $song));
			}
			
			$request->addResult('time', 
				Slim::Player::Source::songTime($client));
			$request->addResult('rate', 
				Slim::Player::Source::rate($client));
			
			my $track = Slim::Schema->rs('Track')->objectForUrl($song);

			if (blessed($track) && $track->can('secs')) {

				my $dur = $track->secs;

				if ($dur) {
					$dur += 0;
					$request->addResult('duration', $dur);
				}
			}

		}
		
		if ($client->currentSleepTime()) {

			my $sleep = $client->sleepTime() - Time::HiRes::time();
			$request->addResult('sleep', $client->currentSleepTime() * 60);
			$request->addResult('will_sleep_in', ($sleep < 0 ? 0 : $sleep));
		}
		
		if (Slim::Player::Sync::isSynced($client)) {

			my $master = Slim::Player::Sync::masterOrSelf($client);

			$request->addResult('sync_master', $master->id());

			my @slaves = Slim::Player::Sync::slaves($master);
			my @sync_slaves = map { $_->id } @slaves;

			$request->addResult('sync_slaves', join(",", @sync_slaves));
		}
	
		if (!$RSC) {
			# undefined for remote streams
			my $vol = $prefs->client($client)->get('volume');
			$vol += 0;
			$request->addResult("mixer volume", $vol);
		}
		
		if ($SB || $SP3) {
			$request->addResult("mixer treble", $client->treble());
			$request->addResult("mixer bass", $client->bass());
		}

		if ($SB) {
			$request->addResult("mixer pitch", $client->pitch());
		}

		$repeat += 0;
		$request->addResult("playlist repeat", $repeat);
		$shuffle += 0;
		$request->addResult("playlist shuffle", $shuffle); 
	
		if (defined (my $playlistObj = $client->currentPlaylist())) {
			$request->addResult("playlist_id", $playlistObj->id());
			$request->addResult("playlist_name", $playlistObj->title());
			$request->addResult("playlist_modified", $client->currentPlaylistModified());
		}

		if ($songCount > 0) {
			$playlist_cur_index = Slim::Player::Source::playingSongIndex($client);
			$request->addResult(
				"playlist_cur_index", 
				$playlist_cur_index
			);
			$request->addResult("playlist_timestamp", $client->currentPlaylistUpdateTime())
		}

		$request->addResult("playlist_tracks", $songCount);
	}
	
	# give a count in menu mode no matter what
	if ($menuMode) {
		$songCount += 0;
		$request->addResult("count", $power?$songCount:0);
		
		my $base = {
			'actions' => {
				'go' => {
					'cmd' => ['songinfo'],
					'params' => {
						#'menu' => 'nowplaying', # first enter the nowplaying window
						'menu' => 'nowhere', # leave this as nowhere until things work
					},
					'itemsParams' => 'params',
				},
			},
			'window' => {
				#'menuStyle'  => 'nowplaying', # this is only for use if nowplaying style menu is used in params above
				'titleStyle' => 'album',
			}
		};
		$request->addResult('base', $base);
	}
	
	if ($songCount > 0 && $power) {
	
		# get the other parameters
		my $tags     = $request->getParam('tags');
		my $index    = $request->getParam('_index');
		my $quantity = $request->getParam('_quantity');
	
		$tags = 'gald' if !defined $tags;
		my $loop = $menuMode ? 'item_loop' : 'playlist_loop';

		# we can return playlist data.
		# which mode are we in?
		my $modecurrent = 0;

		if (defined($index) && ($index eq "-")) {
			$modecurrent = 1;
		}
		
		# if repeat is 1 (song) and modecurrent, then show the current song
		if ($modecurrent && ($repeat == 1) && $quantity) {

			$request->addResult('offset', $playlist_cur_index) if $menuMode;
			my $track = Slim::Player::Playlist::song($client, $playlist_cur_index);

			if ($menuMode) {
				_addJiveSong($request, $loop, 0, 1, $track);
			}
			else {
				_addSong($request, $loop, 0, 
					$track, $tags,
					'playlist index', $playlist_cur_index
				);
			}
			
		} else {

			my ($valid, $start, $end);
			
			if ($modecurrent) {
				($valid, $start, $end) = $request->normalize($playlist_cur_index, scalar($quantity), $songCount);
			} else {
				($valid, $start, $end) = $request->normalize(scalar($index), scalar($quantity), $songCount);
			}

			if ($valid) {
				my $count = 0;
				$start += 0;
				$request->addResult('offset', $start) if $menuMode;
				
				for ($idx = $start; $idx <= $end; $idx++) {
					
					my $track = Slim::Player::Playlist::song($client, $idx);
					my $current = ($idx == $playlist_cur_index);

					if ($menuMode) {
						_addJiveSong($request, $loop, $count, $current, $track);
					}
					else {
						_addSong(	$request, $loop, $count, 
									$track, $tags,
									'playlist index', $idx
								);
					}

					$count++;
					
					# give peace a chance...
					if ($count % 5) {
						::idleStreams();
					}
				}
				
				#we don't do that in menu mode!
				if (!$menuMode) {
				
					my $repShuffle = $prefs->get('reshuffleOnRepeat');
					my $canPredictFuture = ($repeat == 2)  			# we're repeating all
											&& 						# and
											(	($shuffle == 0)		# either we're not shuffling
												||					# or
												(!$repShuffle));	# we don't reshuffle
				
					if ($modecurrent && $canPredictFuture && ($count < scalar($quantity))) {

						# wrap around the playlist...
						($valid, $start, $end) = $request->normalize(0, (scalar($quantity) - $count), $songCount);		

						if ($valid) {

							for ($idx = $start; $idx <= $end; $idx++){

								_addSong($request, $loop, $count, 
									Slim::Player::Playlist::song($client, $idx), $tags,
									'playlist index', $idx
								);

								$count++;
								::idleStreams() ;
							}
						}
					}

				}
			}
		}
	}


	# manage the subscription
	if (defined(my $timeout = $request->getParam('subscribe'))) {
	
		# register ourselves to be automatically re-executed on timeout or filter
		$request->registerAutoExecute($timeout, \&statusQuery_filter);
	}
	
	$request->setStatusDone();
}

sub songinfoQuery {
	my $request = shift;

	$log->debug("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['songinfo']])) {
		$request->setStatusBadDispatch();
		return;
	}

	my $tags  = 'abcdefghijJklmnopqrstvwxyzBCDEFHIJKLMNOQRTUVWXYZ'; # all letter EXCEPT u, A & S, G & P
	my $track;

	# get our parameters
	my $index    = $request->getParam('_index');
	my $quantity = $request->getParam('_quantity');
	my $url	     = $request->getParam('url');
	my $trackID  = $request->getParam('track_id');
	my $tagsprm  = $request->getParam('tags');
	
	my $menu     = $request->getParam('menu');
	my $insert   = $request->getParam('menu_play');

	# menu/jive mgmt
	my $menuMode = defined $menu;
	my $insertPlay = $menuMode && defined $insert;

	if (!defined $trackID && !defined $url) {
		$request->setStatusBadParams();
		return;
	}

	# did we have override on the defaults?
	$tags = $tagsprm if defined $tagsprm;

	# find the track
	if (defined $trackID){

		$track = Slim::Schema->find('Track', $trackID);

	} else {

		if (defined $url && Slim::Music::Info::isSong($url)){

			$track = Slim::Schema->rs('Track')->objectForUrl($url)
		}
	}
	
	# now build the result
	
	if (Slim::Music::Import->stillScanning()) {
		$request->addResult("rescan", 1);
	}

	if (blessed($track) && $track->can('id')) {

		my $trackId = $track->id();
		$trackId += 0;

		if ($menuMode) {

			# decide what is the next step down
			# generally, we go nowhere after songingo, so we get menu:nowhere...

			# build the base element
			my $go_action;
			if ($menu eq 'nowplaying') {
				$go_action = 
					{ 
						cmd  => ['songinfo'],
						params => {
							menu => 'nowhere',
							itemsParams => 'params', 
							cmd => 'load',
							track_id => $trackId,
					},
				};
			} 
			my $base = {
				actions => {

					# no go, we ain't going anywhere!

					# we play/add the current track id
					play => {
						player => 0,
						cmd => ['playlistcontrol'],
						params => {
							cmd => 'load',
							track_id => $trackId,
						},
					},
					add => {
						player => 0,
						cmd => ['playlistcontrol'],
						params => {
							cmd => 'add',
							track_id => $trackId,
						},
					},
				},
				window => {
				},
			};
			if ($menu eq 'nowplaying') {
				# this will get album and artist. may need more tags here
				$tags = 'Al'; 
				# actions for next step--drilling down to songinfo
				$base->{'actions'}{'go'} = $go_action;
				$base->{'window'}{'titleStyle'} = 'album';
				$base->{'window'}{'icon-id'} = $trackId;
				$log->error($base->{'actions'}{'go'});
			} else {
				$tags = 'AlGitCodYXyRkwfrTImvun';
			}
			$request->addResult('base', $base);
		}

		my $hashRef = _songData($request, $track, $tags, $menuMode);
		my $count = scalar (keys %{$hashRef});

		# correct count if we insert "Play all songs"
		$count++ if $insertPlay;

		$count += 0;

		my ($valid, $start, $end) = $request->normalize(scalar($index), scalar($quantity), $count);

		if ($valid) {

		# this is where we construct the nowplaying menu
		if ($menu eq 'nowplaying' && $menuMode) {
			$request->addResult("count", 1);
			$request->addResult('offset', $start) if $menuMode;
			my $cnt = 0;
			my @vals;
			my $loopname = 'item_loop';
			while (my ($key, $val) = each %{$hashRef}) {
				# catch multi-genres or artists
				if ($key =~ /(\w+)::(\d+)/) {
					$key = $1;
					my $id = $val->[0] + 0;
					$val = $val->[1];
				}
				push @vals, $val;
			}
			my $string = join ("\n", @vals);
			$request->addResultLoop($loopname, $cnt, 'text', $string);
			$request->addResultLoop($loopname, $cnt, 'icon-id', $trackId);
			#$cnt++;
		} else {
			
			$request->addResult("count", $count);

			my $idx = 0;
			my $cnt = 0;
			my $loopname = $menuMode?'item_loop':'songinfo_loop';
			$request->addResult('offset', $start) if $menuMode;

			# first PLAY item
			if ($insertPlay) {
			
				# insert first item if needed
				if ($start == 0) {
					$request->addResultLoop($loopname, $cnt, 'text', Slim::Utils::Strings::string('JIVE_PLAY_THIS_SONGS'));

					# override the actions, babe!
					my $actions = {
						'do' => {
							'player' => 0,
							'cmd' => ['playlistcontrol'],
							'params' => {
								'cmd' => 'load',
								'track_id' => $trackId,
							},
						},
						# play/add taken care of in base
					};
					$request->addResultLoop($loopname, $cnt, 'actions', $actions);
					$cnt++;
				}

				# correct db slice!
				else {
					# we are not adding our item but it is counted in $start
					# (a query for tracks 1 10 needs to start at db 0! -- and go to db 9 (instead of 10))
					# (a query for tracks 0 10 ALSO needs to start at db 0! -- and go to db 8 (instead of 9))
					$start--;
				}
				# always fix $end 
				$end--;
			}

			while (my ($key, $val) = each %{$hashRef}) {

				if ($idx >= $start && $idx <= $end) {
					
					if ($menuMode) {
						
						# catch multi-genres or artists
						if ($key =~ /(\w+)::(\d+)/) {
						
							$key = $1;
							my $id = $val->[0] + 0;
							$val = $val->[1];
							my $actions;
							
							# genre
							if ($key eq 'GENRE') {
								$actions = {
									'go' => {
										'cmd' => ['artists'],
										'params' => {
											'menu' => 'album',
											'genre_id' => $id,
										},
									},
									'play' => {
										'player' => 0,
										'cmd' => ['playlistcontrol'],
										'params' => {
											'cmd' => 'load',
											'genre_id' => $id,
										},
									},
									'add' => {
										'player' => 0,
										'cmd' => ['playlistcontrol'],
										'params' => {
											'cmd' => 'add',
											'genre_id' => $id,
										},
									},
								};
							}
							
							# album -- not multi, but _songData simulates it in menuMode so we can add our action here
							elsif ($key eq 'ALBUM') {
								$actions = {
									'go' => {
										'cmd' => ['tracks'],
										'params' => {
											'menu' => 'songinfo',
											'album_id' => $id,
											'sort' => 'tracknum',
										},
									},
									'play' => {
										'player' => 0,
										'cmd' => ['playlistcontrol'],
										'params' => {
											'cmd' => 'load',
											'album_id' => $id,
										},
									},
									'add' => {
										'player' => 0,
										'cmd' => ['playlistcontrol'],
										'params' => {
											'cmd' => 'add',
											'album_id' => $id,
										},
									},
								};
								# style correctly the title that opens for the action element
								$request->addResultLoop($loopname, $cnt, 'window', { 'titleStyle' => 'album', 'icon-id' => $trackId } );
							}
							
							#or one of the artist role -- we don't test explicitely !!!
							else {
								
								$actions = {
									'go' => {
										'cmd' => ['albums'],
										'params' => {
											'menu' => 'track',
											'artist_id' => $id,
										},
									},
									'play' => {
										'player' => 0,
										'cmd' => ['playlistcontrol'],
										'params' => {
											'cmd' => 'load',
											'artist_id' => $id,
										},
									},
									'add' => {
										'player' => 0,
										'cmd' => ['playlistcontrol'],
										'params' => {
											'cmd' => 'add',
											'artist_id' => $id,
										},
									},
								};
								
								# style correctly the window that opens for the action element
								$request->addResultLoop($loopname, $cnt, 'window', { 'menuStyle' => 'album' } );
							}
							
							$request->addResultLoop($loopname, $cnt, 'actions', $actions);
						}
						else {
							# pretty print some of the stuff...
							# it's done all over the place for the web interface:
							## some of it in the template!
							## some of it in Pages::addSongInfo
							## the rest is using pretty printing methods of track
						
							if ($key eq 'COMPILATION') {
								$val = Slim::Utils::Strings::string('YES');
							}
							elsif ($key eq 'TYPE') {
								$val = Slim::Utils::Strings::string($val);
							}
							elsif ($key eq 'LENGTH') {
								$val = $track->duration();
							}
							elsif ($key eq 'ALBUMREPLAYGAIN' || $key eq 'REPLAYGAIN') {
								$val = sprintf("%2.2f", $val) . " dB";
							}
							elsif ($key eq 'RATING') {
								$val = $val / 100;
							}
							elsif ($key eq 'FILELENGTH') {
								$val = Slim::Utils::Misc::delimitThousands($val) . " " . Slim::Utils::Strings::string('BYTES');
							}
							elsif ($key eq 'SAMPLERATE') {
								$val = $track->prettySampleRate();
							}
							elsif ($key eq 'SAMPLESIZE') {
								$val = $val . " " . Slim::Utils::Strings::string('BITS');
							}
							elsif ($key eq 'LOCATION') {
								$val = $track->path();
							}
							elsif ( $key eq 'YEAR' && $val == 0 ||
								$key eq 'COMMENT' && $val == 0) {
								$val = Slim::Utils::Strings::string('NONE');
							}
							
							my $style   ='itemNoAction';
							$request->addResultLoop($loopname, $cnt, 'style', $style);
						}
						$request->addResultLoop($loopname, $cnt, 'text', Slim::Utils::Strings::string($key) . ": " . $val);
					}
					else {
						$request->addResultLoop($loopname, $cnt, $key, $val);
					}
					$cnt++;
				}
				$idx++;
 			}
		}
		}
	}

	$request->setStatusDone();
}


sub syncQuery {
	my $request = shift;
	
	$log->debug("Begin Function");

	# check this is the correct query
	if ($request->isNotQuery([['sync']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	# get the parameters
	my $client = $request->client();

	if (Slim::Player::Sync::isSynced($client)) {
	
		my @buddies = Slim::Player::Sync::syncedWith($client);
		my @sync_buddies = map { $_->id() } @buddies;

		$request->addResult('_sync', join(",", @sync_buddies));
	} else {
	
		$request->addResult('_sync', '-');
	}
	
	$request->setStatusDone();
}


sub timeQuery {
	my $request = shift;
	
	$log->debug("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['time', 'gototime']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	# get the parameters
	my $client = $request->client();

	$request->addResult('_time', Slim::Player::Source::songTime($client));
	
	$request->setStatusDone();
}

sub titlesQuery {
	my $request = shift;

	$log->debug("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['titles', 'tracks', 'songs']])) {
		$request->setStatusBadDispatch();
		return;
	}

	my $where  = {};
	my $attr   = {};

	my $tags   = 'gald';

	# get our parameters
	my $index         = $request->getParam('_index');
	my $quantity      = $request->getParam('_quantity');
	my $tagsprm       = $request->getParam('tags');
	my $sort          = $request->getParam('sort');
	my $search        = $request->getParam('search');
	my $genreID       = $request->getParam('genre_id');
	my $contributorID = $request->getParam('artist_id');
	my $albumID       = $request->getParam('album_id');
	my $year          = $request->getParam('year');
	
	my $menu          = $request->getParam('menu');
	my $insert        = $request->getParam('menu_all');
	
	# menu/jive mgmt
	my $menuMode = defined $menu;
	my $insertAll = $menuMode && defined $insert;

	if ($request->paramNotOneOfIfDefined($sort, ['title', 'tracknum'])) {
		$request->setStatusBadParams();
		return;
	}

	# did we have override on the defaults?
	# note that this is not equivalent to 
	# $val = $param || $default;
	# since when $default eq '' -> $val eq $param
	$tags = $tagsprm if defined $tagsprm;

	# Normalize any search parameters
	if (specified($search)) {
		$where->{'me.titlesearch'} = {'like' => Slim::Utils::Text::searchStringSplit($search)};
	}

	if (defined $albumID){
		$where->{'me.album'} = $albumID;
	}

	if (defined $year) {
		$where->{'me.year'} = $year;
	}

	# we don't want client playlists (Now playing), transporter sources,
	# directories, or playlists.
	$where->{'me.content_type'} = [ -and => {'!=', 'cpl'},  {'!=', 'src'},  {'!=', 'ssp'}, {'!=', 'dir'} ];

	# Manage joins
	if (defined $genreID) {

		$where->{'genreTracks.genre'} = $genreID;

		push @{$attr->{'join'}}, 'genreTracks';
#		$attr->{'distinct'} = 1;
	}

	if (defined $contributorID) {
	
		# handle the case where we're asked for the VA id => return compilations
		if ($contributorID == Slim::Schema->variousArtistsObject->id) {
			$where->{'album.compilation'} = 1;
			push @{$attr->{'join'}}, 'album';
		}
		else {	
			$where->{'contributorTracks.contributor'} = $contributorID;
			push @{$attr->{'join'}}, 'contributorTracks';
		}
	}

	if ($sort && $sort eq "tracknum") {

		if (!($tags =~ /t/)) {
			$tags = $tags . "t";
		}

		$attr->{'order_by'} =  "me.disc, me.tracknum, concat('0', me.titlesort)";
	}
	else {
		$attr->{'order_by'} =  "me.titlesort";
	}

	my $rs = Slim::Schema->rs('Track')->search($where, $attr)->distinct;

	my $count = $rs->count;

	# now build the result
	
	if ($menuMode) {

		# decide what is the next step down
		# generally, we go to songinfo after albums, so we get menu:track
		# from songinfo we go nowhere...
		my $actioncmd = 'songinfo';
		my $nextMenu = 'nowhere';
		
		# build the base element
		my $base = {
			'actions' => {
				'go' => {
					'cmd' => [$actioncmd],
					'params' => {
						'menu' => $nextMenu,
#						'menu_play' => '1',
					},
					'itemsParams' => 'params',
				},
				'play' => {
					'player' => 0,
					'cmd' => ['playlistcontrol'],
					'params' => {
						'cmd' => 'load',
					},
					'itemsParams' => 'params',
				},
				'add' => {
					'player' => 0,
					'cmd' => ['playlistcontrol'],
					'params' => {
						'cmd' => 'add',
					},
					'itemsParams' => 'params',
				},
			},
			'window' => {
				'titleStyle' => 'album',
			}
		};
		$request->addResult('base', $base);
		
		# correct count if we insert "Play all"
		$count++ if $insertAll;
	}

	if (Slim::Music::Import->stillScanning) {
		$request->addResult("rescan", 1);
	}

	$count += 0;
	$request->addResult("count", $count);

	my ($valid, $start, $end) = $request->normalize(scalar($index), scalar($quantity), $count);

	if ($valid) {
		
		my $format = $prefs->get('titleFormat')->[ $prefs->get('titleFormatWeb') ];
		my $loopname = $menuMode?'item_loop':'titles_loop';
		my $cnt = 0;
		$request->addResult('offset', $start) if $menuMode;

		# first PLAY ALL item
		if ($insertAll) {
			($start, $end, $cnt) = _playAll($start, $end, $cnt, $request, $loopname);
		}


		for my $item ($rs->slice($start, $end)) {
			
			# jive formatting
			if ($menuMode) {
				
				my $text = Slim::Music::TitleFormatter::infoFormat($item, $format, 'TITLE');
				$request->addResultLoop($loopname, $cnt, 'text', $text);
				my $id = $item->id();
				$id += 0;
				my $params = {
					'track_id' =>  $id, 
				};
				$request->addResultLoop($loopname, $cnt, 'params', $params);
			
			
				# open a window with icon etc...
			
				my $text2 = $item->title;
				my $album;
				my $albumObj = $item->album();
				my $iconId;
				if(defined($albumObj)) {
					$album = $albumObj->title();
					$iconId = $albumObj->artwork();
				}
				$text2 = $text2 . "\n" . (defined($album)?$album:"");
			
				my $artist;
				if(defined(my $artistObj = $item->artist())) {
					$artist = $artistObj->name();
				}
				$text2 = $text2 . "\n" . (defined($artist)?$artist:"");
			
				my $window = {
					'text' => $text2,
				};
			
				if (defined($iconId)) {
					$iconId += 0;
					$window->{'icon-id'} = $iconId;
				}

				$request->addResultLoop($loopname, $cnt, 'window', $window);
			}
			
			# regular formatting
			else {
				_addSong($request, $loopname, $cnt, $item, $tags);
			}
			
			$cnt++;
			
			# give peace a chance...
			if ($cnt % 5) {
				::idleStreams();
			}
		}
	}

	$request->setStatusDone();
}


sub versionQuery {
	my $request = shift;
	
	$log->debug("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['version']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# no params for the version query

	$request->addResult('_version', $::VERSION);
	
	$request->setStatusDone();
}


sub yearsQuery {
	my $request = shift;

	$log->debug("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['years']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get our parameters
	my $index         = $request->getParam('_index');
	my $quantity      = $request->getParam('_quantity');	
	my $menu          = $request->getParam('menu');
	my $insert        = $request->getParam('menu_all');
	
	# menu/jive mgmt
	my $menuMode  = defined $menu;
	my $insertAll = $menuMode && defined $insert;
	
	# get them all by default
	my $where = {};
	
	# sort them
	my $attr = {
		'distinct' => 'me.id'
	};

	my $rs = Slim::Schema->resultset('Year')->browse->search($where, $attr);

	my $count = $rs->count;

	# now build the result
	
	if ($menuMode) {

		# decide what is the next step down
		# generally, we go to albums after years, so we get menu:album
		# from the albums we'll go to tracks
		my $actioncmd = $menu . 's';
		my $nextMenu = 'track';
		
		# build the base element
		my $base = {
			'actions' => {
				'go' => {
					'cmd' => [$actioncmd],
					'params' => {
						menu     => $nextMenu,
						menu_all => '1',
					},
					'itemsParams' => 'params',
				},
				'play' => {
					'player' => 0,
					'cmd' => ['playlistcontrol'],
					'params' => {
						'cmd' => 'load',
					},
					'itemsParams' => 'params',
				},
				'add' => {
					'player' => 0,
					'cmd' => ['playlistcontrol'],
					'params' => {
						'cmd' => 'add',
					},
					'itemsParams' => 'params',
				},
			},
			'window' => {
				menuStyle   => 'album',
				titleStyle  => 'mymusic',
			}
		};
		$request->addResult('base', $base);
		$count++ if $insertAll;
	}

	if (Slim::Music::Import->stillScanning()) {
		$request->addResult('rescan', 1);
	}

	$count += 0;
	$request->addResult('count', $count);

	my ($valid, $start, $end) = $request->normalize(scalar($index), scalar($quantity), $count);

	if ($valid) {

		my $loopname = $menuMode?'item_loop':'years_loop';
		my $cnt = 0;
		$request->addResult('offset', $start) if $menuMode;

		if ($insertAll) {
			($start, $end, $cnt) = _playAll($start, $end, $cnt, $request, $loopname);
		}
		for my $eachitem ($rs->slice($start, $end)) {

			my $id = $eachitem->id();
			$id += 0;

			if ($menuMode) {
				$request->addResultLoop($loopname, $cnt, 'text', $eachitem->name);
				my $params = {
					'year' =>  $id, 
				};
				$request->addResultLoop($loopname, $cnt, 'params', $params);
			}
			else {
				$request->addResultLoop($loopname, $cnt, 'year', $id);
			}
			$cnt++;
		}
	}

	$request->setStatusDone();
}

################################################################################
# Special queries
################################################################################

=head2 dynamicAutoQuery( $request, $query, $funcptr, $data )

 This function is a helper function for any query that needs to poll enabled
 plugins. In particular, this is used to implement the CLI radios query,
 that returns all enabled radios plugins. This function is best understood
 by looking as well in the code used in the plugins.
 
 Each plugins does in initPlugin (edited for clarity):
 
    $funcptr = addDispatch(['radios'], [0, 1, 1, \&cli_radiosQuery]);
 
 For the first plugin, $funcptr will be undef. For all the subsequent ones
 $funcptr will point to the preceding plugin cli_radiosQuery() function.
 
 The cli_radiosQuery function looks like:
 
    sub cli_radiosQuery {
      my $request = shift;
      
      my $data = {
         #...
      };
 
      dynamicAutoQuery($request, 'radios', $funcptr, $data);
    }
 
 The plugin only defines a hash with its own data and calls dynamicAutoQuery.
 
 dynamicAutoQuery will call each plugin function recursively and add the
 data to the request results. It checks $funcptr for undefined to know if
 more plugins are to be called or not.
 
=cut

sub dynamicAutoQuery {
	my $request = shift;                       # the request we're handling
	my $query   = shift || return;             # query name
	my $funcptr = shift;                       # data returned by addDispatch
	my $data    = shift || return;             # data to add to results
	
	$log->debug("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([[$query]])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get our parameters
	my $index    = $request->getParam('_index');
	my $quantity = $request->getParam('_quantity') || 0;
	my $sort     = $request->getParam('sort');
	my $menu     = $request->getParam('menu');

	my $menuMode = defined $menu;

	# we have multiple times the same resultset, so we need a loop, named
	# after the query name (this is never printed, it's just used to distinguish
	# loops in the same request results.
	my $loop = $menuMode?'item_loop':$query . 's_loop';

	# if the caller asked for results in the query ("radios 0 0" returns 
	# immediately)
	if ($quantity) {

		# add the data to the results
		my $cnt = $request->getResultLoopCount($loop) || 0;
		$request->setResultLoopHash($loop, $cnt, $data);
		
		# more to jump to?
		# note we carefully check $funcptr is not a lemon
		if (defined $funcptr && ref($funcptr) eq 'CODE') {
			
			eval { &{$funcptr}($request) };
	
			# arrange for some useful logging if we fail
			if ($@) {

				logError("While trying to run function coderef: [$@]");
				$request->setStatusBadDispatch();
				$request->dump('Request');
			}
		}
		
		# $funcptr is undefined, we have everybody, now slice & count
		else {
			
			# sort if requested to do so
			if ($sort) {
				$request->sortResultLoop($loop, $sort);
			}
			
			# slice as needed
			my $count = $request->getResultLoopCount($loop);
			$request->sliceResultLoop($loop, $index, $quantity);
			$request->addResult('offset', $index) if $menuMode;
			$count += 0;
			$request->setResultFirst('count', $count);
			
			# don't forget to call that to trigger notifications, if any
			$request->setStatusDone();
		}
	}
	else {
		$request->setStatusDone();
	}
}

################################################################################
# Helper functions
################################################################################

sub _addSong {
	my $request   = shift; # request
	my $loop      = shift; # loop
	my $index     = shift; # loop index
	my $pathOrObj = shift; # song path or object
	my $tags      = shift; # tags to use
	my $prefixKey = shift; # prefix key, if any
	my $prefixVal = shift; # prefix value, if any   

	# get the hash with the data	
	my $hashRef = _songData($request, $pathOrObj, $tags);
	
	# add the prefix in the first position, use a fancy feature of
	# Tie::LLHash
	if (defined $prefixKey) {
		(tied %{$hashRef})->Unshift($prefixKey => $prefixVal);
	}
	
	# add it directly to the result loop
	$request->setResultLoopHash($loop, $index, $hashRef);
}


sub _addJiveSong {
	my $request   = shift; # request
	my $loop      = shift; # loop
	my $count     = shift; # loop index
	my $current   = shift;
	my $track     = shift;
	
	# If we have a remote track, check if a plugin can provide metadata
	my $remoteMeta = {};
	if ( $track->remote ) {
		my $url     = $track->url;
		my $handler = Slim::Player::ProtocolHandlers->handlerForURL($url);
		if ( $handler && $handler->can('getMetadataFor') ) {
			$remoteMeta = $handler->getMetadataFor( $request->client, $url );
			
			# if we have a plugin-defined title, remove the current_title value
			if ( $remoteMeta->{title} ) {
				$request->addResult( 'current_title' => undef );
			}
		}
	}
	
	my $text = $remoteMeta->{title} || $track->title;
	my $album;
	my $albumObj = $track->album();
	my $iconId;
	
	if ( defined $albumObj ) {
		$album = $albumObj->title();
		$iconId = $albumObj->artwork();
	}
	elsif ( $remoteMeta->{album} ) {
		$album = $remoteMeta->{album};
	}
	
	$text .= "\n" . ( defined $album ? $album : '' );
	
	my $artist;
	if ( defined( my $artistObj = $track->artist() ) ) {
		$artist = $artistObj->name();
	}
	elsif ( $remoteMeta->{artist} ) {
		$artist = $remoteMeta->{artist};
	}
	
	$text .= "\n" . ( defined $artist ? $artist : '' );
	
	if ( defined $iconId ) {
		$iconId += 0;
		$request->addResultLoop($loop, $count, 'icon-id', $iconId);
	}
	elsif ( $remoteMeta->{cover} ) {
		$request->addResultLoop( $loop, $count, 'icon', $remoteMeta->{cover} );
	}

	$request->addResultLoop($loop, $count, 'text', $text);

	# Add trackinfo menu action for remote URLs
	if ( $track->remote ) {
		my $actions = {
			go => {
				cmd    => [ 'trackinfo', 'items' ],
				params => {
					menu => 'menu',
					url  => $track->url,
				},
			},
		};
		
		$request->addResultLoop( $loop, $count, 'actions', $actions );
	}

	my $id = $track->id();
	$id += 0;
	my $params = {
		'track_id' => $id, 
	};
	$request->addResultLoop($loop, $count, 'params', $params);
}


sub _songData {
	my $request   = shift; # current request object
	my $pathOrObj = shift; # song path or object
	my $tags      = shift; # tags to use
	my $menuMode  = shift; # if true, we're in Menu mode


	# figure out the track object
	my $track     = Slim::Schema->rs('Track')->objectForUrl($pathOrObj);

	if (!blessed($track) || !$track->can('id')) {

		logError("Called with invalid object or path: $pathOrObj!");
		
		# For some reason, $pathOrObj may be an id... try that before giving up...
		if ($pathOrObj =~ /^\d+$/) {
			$track = Slim::Schema->find('Track', $pathOrObj);
		}

		if (!blessed($track) || !$track->can('id')) {

			logError("Can't make track from: $pathOrObj!");
			return;
		}
	}
	
	# If we have a remote track, check if a plugin can provide metadata
	my $remoteMeta = {};
	if ( $track->remote ) {
		my $url     = $track->url;
		my $handler = Slim::Player::ProtocolHandlers->handlerForURL($url);
		if ( $handler && $handler->can('getMetadataFor') ) {
			$remoteMeta = $handler->getMetadataFor( $request->client, $url );
			
			$remoteMeta->{a} = $remoteMeta->{artist};
			$remoteMeta->{A} = $remoteMeta->{artist};
			$remoteMeta->{l} = $remoteMeta->{album};
			$remoteMeta->{K} = $remoteMeta->{cover};
			$remoteMeta->{Y} = $remoteMeta->{replay_gain};
			$remoteMeta->{o} = $remoteMeta->{type};
			$remoteMeta->{r} = $remoteMeta->{bitrate};
			$remoteMeta->{B} = $remoteMeta->{buttons};
			$remoteMeta->{L} = $remoteMeta->{info_link};

			# if we have a plugin-defined title, remove the current_title value
			if ( $remoteMeta->{title} ) {
				$request->addResult( 'current_title' => undef );
			}
		}
	}
	
	# define an ordered hash for our results
	tie (my %returnHash, "Tie::IxHash");

	# in normal mode, we want to use a tag name as key
	# in menu mode, we want to use a string token we can i8n as key
	my $keyIndex = 0;

	# add fields present no matter $tags
	if ($menuMode) {
		$returnHash{'TITLE'} = $remoteMeta->{title} || $track->title;
		
		# use token as key in menuMode
		$keyIndex = 1;
	}
	else {
		$returnHash{'id'}    = $track->id;
		$returnHash{'title'} = $remoteMeta->{title} || $track->title;
	}

	my %tagMap = (
		# Tag    Tag name             Token            Track method         Track field
		#------------------------------------------------------------------------------
		# '.' => ['id',               '',              'id'],               #id
		  'u' => ['url',              'LOCATION',      'url'],              #url
		  'o' => ['type',             'TYPE',          'content_type'],     #content_type
		# '.' => ['title',            'TITLE',         'title'],            #title
		#                                                                   #titlesort 
		#                                                                   #titlesearch 
		  'e' => ['album_id',         '',              'albumid'],          #album 
		  't' => ['tracknum',         'TRACK',         'tracknum'],         #tracknum
		  'n' => ['modificationTime', 'MODTIME',       'modificationTime'], #timestamp
		  'f' => ['filesize',         'FILELENGTH',    'filesize'],         #filesize
		#                                                                   #tag 
		  'i' => ['disc',             'DISC',          'disc'],             #disc
		  'j' => ['coverart',         '',              'coverArtExists'],   #cover
		  'x' => ['remote',           '',              'remote'],           #remote 
		#                                                                   #audio 
		#                                                                   #audio_size 
		#                                                                   #audio_offset
		  'y' => ['year',             'YEAR',          'year'],             #year
		  'd' => ['duration',         'LENGTH',        'secs'],             #secs
		#                                                                   #vbr_scale 
		  'r' => ['bitrate',          'BITRATE',       'prettyBitRate'],    #bitrate
		  'T' => ['samplerate',       'SAMPLERATE',    'samplerate'],       #samplerate 
		  'I' => ['samplesize',       'SAMPLESIZE',    'samplesize'],       #samplesize 
		#                                                                   #channels 
		#                                                                   #block_alignment
		#                                                                   #endian 
		  'm' => ['bpm',              'BPM',           'bpm'],              #bpm
		  'v' => ['tagversion',       'TAGVERSION',    'tagversion'],       #tagversion
		# 'z' => ['drm',              '',              'drm'],              #drm
		#                                                                   #musicmagic_mixable
		#                                                                   #musicbrainz_id 
		#                                                                   #playcount 
		#                                                                   #lastplayed 
		#                                                                   #lossless 
		  'w' => ['lyrics',           'LYRICS',        'lyrics'],           #lyrics 
		  'R' => ['rating',           'RATING',        'rating'],           #rating 
		  'Y' => ['replay_gain',      'REPLAYGAIN',    'replay_gain'],      #replay_gain 
		#                                                                   #replay_peak


		# Tag    Tag name              Token              Relationship     Method          Track relationship
		#--------------------------------------------------------------------------------------------------
		  'a' => ['artist',            'ARTIST',          'artist',        'name'],         #->contributors
		  's' => ['artist_id',         '',                'artist',        'id'],           #->contributors
		  'A' => ['<role>',            '<ROLE>',          'contributors',  'name'],         #->contributors[role].name
		  'S' => ['<role>_ids',        '',                'contributors',  'id'],           #->contributors[role].id
#		  'b' => ['band',              'B',               'band'],                          #->contributors
#		  'c' => ['composer',          'C',               'composer'],                      #->contributors
#		  'h' => ['conductor',         'D',               'conductor'],                     #->contributors
                                                                            
		  'l' => ['album',             'ALBUM',           'album',         'title'],        #->album.title
		  'q' => ['disccount',         '',                'album',         'discc'],        #->album.discc
		  'J' => ["artwork_track_id",  '',                'album',         'artwork'],      #->album.artwork
		  'C' => ['compilation',       'COMPILATION',     'album',         'compilation'],  #->album.compilation
		  'X' => ['album_replay_gain', 'ALBUMREPLAYGAIN', 'album',         'replay_gain'],  #->album.replay_gain
                                                                            
		  'g' => ['genre',             'GENRE',           'genre',         'name'],         #->genre_track->genre.name
		  'p' => ['genre_id',          '',                'genre',         'id'],           #->genre_track->genre.id
		  'G' => ['genres',            'GENRE',           'genres',        'name'],         #->genre_track->genres.name
		  'P' => ['genre_ids',         '',                'genres',        'id'],           #->genre_track->genres.id
                                                                            
		  'k' => ['comment',           'COMMENT',         'comment'],                       #->comment_object
		  'K' => [''],                                                                      # artwork URL, not in db
		  'B' => [''],                                                                      # radio stream special buttons
		  'L' => [''],                                                                      # special trackinfo link for i.e. Pandora

	);
	
	# loop so that stuff is returned in the order given...
	for my $tag (split //, $tags) {
		
		# special case, artwork URL for remote tracks
		if ($tag eq 'K') {
			if ( my $meta = $remoteMeta->{$tag} ) {
				$returnHash{artwork_url} = $meta;
			}
		}

		# special case, button handling for remote tracks
		elsif ($tag eq 'B') {
			if ( my $meta = $remoteMeta->{$tag} ) {
				$returnHash{buttons} = $meta;
			}
		}
		
		# special case, info_link for remote tracks
		elsif ($tag eq 'L') {
			if ( my $meta = $remoteMeta->{$tag} ) {
				$returnHash{info_link} = $meta;
			}
		}

		# special case artists (tag A and S)
		elsif ($tag eq 'A' || $tag eq 'S') {
			if ( my $meta = $remoteMeta->{$tag} ) {
				$returnHash{artist} = $meta;
				next;
			}
			
			if (defined(my $submethod = $tagMap{$tag}->[3])) {
				
				my $postfix = ($tag eq 'S')?"_ids":"";
			
				foreach my $type (Slim::Schema::Contributor::contributorRoles()) {
				
					if ($menuMode) {
						my $key = uc($type);
						my $idx = 0;
						foreach my $contrib ($track->contributorsOfType($type)->all) {
							$returnHash{$key . "::" . $idx++} = [$contrib->id(), $contrib->name()];
						}
					}
					else {
						
						my $key = lc($type) . $postfix;
						my $value = join(', ', map { $_ = $_->$submethod() } $track->contributorsOfType($type)->all);
				
						if (defined $value && $value ne '') {

							# add the tag to the result
							$returnHash{$key} = $value;
						}
					}
				}
			}
		}

		# if we have a method/relationship for the tag
		elsif (defined(my $method = $tagMap{$tag}->[2])) {
			
			if ($method ne '') {

				my $value;
				my $key = $tagMap{$tag}->[$keyIndex];
				
				# Override with remote track metadata if available
				if ( defined $remoteMeta->{$tag} ) {
					$value = $remoteMeta->{$tag};
				}

				# tag with submethod
				elsif (defined(my $submethod = $tagMap{$tag}->[3])) {

					# call submethod
					if (defined(my $related = $track->$method)) {
						
						# array returned/genre
						if ( blessed($related) && $related->isa('Slim::Schema::ResultSet::Genre')) {
							
							if ($menuMode) {
								my $idx = 0;
								foreach my $genre ($related->all) {
									$returnHash{$key . "::" . $idx++} = [$genre->id(), $genre->name()];
								}
							} 
							else {
								$value = join(', ', map { $_ = $_->$submethod() } $related->all);
							}
						}
						# special case album in menuMode
						elsif ($menuMode && $key eq 'ALBUM') {
							# send a dummy key::0 to trigger adding action in songinfo
							# and return an [id, name] array
							$key = $key . "::0";
							$value = [ $track->albumid(), $related->$submethod() ];
						}
						else {
							$value = $related->$submethod();
						}
					}
				}
				
				# simple track method
				else {
					$value = $track->$method();
				}
				
				# correct values
				if (($tag eq 'R' || $tag eq 'x') && $value == 0) {
					$value = undef;
				}
				
				# if we have a value
				if (defined $value && $value ne '') {

					# add the tag to the result
					$returnHash{$key} = $value;
				}
			}
		}
	}

	return \%returnHash;
}

sub _playAll {
	my ($start, $end, $cnt, $request, $loopname) = @_;
	# insert first item if needed
	if ($start == 0) {
			$request->addResultLoop($loopname, $cnt, 'text', Slim::Utils::Strings::string('JIVE_PLAY_ALL'));

		# get all our params
		my $params = $request->getParamsCopy();
		my $paramsAdd = {};
		my $paramsGoPlay = {};

		my $searchType = $request->getParam('_searchType');
		$paramsAdd->{'cmd'} = 'add';
		$paramsGoPlay->{'cmd'} = 'load';
	
		my @playCmd = ('playlistcontrol');
		my @addCmd = ('playlistcontrol');

		# remove keys starting with _ (internal or positional) and make copies
		while (my ($key, $val) = each %{$params}) {
			if ($key =~ /^_/ || $key eq 'menu' || $key eq 'menu_all') {
				next;
			}
			# search is a special case of _playAll, which needs to fire off a different cli command
			if ($key eq 'search') {
				@playCmd = ('playlist', 'loadtracks');
				@addCmd  = ('playlist', 'addtracks');
				# we don't need a cmd: tagged param for these
				delete($paramsAdd->{'cmd'});
				delete($paramsGoPlay->{'cmd'});
				if ($searchType eq 'artists') {
					$paramsAdd->{'contributor.namesearch'}    = $val;
					$paramsGoPlay->{'contributor.namesearch'} = $val;
				} elsif ($searchType eq 'albums') {
					$paramsAdd->{'album.titlesearch'}    = $val;
					$paramsGoPlay->{'album.titlesearch'} = $val;
				} else {
					$paramsAdd->{'track.titlesearch'}    = $val;
					$paramsGoPlay->{'track.titlesearch'} = $val;
				}
			} else {
				$paramsAdd->{$key} = $val;
				$paramsGoPlay->{$key} = $val;
			}
		}
				
		# override the actions, babe!
		my $actions = {
			'do' => {
				'player' => 0,
				'cmd' => [ @playCmd ],
				'params' => $paramsGoPlay,
			},
			'play' => {
				'player' => 0,
				'cmd' => [ @playCmd ],
				'params' => $paramsGoPlay,
			},
			'add' => {
				'player' => 0,
				'cmd' => [ @addCmd ],
				'params' => $paramsAdd,
			},
		};
		$request->addResultLoop($loopname, $cnt, 'actions', $actions);
		$cnt++;

	# correct db slice!
	} else {
		# we are not adding our item but it is counted in $start
		# (a query for tracks 1 10 needs to start at db 0! -- and go to db 9 (instead of 10))
		# (a query for tracks 0 10 ALSO needs to start at db 0! -- and go to db 8 (instead of 9))
		$start--;
	}
	# always fix $end 
	$end--;
	return($start, $end, $cnt);
}
=head1 SEE ALSO

L<Slim::Control::Request.pm>

=cut

1;

__END__
