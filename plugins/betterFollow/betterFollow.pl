############################ 
# betterFollow plugin for OpenKore by MaterialBlade (2014) 
# Updated 2025 - Fixed for modern Perl/OpenKore compatibility
# 
# This software is open source, licensed under the GNU General Public License
# -------------------------------------------------- 
#
# If betterFollow_Target in config.txt is set, the bot will try to work around it
#	v0.1 - Base program
#	v0.2 - Added extra checks for available positions
#	v0.8 - 2025 update: Removed deprecated given/when syntax
#
############################ 

############################
# 
# 2025 edit
# if you want to search for all the config settings, search for "bf_"
# Config options available - add these to your config.txt:
#   bf_rangeSize - size of square to select offset from
#   bf_reaction - bot reaction speed timeout
#   bf_debug - enable debug messages
#   bf_healer - mark bot as healer type
#   bf_devotionSource - name of devotion source player
#   bf_devotionMinAggressives - min aggressives before seeking devotion (default: 3)
#   bf_devotionMinHP - min HP% before seeking devotion (default: 15)
#   bf_devotionChase - distance to maintain from devotion source (default: 5)
#   bf_Commanders - comma-separated list of players who can issue commands
#   bf_baseMap, bf_baseX, bf_baseY - saved base position
#
############################ 

package betterFollow;

use strict;
use warnings;
use Time::HiRes qw(time);
use Carp::Assert;
use IO::Socket;
use Text::ParseWords;
use utf8;

use Globals;
use Log qw(message warning error debug);
use Misc;
use Network::Send ();
use Settings;
use AI;
use AI::SlaveManager;

use Actor;
use Actor::You;
use Actor::Player;
use Actor::Monster;
use Actor::Party;
use Actor::NPC;
use Actor::Portal;
use Actor::Pet;
use Actor::Slave;
use Actor::Unknown;

use ChatQueue;
use Utils;
use Commands;
use Network;
use FileParsers;
use Translation;
use Field;
use Task::TalkNPC;
use Task::UseSkill;
use Task::ErrorReport;
use Utils::Exceptions;
use Data::Dumper;
use Math::Trig;

Plugins::register('betterFollow', 'more realistic follow options', \&onUnload); 
my $hooks = Plugins::addHooks(
	['ai_follow', \&mainProcess, undef], 
	["AI_pre", \&prelims, undef],
	['AI_post',       \&ai_post, undef],
	["packet_pre/party_chat", \&partyMsg, undef]
);

message "betterFollow v0.8 loaded successfully\n", "success";

# Check follow config on load
if (defined $config{'followDistanceMax'} && defined $config{'followDistanceMin'}) {
	message sprintf("betterFollow: Follow distances loaded - Min: %s, Max: %s\n", 
		$config{'followDistanceMin'}, $config{'followDistanceMax'}), "success";
} else {
	warning "betterFollow: Follow distances not found in config! Using defaults (3-6)\n";
	if (!defined $config{'followDistanceMax'}) {
		warning "  followDistanceMax is not set\n";
	}
	if (!defined $config{'followDistanceMin'}) {
		warning "  followDistanceMin is not set\n";
	}
}

my $better_move_timeout = time;
my $better_recalc_timeout = time;
my $better_routefix_timeout = time;
my $better_reaction_timeout = time;
my $better_loot_timeout = time;

my $mytimeout;
my $bf_args;
my %bf_hash;
my $break_multiplier = 0.75;

my $last_dir;
my $direction;

my $dir_check = 35;
my $max_break = 2+(rand 2);

$mytimeout->{'search_for_leader'} = $mytimeout->{'shuffle_move'} = $mytimeout->{'wander_move'} = time + 10;

my $boredom_dist = 0;

my %new_pos = ();
my %saved_offset = ();
my %offset = ();

my $setup = 0;

my $storedFollow;

my $last_debug_time = 0; # Throttle debug messages

# Store user's intended follow distances to prevent them being overwritten
my $user_followDistMax;
my $user_followDistMin;

