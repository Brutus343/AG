package lkPartyLeader;

use strict;
use Plugins;
use Settings;
use Log qw(message warning error);
use Globals qw($char @monstersID %monsters);
use Commands;
use Utils;
use Actor;

Plugins::register('lkPartyLeader', 'LK Party Leader communication', \&unload);

my $hooks = Plugins::addHooks(
    ['packet/actor_action', \&onAttack],
    ['is_casting', \&onCasting],
    ['mainLoop_post', \&onAI]
);

my $currentTarget = "";
my $lastDangerCheck = 0;

message "[lkPartyLeader] Plugin loaded! Will announce targets on engage.\n", "success";

sub unload {
    Plugins::delHooks($hooks);
    message "[lkPartyLeader] Plugin unloaded.\n";
}

sub onAI {
    return unless $char;
    my $now = time;
    
    # Check for danger every 3 seconds
    if ($now - $lastDangerCheck > 3) {
        $lastDangerCheck = $now;
        checkDangerLevel();
    }
}

sub onAttack {
    my (undef, $args) = @_;
    
    # Check if this is our character attacking
    return unless $args->{sourceID} eq $char->{ID};
    return unless $args->{targetID};
    
    my $target = Actor::get($args->{targetID});
    return unless $target;
    
    announceTarget($target);
}

sub onCasting {
    my (undef, $args) = @_;
    
    return unless $args->{sourceID} && $args->{sourceID} eq $char->{ID};
    return unless $args->{targetID};
    
    my $target = Actor::get($args->{targetID});
    return unless $target;
    
    announceTarget($target);
}

sub announceTarget {
    my ($target) = @_;
    
    my $targetInfo = $target->{name} . " #" . $target->{binID};
    
    # Only announce if target changed
    if ($targetInfo ne $currentTarget) {
        $currentTarget = $targetInfo;
        
        my $announcement = "Engaging $targetInfo";
        Commands::run("p $announcement");
        message "[lkPartyLeader] $announcement\n", "success";
    }
}

sub checkDangerLevel {
    my $nearbyCount = 0;
    my $range = 8;
    
    # Count monsters within 8 cells
    foreach my $id (@monstersID) {
        next unless $id;
        my $monster = $monsters{$id};
        next unless $monster;
        
        my $dist = distance($char->{pos_to}, $monster->{pos_to});
        if ($dist <= $range) {
            $nearbyCount++;
        }
    }
    
    # Warn if 3+ monsters nearby
    if ($nearbyCount >= 3) {
        Commands::run("p DANGER! $nearbyCount monsters nearby!");
        message "[lkPartyLeader] DANGER! $nearbyCount monsters nearby!\n", "warning";
        
        # Don't spam - wait 10 seconds before next warning
        $lastDangerCheck = time + 7;
    }
}

1;