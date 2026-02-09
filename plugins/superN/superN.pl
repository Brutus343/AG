package supernoviGlassCannon;

use strict;
use Plugins;
use Settings;
use Log qw(message warning error);
use Globals qw($char $messageSender @monstersID %monsters %config $field);
use Commands;
use Utils;
use Actor;

Plugins::register('supernoviGlassCannon', 'Supernovice glass cannon - cast and flee', \&unload);

my $hooks = Plugins::addHooks(
    ['mainLoop_post', \&onAI]
);

my $lastCheck = 0;
my $state = "idle"; # idle, casting, fleeing
my $castTarget = "";
my $fleeTimer = 0;

message "[supernoviGlassCannon] Plugin loaded! Standing still and casting Cold Bolt.\n", "success";

sub unload {
    Plugins::delHooks($hooks);
    message "[supernoviGlassCannon] Plugin unloaded.\n";
}

sub onAI {
    return unless $char;
    my $now = time;
    
    # Don't do anything if not in lockMap
    return unless $config{lockMap};
    return unless $field->baseName eq $config{lockMap};
    
    # Always prevent movement
    Commands::run("move stop") if $char->{moving};
    
    # Handle flee delay
    if ($state eq "fleeing" && $now >= $fleeTimer) {
        message "[supernoviGlassCannon] Fleeing!\n", "warning";
        Commands::run("tele");
        $state = "idle";
        return;
    }
    
    # Don't check while waiting to flee
    return if $state eq "fleeing";
    
    # Check every 0.5 seconds
    if ($now - $lastCheck >= 0.5) {
        $lastCheck = $now;
        scanAndAct();
    }
}

sub scanAndAct {
    my @dangerClose = ();  # Within 3 cells - DANGER
    my @inRange = ();      # Within 9 cells - can cast

    foreach my $id (@monstersID) {
        next unless $id;
        my $monster = $monsters{$id};
        next unless $monster;
        
        my $dist = distance($char->{pos_to}, $monster->{pos_to});
        
        if ($dist <= 3) {
            push @dangerClose, {monster => $monster, dist => $dist};
        } elsif ($dist <= 9) {
            push @inRange, {monster => $monster, dist => $dist};
        }
    }
    
    # Priority 1: ANYTHING within 3 cells = instant teleport
    if (@dangerClose) {
        message "[supernoviGlassCannon] DANGER! " . scalar(@dangerClose) . " monster(s) too close! Teleporting!\n", "warning";
        Commands::run("tele");
        $state = "idle";
        return;
    }
    
    # Priority 2: Monsters in range but none close = cast Cold Bolt then flee
    if (@inRange && $state eq "idle") {
        # Pick closest monster in range
        my $closest = $inRange[0];
        foreach my $target (@inRange) {
            if ($target->{dist} < $closest->{dist}) {
                $closest = $target;
            }
        }
        
        my $monster = $closest->{monster};
        message "[supernoviGlassCannon] Casting Cold Bolt on " . $monster->{name} . " #" . $monster->{binID} . " (dist: " . sprintf("%.1f", $closest->{dist}) . ")\n", "info";
        
        Commands::run("sm " . $monster->{binID} . " Cold Bolt");
        
        # Set flee timer for 0.5 seconds after cast
        $state = "fleeing";
        $fleeTimer = time + 0.5;
        return;
    }
}

1;