sub saveFollowDistances {
	# Save the user's configured values
	if (defined $config{'followDistanceMax'} && $config{'followDistanceMax'} > 1) {
		$user_followDistMax = $config{'followDistanceMax'};
	}
	if (defined $config{'followDistanceMin'} && $config{'followDistanceMin'} > 0) {
		$user_followDistMin = $config{'followDistanceMin'};
	}
	
	if (defined $user_followDistMax || defined $user_followDistMin) {
		message sprintf("betterFollow: Saved user follow distances - Min: %s, Max: %s\n",
			$user_followDistMin || 'default', $user_followDistMax || 'default'), "success";
	}
}

sub restoreFollowDistances {
	my $restored = 0;
	
	# Check if values have been overwritten with defaults
	if (defined $user_followDistMax && (!defined $config{'followDistanceMax'} || $config{'followDistanceMax'} <= 1)) {
		configModify('followDistanceMax', $user_followDistMax);
		$restored = 1;
	}
	
	if (defined $user_followDistMin && (!defined $config{'followDistanceMin'} || $config{'followDistanceMin'} == 0)) {
		configModify('followDistanceMin', $user_followDistMin);
		$restored = 1;
	}
	
	if ($restored) {
		message "betterFollow: Restored follow distances from saved values\n", "success";
	}
}

# Helper function to clean config values (strips comments and whitespace)
sub cleanConfigValue {
	my ($value, $default, $type) = @_;
	return $default unless defined $value;
	
	$value =~ s/\s*#.*$//; # Remove comments
	$value =~ s/^\s+|\s+$//g; # Trim whitespace
	
	if ($type eq 'int') {
		return int($value) || $default;
	} elsif ($type eq 'float') {
		return ($value =~ /^[\d.]+$/) ? $value : $default;
	}
	
	return $value || $default;
}

sub onLoad {
	if($config{bf_baseX}){
		$bf_args->{'base'} = $config{bf_baseMap};
		$bf_hash{'base_pos'}{'x'} = $config{bf_baseX};
		$bf_hash{'base_pos'}{'y'} = $config{bf_baseY};
	}
	
	# Save the user's follow distances before anything can overwrite them
	saveFollowDistances();
}

onLoad();

sub onUnload {
    Plugins::delHooks($hooks);
}

sub onReload {
    &onUnload;
}

sub prelims {
	my (undef,$args) = @_;
	
	my $action = AI::action;
	
	if (defined $action && $action eq "attack") {
		$args->{move_timeout} = time+2;

		if(exists $new_pos{x}){
			my $garbage = calcPosition($char);
			$new_pos{'x'} = $garbage->{x};
			$new_pos{'y'} = $garbage->{y};
		}
		
		$break_multiplier = 0.75;
		$mytimeout->{'break_wait'} = time;
		$mytimeout->{'sit_wait'} = time;

	}

	my $devoMinAggressives = cleanConfigValue($config{bf_devotionMinAggressives}, 3, 'int');
	my $devoMinHP = cleanConfigValue($config{bf_devotionMinHP}, 15, 'int');
	
	my $selfAggressives = scalar(ai_getAggressives());
	my $partyAggressives = scalar(ai_getAggressives(1,1));

	if(defined $config{'bf_devotionSource'} and
	((percent_hp($char) <= $devoMinHP and $selfAggressives>0) || $partyAggressives>$devoMinAggressives)
	and timeOut($mytimeout->{'devotion_shuffle'},1.0))
	{
		$mytimeout->{'devotion_shuffle'} = time;

		foreach (@playersID) {
			next if (!$_);
			next unless ($char->{party} and $char->{party}{users}{$players{$_}{ID}});

			my $devoSource = $playersList->getByID($_);
			next unless defined $devoSource;
			next unless defined $devoSource->{name};

			next unless $devoSource->{name} eq $config{'bf_devotionSource'};

			my $devoMinDistance = cleanConfigValue($config{bf_devotionChase}, 5, 'int');

			my $devoPosition = calcPosition($devoSource);
			my $myPos = calcPosition($char);

			my $devoDist = distance($myPos, $devoPosition);

			if(!$devoSource->{dead} and $devoDist > $devoMinDistance)
			{
				message TF("Devo Check: Moving closer to devotion source.\n"), "teleport";
				
				my @array = calcRectArea2($devoPosition->{x}, $devoPosition->{y}, int($devoMinDistance/2), 1);
				my $randIndex = int(rand(@array));
				
				$new_pos{'x'} = $array[$randIndex]{x};
				$new_pos{'y'} = $array[$randIndex]{y};

				AI::dequeue if (defined AI::action && AI::action eq "move");
				
				main::ai_route($field->baseName, $new_pos{x}, $new_pos{y},
					distFromGoal => 0,
					attackOnRoute => 2,
					noSitAuto => 0,
					notifyUponArrival => 0);
			}
		}
	}
}

