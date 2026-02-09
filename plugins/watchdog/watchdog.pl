package watchdog;

use strict;
use Plugins;
use Globals;
use Log qw(message);
use AI;

Plugins::register('watchdog', 'Stagnation Watchdog with Debug', \&on_unload);
my $hooks = Plugins::addHooks(['AI_pre', \&check_status]);

# Settings
my $checkInterval = 300; # 5 minutes
my $lastCheckTime = time;
my $oldX = 0;
my $oldY = 0;
my $oldKills = 0;

sub check_status {
    # 1. Timer check
    my $elapsed = time - $lastCheckTime;
    return if ($elapsed < $checkInterval);
    $lastCheckTime = time;

    # 2. Safety Check - Are we actually in game?
    if (!$char || !$net || $net->getState() != 5) {
        message "[Watchdog] Skipping check: Not fully logged in.\n", "info";
        return;
    }

    # 3. Data Collection
    my $curX = $char->{pos}{x} || 0;
    my $curY = $char->{pos}{y} || 0;
    my $curKills = $char->{mobs_killed} || 0;

    # 4. DEBUG LOG (This will show up in your console every 5 mins)
    message "[Watchdog] Heartbeat - Pos: ($curX, $curY) Kills: $curKills | Prev: ($oldX, $oldY) Kills: $oldKills\n", "info";

    # 5. The Comparison
    # We check if the bot has moved OR if the kill count has increased.
    if ($curX == $oldX && $curY == $oldY && $curKills <= $oldKills) {
        message "[Watchdog] !!! STUCK DETECTED !!! Sending reset commands...\n", "info";
        
        # Use direct chat command for @go
        Commands::run("c \@go 11");
        
        # Clear AI and Force a full re-think
        AI::clear;
        # Force the bot to stop what it's doing and re-evaluate
        $ai_seq = ""; 
        
        message "[Watchdog] AI Cleared and @go 11 sent.\n", "info";
    } else {
        message "[Watchdog] Bot is active. No action needed.\n", "info";
    }

    # 6. Snapshot for next time
    $oldX = $curX;
    $oldY = $curY;
    $oldKills = $curKills;
}

sub on_unload {
    # Cleanup
}

1;