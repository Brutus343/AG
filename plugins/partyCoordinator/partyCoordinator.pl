package underAttackAlert;

use strict;
use Plugins;
use Settings;
use Log qw(message warning error);
use Globals qw($char @monstersID %monsters);
use Commands;
use Utils;

Plugins::register('underAttackAlert', 'Alert party when being attacked', \&unload);

my $hooks = Plugins::addHooks(
    ['mainLoop_post', \&onAI]
);

my $lastThreatCheck = 0;

message "[underAttackAlert] Plugin loaded! Will alert party when attacked.\n", "success";

sub unload {
    Plugins::delHooks($hooks);
    message "[underAttackAlert] Plugin unloaded.\n";
}

sub onAI {
    return unless $char;
    my $now = time;
    
    # Check every 4 seconds
    if ($now - $lastThreatCheck > 4) {
        $lastThreatCheck = $now;
        checkIfUnderAttack();
    }
}

sub checkIfUnderAttack {
    # Check if any monster is targeting this character
    foreach my $id (@monstersID) {
        next unless $id;
        my $monster = $monsters{$id};
        next unless $monster;
        
        # Check if monster's target is this character
        if ($monster->{target} && $monster->{target} eq $char->{ID}) {
            my $dist = distance($char->{pos_to}, $monster->{pos_to});
            
            # Only warn if monster is close (within 7 cells)
            if ($dist <= 7) {
                my $announcement = "I am being attacked by " . $monster->{name} . " #" . $monster->{binID} . "!";
                Commands::run("p $announcement");
                message "[underAttackAlert] $announcement\n", "warning";
                
                # Only warn once every 10 seconds to avoid spam
                $lastThreatCheck = time + 6;
                return;
            }
        }
    }
}

1;