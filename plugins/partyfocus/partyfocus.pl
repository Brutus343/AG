package dpsFocusFire;

use strict;
use Plugins;
use Settings;
use Log qw(message warning error);
use Globals qw($char @monstersID %monsters);
use Commands;
use Actor;

Plugins::register('dpsFocusFire', 'Focus fire on leader target', \&unload);

my $hooks = Plugins::addHooks(
    ['packet/party_chat', \&onPartyChat]
);

my $leaderTarget = "";
my $leaderTargetBinID = "";

message "[dpsFocusFire] Plugin loaded! Listening for leader engage commands.\n", "success";

sub unload {
    Plugins::delHooks($hooks);
    message "[dpsFocusFire] Plugin unloaded.\n";
}

sub onPartyChat {
    my (undef, $args) = @_;
    
    my $msg = $args->{message} || "";
    
    # Parse "Engaging Monster #5" format
    if ($msg =~ /Engaging (.+) #(\d+)/) {
        my $monsterName = $1;
        my $binID = $2;
        
        message "[dpsFocusFire] Leader engaging: $monsterName #$binID\n", "info";
        
        $leaderTarget = $monsterName;
        $leaderTargetBinID = $binID;
        
        switchToTarget($binID);
    }
}

sub switchToTarget {
    my ($targetBinID) = @_;
    
    message "[dpsFocusFire] Searching for monster with binID: $targetBinID\n", "info";
    
    # Find the monster by binID
    foreach my $id (@monstersID) {
        next unless $id;
        my $monster = $monsters{$id};
        next unless $monster;
        
        if ($monster->{binID} eq $targetBinID) {
            message "[dpsFocusFire] Found target! Switching to $monster->{name} #$targetBinID\n", "success";
            
            # Clear AI queue and force new target
            Commands::run("ai clear attack");
            Commands::run("a " . $monster->{binID});
            
            return;
        }
    }
    
    message "[dpsFocusFire] Could not find monster with binID $targetBinID\n", "warning";
}

1;