sub mainProcess {
	return if (!$net || $net->getState() != Network::IN_GAME);
	return if ($char->{sitting});
	
	my $args = AI::args;
	
	return unless ($config{'followTarget'});
	
	# Restore follow distances if they've been overwritten
	restoreFollowDistances();
	
	if($config{'followTarget'} eq "BASE"){
		if(!defined $bf_args->{'base'}){
			message TF("BASE following set but no base defined. Disabling follow.\n"), "follow";
			configModify("followTarget", "");
			return;
		}
		
		if($field->baseName ne $bf_args->{'base'}){
			message TF("Wrong map for BASE following. Current: %s, Base: %s\n", $field->baseName, $bf_args->{'base'}), "follow";
			return;
		}
		
		my $myPos = calcPosition($char);
		my $baseDist = distance($myPos, $bf_hash{'base_pos'});
		
		if($baseDist > 3){
			main::ai_route($field->baseName, $bf_hash{'base_pos'}{'x'}, $bf_hash{'base_pos'}{'y'},
				distFromGoal => 1,
				attackOnRoute => 2);
			return;
		}
		
		AI::dequeue if (defined AI::action && AI::action eq "follow");
		return;
	}
	
	my $followIndex;
	my $following;
	my $myPos = calcPosition($char); # Define early so it's available for party position checks
	
	# Throttle debug messages to once per second
	my $should_debug = $config{bf_debug} && (time - $last_debug_time > 1.0);
	if ($should_debug) {
		$last_debug_time = time;
	}
	
	if ($config{'followTarget'} eq $char->{name}) {
		error TF("You cannot follow yourself!\n"), "follow";
		configModify("followTarget", "");
		return;
	}

	foreach (@playersID) {
		next if (!$_);
		next unless defined $players{$_}{name};
		if ($players{$_}{name} eq $config{'followTarget'}) {
			$following = $players{$_};
			last;
		}
	}

	if (!defined $following) {
		# Leader not visible - check if they're in the party and on same map
		if ($char->{party}) {
			foreach my $ID (keys %{$char->{party}{users}}) {
				my $member = $char->{party}{users}{$ID};
				if ($member->{name} eq $config{'followTarget'}) {
					# Found in party, check if on same map
					if ($member->{map} eq $field->baseName && $member->{online}) {
						# Same map but not visible - try to move towards them
						if (defined $member->{pos}{x} && defined $member->{pos}{y}) {
							my $memberPos = {x => $member->{pos}{x}, y => $member->{pos}{y}};
							my $distToMember = distance($myPos, $memberPos);
							
							if ($should_debug) {
								message sprintf("DEBUG: Leader in party at (%d,%d), distance: %.1f\n", 
									$memberPos->{x}, $memberPos->{y}, $distToMember);
							}
							
							# Move towards party position if we're far
							if ($distToMember > 10 && timeOut($mytimeout->{'search_for_leader'}, 5)) {
								message "Leader not visible but in party, moving to their position\n", "follow";
								main::ai_route($field->baseName, $memberPos->{x}, $memberPos->{y},
									distFromGoal => 5,
									attackOnRoute => 2);
								$mytimeout->{'search_for_leader'} = time;
							}
							return;
						}
					} elsif ($member->{map} ne $field->baseName) {
						# Different map
						if (timeOut($mytimeout->{'search_for_leader'}, 30)) {
							message sprintf("Leader is on different map: %s (we're on %s)\n", 
								$member->{map}, $field->baseName), "follow";
							$mytimeout->{'search_for_leader'} = time;
						}
						return;
					}
				}
			}
		}
		
		# Fallback: ask in party chat
		if (timeOut($mytimeout->{'search_for_leader'}, 10) and $char->{party}) {
			sendMessage($messageSender, "p", "where is " . $config{'followTarget'} . "?");
			$mytimeout->{'search_for_leader'} = time;
			$bf_args->{'search_for_follow'} = 1;
		}
		return;
	}

	my $followPos = calcPosition($following);
	my $dist = distance($myPos, $followPos);
	
	if ($following->{dead}) {
		AI::dequeue if (defined AI::action && AI::action eq "follow");
		return;
	}

	my $followDistMax = cleanConfigValue($config{'bf_followDistanceMax'} || $config{'followDistanceMax'}, 6, 'int');
	my $followDistMin = cleanConfigValue($config{'bf_followDistanceMin'} || $config{'followDistanceMin'}, 3, 'int');
	
	if ($should_debug) {
		message "DEBUG: Raw config values:\n";
		message "  followDistanceMax = '" . (defined $config{'followDistanceMax'} ? $config{'followDistanceMax'} : 'undef') . "'\n";
		message "  followDistanceMin = '" . (defined $config{'followDistanceMin'} ? $config{'followDistanceMin'} : 'undef') . "'\n";
		message sprintf("DEBUG mainProcess: My pos (%d,%d), Leader pos (%d,%d), Distance: %.1f, Min: %d, Max: %d\n",
			$myPos->{x}, $myPos->{y}, $followPos->{x}, $followPos->{y}, $dist, $followDistMin, $followDistMax);
		message sprintf("DEBUG: Cleaned config - Min: %d, Max: %d\n", $followDistMin, $followDistMax);
	}

	# Check if we're already moving to a valid position
	if (exists $new_pos{x} && exists $new_pos{y}) {
		my $distToTarget = distance($myPos, \%new_pos);
		
		if ($should_debug) {
			message sprintf("DEBUG: Already have target (%d,%d), distance to target: %.1f\n", 
				$new_pos{x}, $new_pos{y}, $distToTarget);
		}
		
		# If we're close to our target position
		if ($distToTarget < 2) {
			# Check if we're in good range of the leader BEFORE clearing
			if ($dist >= $followDistMin && $dist <= $followDistMax) {
				# We're at our target AND in good range, clear and stay put
				delete $new_pos{x};
				delete $new_pos{y};
				if ($should_debug) {
					message "DEBUG: Reached target and in good range, clearing and staying\n";
				}
				return; # STAY HERE, don't recalculate
			} else {
				# We reached target but we're out of range (leader moved), clear and recalc
				delete $new_pos{x};
				delete $new_pos{y};
				if ($should_debug) {
					message "DEBUG: Reached target but out of range, clearing and will recalc\n";
				}
			}
		}
		# If we're still far from our target, don't recalculate yet
		elsif ($distToTarget > 2 && timeOut($better_recalc_timeout, 3)) {
			# Allow recalc after timeout
			$better_recalc_timeout = time;
			if ($should_debug) {
				message "DEBUG: Recalc timeout passed, allowing new calculation\n";
			}
		}
		else {
			# We're already moving, don't interrupt
			if ($should_debug) {
				message "DEBUG: Still moving to target, skipping\n";
			}
			return;
		}
	}

	# Only move if we're too far or too close
	if ($dist > $followDistMax || $dist < $followDistMin) {
		if ($should_debug) {
			message sprintf("DEBUG: Outside range (%.1f not between %d-%d), calculating new position\n", 
				$dist, $followDistMin, $followDistMax);
		}
		# Add a reaction timeout to prevent immediate movement
		my $reactionTime = cleanConfigValue($config{'bf_reaction'}, 0.5, 'float');
		
		return unless timeOut($better_reaction_timeout, $reactionTime);
		
		# Calculate the ideal follow distance (middle of min/max range)
		my $targetDist = int(($followDistMin + $followDistMax) / 2);
		
		# Get the leader's body direction (0-7, where 0=north, 2=east, 4=south, 6=west)
		my $leaderDir = $following->{look}{body} || 0;
		
		# Calculate the opposite direction (to be behind the leader)
		my $behindDir = ($leaderDir + 4) % 8;
		
		# Direction vectors: 0=N, 1=NE, 2=E, 3=SE, 4=S, 5=SW, 6=W, 7=NW
		my @dirVectors = (
			{x => 0, y => 1},   # 0: North
			{x => 1, y => 1},   # 1: NE
			{x => 1, y => 0},   # 2: East
			{x => 1, y => -1},  # 3: SE
			{x => 0, y => -1},  # 4: South
			{x => -1, y => -1}, # 5: SW
			{x => -1, y => 0},  # 6: West
			{x => -1, y => 1},  # 7: NW
		);
		
		# Get all cells around the leader within the follow distance range
		my @candidates;
		my $searchRadius = $followDistMax + 1;
		
		for (my $x = $followPos->{x} - $searchRadius; $x <= $followPos->{x} + $searchRadius; $x++) {
			for (my $y = $followPos->{y} - $searchRadius; $y <= $followPos->{y} + $searchRadius; $y++) {
				my $cellDist = distance($followPos, {x => $x, y => $y});
				
				# Only consider cells within our follow distance range
				if ($cellDist >= $followDistMin && $cellDist <= $followDistMax) {
					# Check if the cell is walkable
					if ($field->isWalkable($x, $y)) {
						# Calculate angle from leader to this cell
						my $dx = $x - $followPos->{x};
						my $dy = $y - $followPos->{y};
						
						# Calculate how "behind" this position is
						my $behindVector = $dirVectors[$behindDir];
						my $behindScore = ($dx * $behindVector->{x} + $dy * $behindVector->{y});
						
						push @candidates, {
							x => $x, 
							y => $y, 
							dist => $cellDist,
							behindScore => $behindScore
						};
					}
				}
			}
		}
		
		if (@candidates) {
			# Sort by: 1) How "behind" the leader (higher score better), 2) Closeness to target distance
			@candidates = sort { 
				($b->{behindScore} <=> $a->{behindScore}) ||
				(abs($a->{dist} - $targetDist) <=> abs($b->{dist} - $targetDist))
			} @candidates;
			
			# Pick from top candidates (those with good "behind" scores)
			my $maxBehindScore = $candidates[0]->{behindScore};
			my @topCandidates = grep { $_->{behindScore} >= $maxBehindScore * 0.7 } @candidates;
			@topCandidates = @candidates[0..4] if (@topCandidates == 0 && @candidates > 5); # Fallback to top 5
			
			my $chosen = $topCandidates[int(rand(@topCandidates))];
			$new_pos{'x'} = $chosen->{x};
			$new_pos{'y'} = $chosen->{y};
			
			$better_reaction_timeout = time;
			
			if ($should_debug) {
				message sprintf("DEBUG: Moving to position (%d,%d) at distance %.1f, behind score: %.1f (dir: %d)\n", 
					$new_pos{x}, $new_pos{y}, $chosen->{dist}, $chosen->{behindScore}, $behindDir);
			}
			
			main::ai_route($field->baseName, $new_pos{x}, $new_pos{y},
				distFromGoal => 0,
				attackOnRoute => 2);
		}
	}
	else {
		# We're in good range, clear any stored position
		if (exists $new_pos{x}) {
			delete $new_pos{x};
			delete $new_pos{y};
		}
	}
}

