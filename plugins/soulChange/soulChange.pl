# SoulChange plugin.
# A simple queue for soul change skill.
#
# This plugin listens to "I need mana!" party message and queue the sender for soul change.
#
# available config:
#   soulChange [1|0] - enable or disable the plugin.
#   soulChange_minSPPercent [value] - minimum SP to cast the soul change, default to 50 (percent).
#   soulChange_timeout [value] - timeout for the soul change skill, default to 5 (seconds).
#   soulChange_priority [value] - priority for the queue, comma separated.
#   soulChange_maxAttempts [value] - maximum number of attempts allowed to use soul change, default to 2.
#
# You can use this plugin with doCommand block in your config.txt. For example:
#  doCommand p I need mana! {
#    partyAggressives > 0
#    sp < 20%
#    timeout 5
#  }

package soulChange;

use strict;

use Plugins;
use Globals;
use Log qw(message);
use Time::HiRes qw(time);
use Utils;
use Misc;
use Commands;
use Data::Dumper;
use AI;

Plugins::register('soulChange', 'Simple queue for soul change',\&unload, \&unload);

my $hooks = Plugins::addHooks(
	['AI_pre', \&onAIPre, undef],
	['packet_partyMsg', \&onPartyMsg, undef],
	['packet_skilluse', \&onSkillUse, undef],
);

my $attempts = 0;
my $defaultMaxAttempts = 2;
my %priorityHash = ();
my $prioQueue = [];

my $timer = time;

sub unload {
	Plugins::delHooks($hooks);
}

sub onAIPre {
	processSoulChange();
}

sub onPartyMsg {
	return unless $config{soulChange};

	my (undef, $args) = @_;

	if ($args->{Msg} eq "I need mana!") {
		insert($args->{MsgUser});
	}
}

sub processSoulChange {
	return unless $config{soulChange};
	return unless scalar(@{$prioQueue}) > 0;
	return if $char->sp_percent() < ($config{soulChange_minSPPercent} || 50);

	my $timeout = $config{soulChange_timeout} || 5;
	my $maxAttempts = $config{soulChange_maxAttempts} || $defaultMaxAttempts;

	if (AI::isIdle || AI::is(qw(route mapRoute follow sitAuto take items_gather items_take attack move))) {
		my $target = $prioQueue->[0]{name};

		if ($attempts >= $maxAttempts) {
			message "[soulChange] max attempts reached.. removing $target from the queue\n", "plugin";
			remove($target);
			$attempts = 0;
			return;
		}

		my $player = Match::player($target);
		if ($player && timeOut($timer, $timeout)) {
			$timer = time;

			if ($player->{dead}) {
				message "[soulChange] player is dead... removing $target from the queue\n", "plugin";
				remove($target);
				$attempts = 0;
				return;
			}

			my $distance = distance(calcPosition($char), calcPosition($player));

			# Need to walk to the target if out of range so that we can cast the skill.
			if ($distance > 8) {
				my $targetPos = calcPosition($player);
				ai_route(
					$field->baseName,
					$targetPos->{x},
					$targetPos->{y},
					distFromGoal => 4,
				);
			}

			my $skill = Skill->new(auto => "Soul Change");
			ai_skillUse2($skill, 1, undef, undef , $player);
			$attempts++;
		}
	}
}

sub insert {
	my $name = shift;

	my %priorityHash = getPriority();
	my $priority = $priorityHash{$name};
	$priority = 999 if !defined $priority;

	my $el = {
		name => $name,
		priority => $priority,
	};

	foreach my $q (@{$prioQueue}) {
		return if $q->{name} eq $el->{name};
	}

	push(@{$prioQueue}, $el);

	my $i = scalar(@{$prioQueue}) - 1;
	while ($i > 0 && $prioQueue->[$i]{priority} < $prioQueue->[$i - 1]{priority}) {
		# swap
		my $temp = $prioQueue->[$i];
		$prioQueue->[$i] = $prioQueue->[$i - 1];
		$prioQueue->[$i - 1] = $temp;

		$i--;
	}
}

sub remove {
	return if scalar(@{$prioQueue}) == 0;
	my $name = shift;

	my $index = -1;
	for (my $i = 0; $i < scalar(@{$prioQueue}); $i++) {
		$index = $i if $prioQueue->[$i]{name} eq $name;
	}

	if ($index != -1) {
		splice(@{$prioQueue}, $index, 1);
	} else {
		shift @{$prioQueue}; # should not happen
	}
}

sub parsePriority {
	my $priorityStr = shift;
	my @priorityArr = split / *, */, $priorityStr;

	for my $i (0 .. $#priorityArr) {
		$priorityHash{$priorityArr[$i]} = $i;
	}
}

sub getPriority {
	if ($config{soulChange_priority} && scalar(keys(%priorityHash)) == 0) {
		parsePriority($config{soulChange_priority});
	}

	return %priorityHash;
}

sub onSkillUse {
	return unless $config{soulChange};

	my (undef, $args) = @_;

	if ($args->{skillID} == 374 && $args->{sourceID} eq $accountID) {
		$attempts = 0;
		my $player = $playersList->getByID($args->{targetID});
		message "[soulChange] successfully casted soul change on $player->{name}\n", "plugin";
		remove($player->{name});
		if (scalar(@{$prioQueue}) == 0) {
			message "[soulChange] queue is empty now\n", "plugin";
		} else {
			message "[soulChange] currently in the queue: " . queueString() . "\n", "plugin";
		}
	}
}

sub queueString {
	my $sep = "";
	my $str = "";
	foreach my $q (@{$prioQueue}) {
		$str .= $sep . $q->{name};
		$sep = ", ";
	}

	return $str;
}

1;
