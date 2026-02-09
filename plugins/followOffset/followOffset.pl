# followOffset - OpenKore plugin to add offset when following a leader
# Usage:
#   Add the following to your config
#   followOffset <x> <y>

package followOffset;

use strict;
use Plugins;
use Globals;
use Log qw(message debug);
use Time::HiRes qw(time);
use Misc;
use Utils;
use AI;
use Math::Trig;

Plugins::register('followOffset', 'add position offset when following', \&onUnload, \&onUnload);

my $hooks = Plugins::addHooks(
	['ai_follow', \&onAIFollow, undef],
);

my %followTimeout;
$followTimeout{timeout} = 0.25;

my $masterLastMoveTime;

sub onUnload {
	Plugins::delHooks($hooks);
}

sub onAIFollow {
	return unless $config{followOffset};

	my (undef, $args) = @_;
	# Increase timeout so that original follow movement won't be executed.
	$args->{move_timeout} = time + 10;
	# On the original follow logic, actor will reroute if the last stored master last move time doesn't equal to the actual actor last move time.
	# We can disable it by setting the value to undef.
	$args->{masterLastMoveTime} = undef;

	my $master = $players{$args->{ID}};
	return unless $master && $master->{pos_to};
	return unless $args->{following};

	if (AI::action eq "follow" && !$args->{ai_follow_lost} && timeOut(\%followTimeout)) {
		$followTimeout{timeout} = time;
		$masterLastMoveTime = $master->{time_move};

		routeUsingOffset($master);
	} elsif (((AI::action eq "route" && AI::action(1) eq "follow") || (AI::action eq "move" && AI::action(2) eq "follow")) && !$args->{ai_follow_lost}) {
		if (
			$masterLastMoveTime &&
			$masterLastMoveTime != $master->{time_move}
		) {
			debug "[formation] Master $master has moved since we started routing to it - Adjusting route\n", "followOffset";
			AI::dequeue;
			AI::dequeue if (AI::action eq "route");

			$followTimeout{timeout} = time;
			$masterLastMoveTime = $master->{time_move};

			routeUsingOffset($master);
		}
	}
}

sub routeUsingOffset {
	my ($master) = @_;

	my $currentPos = calcPosition($char);
	my $distFromGoal = 0;

	my $targetPos;
	$targetPos->{x} = $master->{pos_to}{x};
	$targetPos->{y} = $master->{pos_to}{y};

	my $offsetPos;
	my $offset = getOffset();
	$offset = rotate($offset, directionToAngle($master));
	$offsetPos->{x} = $master->{pos_to}{x} + $offset->{x};
	$offsetPos->{y} = $master->{pos_to}{y} + $offset->{y};

	if (
		$field->isWalkable($targetPos->{x}, $targetPos->{y}) &&
		$field->checkLOS($currentPos, $targetPos) &&
		!positionNearPortal($targetPos, $config{attackMinPortalDistance})
	) {
		$targetPos = $offsetPos;
	}

	ai_route(
		$field->baseName,
		$targetPos->{x},
		$targetPos->{y},
		attackOnRoute => 1,
		isFollow => 1,
		distFromGoal => $distFromGoal,
	);
}

sub getOffset {
	my $offset;
	my ($x, $y) = split " ", $config{followOffset};
	$offset->{x} = int($x);
	$offset->{y} = int($y);

	return $offset;
}

sub directionToAngle {
	my ($actor) = @_;
	my $dir = $actor->{look}{body};
	my %angles = (
		0 => 0,    # North
		1 => 45,   # Northwest
		2 => 90,   # West
		3 => 135,  # Southwest
		4 => 180,  # South
		5 => 225,  # Southeast
		6 => 270,  # East
		7 => 315,  # Northeast
	);

	return $angles{$dir} || 0;
}

sub rotate {
	my ($pos, $angle) = @_;

	my $radians = deg2rad($angle);

	my $x = $pos->{x};
	my $y = $pos->{y};

	my $rotated_x = $x * cos($radians) - $y * sin($radians);
	my $rotated_y = $x * sin($radians) + $y * cos($radians);

	return { x => $rotated_x, y => $rotated_y };
}

1;