sub ai_post {
	return if (!$net || $net->getState() != Network::IN_GAME);
	
	# Additional post-AI logic can go here
}

sub partyMsg {
	my (undef, $args) = @_;
	
	return unless ($char->{party});
	
	# Debug: Print what we receive
	if ($config{bf_debug}) {
		message "DEBUG partyMsg - Full dump:\n";
		message Dumper($args);
		message "DEBUG partyMsg - Individual fields:\n";
		foreach my $key (sort keys %{$args}) {
			my $val = $args->{$key};
			if (ref($val) eq 'ARRAY') {
				message "  $key => ARRAY (length=" . scalar(@$val) . ")\n";
			} elsif (ref($val)) {
				message "  $key => " . ref($val) . "\n";
			} elsif (!defined $val) {
				message "  $key => undef\n";
			} elsif ($key eq 'RAW_MSG') {
				message "  $key => [binary data, length=" . length($val) . "]\n";
			} else {
				message "  $key => '$val'\n";
			}
		}
	}
	
	# In OpenKore, party_chat packets have these fields:
	# - ID: the actor ID who sent the message
	# - MsgUser: the name of who sent it (sometimes)
	# - Msg: the actual message text
	# We need to get the sender's name from the party data
	
	my $message = $args->{Msg};
	my $senderID = $args->{ID};
	
	message "DEBUG: Initial extraction - Msg=" . (defined $message ? "'$message'" : "undef") . ", ID=" . (defined $senderID ? $senderID : "undef") . "\n" if $config{bf_debug};
	
	# Get sender name from party data or player list
	my $name;
	
	if ($senderID && $char->{party}) {
		# Try to find the sender in party
		if ($char->{party}{users}{$senderID}) {
			$name = $char->{party}{users}{$senderID}{name};
			message "DEBUG: Found name in party data: '$name'\n" if $config{bf_debug};
		} else {
			message "DEBUG: ID '$senderID' not found in party users\n" if $config{bf_debug};
		}
	}
	
	# If we still don't have a name, try the MsgUser field
	unless (defined $name) {
		$name = $args->{MsgUser};
		message "DEBUG: Trying MsgUser field: " . (defined $name ? "'$name'" : "undef") . "\n" if $config{bf_debug};
	}
	
	# Last resort: try parsing from old format "Name : message"
	unless (defined $name && defined $message) {
		if ($args->{message} && $args->{message} =~ /^([^:]+):\s*(.+)$/) {
			$name = $1;
			$name =~ s/^\s+|\s+$//g; # Trim whitespace from both ends
			$message = $2;
			message "DEBUG: Parsed from 'message' field: name='$name', msg='$message'\n" if $config{bf_debug};
		}
	}
	
	# Trim any remaining whitespace from name
	if (defined $name) {
		$name =~ s/^\s+|\s+$//g;
	}
	
	message "DEBUG: Final extraction - name=" . (defined $name ? "'$name'" : "undef") . ", message=" . (defined $message ? "'$message'" : "undef") . "\n" if $config{bf_debug};
	
	return unless defined $message;
	return unless defined $name;
	return unless ($name ne ""); # Make sure name is not empty
	
	# Ignore messages from ourselves
	if ($char->{name} eq $name) {
		message "DEBUG: Ignoring message from ourselves\n" if $config{bf_debug};
		return;
	}
	
	unless (isSpeakerDesignated($name)) {
		message "DEBUG: Speaker '$name' is not designated as commander\n" if $config{bf_debug};
		return;
	}
	
	message "DEBUG: Processing command '$message' from '$name'\n" if $config{bf_debug};
	
	# Command parsing - replaced given/when with if/elsif
	if ($message eq "stay here") {
		stayHere($name);
	}
	elsif ($message eq "lets go") {
		letsGo($name);
	}
	elsif ($message eq "stop") {
		if(defined $bf_args->{'stop'}) {
			sendMessage($messageSender, "p", "Moving!");
			undef $bf_args->{'stop'};
		}
		else {
			sendMessage($messageSender, "p", "Stopping...");
			$bf_args->{'stop'} = $field->baseName;
			$bf_hash{'stop_pos'}{'x'} = $char->{pos_to}{x};
			$bf_hash{'stop_pos'}{'y'} = $char->{pos_to}{y};
		}
	}
	elsif ($message eq "whats my job") {
		my $whatever;
		if (defined $name && $name ne "") {
			foreach my $player (@{$playersList->getItems()}) {
				if (defined $player->{name} && $name eq $player->{name}) {
					$whatever = $player->{jobID};
					last;
				}
			}
		}
		if (defined $whatever) {
			sendMessage($messageSender, "p", "Your job id is $whatever");
		} else {
			sendMessage($messageSender, "p", "Could not find your job ID");
		}
	}
	elsif ($message eq "use con") {
		my $item = $char->inventory->getByNameList("Concentration Potion");
		if ($item) {
			$messageSender->sendItemUse($item->{ID}, $accountID);
		}
	}
	elsif ($message =~ /^cast\s+(.+)$/i) {
		my $skillName = $1;
		my $skill = new Skill(auto => $skillName);
		
		if($char->{skills}{$skill->getHandle()}) {
			my $level = $char->{skills}{$skill->getHandle()}{lv};
			$skill = new Skill(auto => $skillName, level => $level);
			
			my $actorList = $playersList;
			my $target = $char;
			
			require Task::UseSkill;
			my $skillTask = new Task::UseSkill(
				actor => $skill->getOwner,
				target => $target,
				actorList => $actorList,
				skill => $skill,
				priority => Task::USER_PRIORITY
			);
			my $task = new Task::ErrorReport(task => $skillTask);
			$taskManager->add($task);
		}
	}
	elsif ($message =~ /(\w+)\s+(\w+)\s+is\s+at\s+(\d+)\s+(\d+)/ && $bf_args->{'search_for_follow'}) {
		undef $bf_args->{'search_for_follow'};
		ai_route($field->baseName, $3, $4, attackOnRoute => 0);
		message TF("Moving to: %s, %s to find master\n", $3, $4), "teleport";
		$mytimeout->{'search_for_leader'} = time + 60;
	}
	elsif ($message =~ /(\w+)\s+is\s+at\s+(\d+)\s+(\d+)/ && $bf_args->{'search_for_follow'}) {
		undef $bf_args->{'search_for_follow'};
		ai_route($field->baseName, $2, $3, attackOnRoute => 0);
		message TF("Moving to: %s, %s to find master\n", $2, $3), "teleport";
		$mytimeout->{'search_for_leader'} = time + 60;
	}
	elsif ($message eq "this is a test") {
		sendMessage($messageSender, "p", "test received");
	}
}

sub isSpeakerOnScreen {
	my ($args) = @_;
	
	foreach my $player (@{$playersList->getItems()}) {
		return 1 if($args eq $player->{name});
	}
	
	return 0;
}

sub storeFollowTarget {
	if(!defined $storedFollow) {
		$storedFollow = $config{followTarget};
		message TF("Storing followTarget: $config{followTarget}\n"), "follow";
	}
}

sub reloadFollowTarget {
	if(defined $storedFollow) {
		configModify("followTarget", $storedFollow);
	}
}

sub letsGo {
	my ($args) = @_;
	return unless defined $bf_args->{'base'};
	undefBase();
}

sub stayHere {
	my ($args) = @_;

	storeFollowTarget();
	return unless isSpeakerOnScreen($args);

	sendMessage($messageSender, "p", "base set");
	$bf_args->{'base'} = $field->baseName;
	$bf_hash{'base_pos'}{'x'} = $char->{pos_to}{x};
	$bf_hash{'base_pos'}{'y'} = $char->{pos_to}{y};

	configModify("followTarget", "BASE");

	AI::dequeue if (defined AI::action && AI::action eq "follow");
	AI::queue("follow");
}

sub isSpeakerDesignated {
	my ($args) = @_;
	return 1 if existsInList($config{"bf_Commanders"}, $args);
	return 0;
}

sub undefBase {
	$bf_args->{'base'} = undef;
	$bf_hash{'base_pos'} = undef;
	configModify("bf_baseMap", undef);
	configModify("bf_baseX", undef);
	configModify("bf_baseY", undef);
}

return 1;