package PartySetup;

use strict;
use Plugins;
use Settings;
use Log qw(message warning error);
use Globals qw($char $messageSender %config @playersID %players $field @partyUsersID);
use Commands;
use Utils;
use Misc;

Plugins::register('PartySetup', 'Party coordination and dungeon entry', \&unload);

my $hooks = Plugins::addHooks(
    ['packet/party_chat', \&onPartyChat],
    ['AI_pre', \&onAI]
);

# State machine
my $setupState = "idle"; # idle, checking_party, waiting_storage, waiting_buy, moving_out, waiting_arrival, entering_dungeon
my $stateStartTime = 0;
my $checkInterval = 0;

message "[PartySetup] Plugin loaded! Type 'start' in party chat to begin.\n", "success";

sub unload {
    Plugins::delHooks($hooks);
    message "[PartySetup] Plugin unloaded.\n";
}

sub onPartyChat {
    my (undef, $args) = @_;
    
    my $msg = $args->{message} || "";
    message "[PartySetup] Party message: '$msg'\n", "info";
    
    # Message format is "SenderName : message"
    # Extract the actual message part
    if ($msg =~ /^(.+?)\s*:\s*(.+)$/) {
        my $senderName = $1;
        my $actualMsg = $2;
        
        message "[PartySetup] Sender: '$senderName' | Message: '$actualMsg' | My name: '" . $char->{name} . "'\n", "info";
        
        # Only respond to our own messages
        return unless $senderName eq $char->{name};
        
        if ($actualMsg =~ /^start$/i && $setupState eq "idle") {
            message "[PartySetup] Starting party setup sequence!\n", "success";
            $setupState = "checking_party";
            $stateStartTime = time;
            checkPartyStatus();
        }
    }
}

sub onAI {
    return unless $char;
    my $now = time;
    
    # State machine updates
    if ($setupState eq "waiting_storage" && $now - $stateStartTime > 60) {
        message "[PartySetup] Storage time complete, sending autobuy command\n", "info";
        Commands::run("p Autobuy");
        $setupState = "waiting_buy";
        $stateStartTime = $now;
    }
    
    if ($setupState eq "waiting_buy" && $now - $stateStartTime > 60) {
        message "[PartySetup] Buy time complete, telling party to move out\n", "info";
        Commands::run("p Move out");
        $setupState = "moving_out";
        $stateStartTime = $now;
        setGatherPoint();
    }
    
    if ($setupState eq "moving_out" && $now - $checkInterval > 5) {
        $checkInterval = $now;
        if (arrivedAtGatherPoint()) {
            message "[PartySetup] Leader arrived at gather point, waiting for party...\n", "info";
            $setupState = "waiting_arrival";
            $stateStartTime = $now;
        }
    }
    
    if ($setupState eq "waiting_arrival" && $now - $checkInterval > 10) {
        $checkInterval = $now;
        if (checkPartyArrived()) {
            message "[PartySetup] Everyone has arrived! Entering dungeon...\n", "success";
            $setupState = "entering_dungeon";
            enterDungeon();
        } elsif ($now - $stateStartTime > 300) {
            warning "[PartySetup] Timeout waiting for party (5 minutes). Entering anyway...\n";
            $setupState = "entering_dungeon";
            enterDungeon();
        }
    }
}

sub checkPartyStatus {
    my @partyMembers = split(/,\s*/, $config{partySetup_members});
    my $townMap = $config{partySetup_townMap} || "prontera";
    
    # Refresh party info first
    Commands::run("c \@refresh");
    message "[PartySetup] Refreshing party info...\n", "info";
    
    message "[PartySetup] Checking party members: " . join(", ", @partyMembers) . "\n", "info";
    message "[PartySetup] Current map: " . $field->baseName . " | Required town: $townMap\n", "info";
    
    my $allPresent = 1;
    my $allAlive = 1;
    
    # Check if leader is in town
    if ($field->baseName ne $townMap) {
        message "[PartySetup] WARNING: Leader not in town ($townMap)! Current map: " . $field->baseName . "\n", "warning";
        $allPresent = 0;
    }
    
    # Debug: Show all party members
    message "[PartySetup] === All Party Members ===\n", "info";
    foreach my $id (@partyUsersID) {
        next unless $id;
        my $member = $char->{party}{users}{$id};
        next unless $member;
        
        my $memberMap = $member->{map} || "unknown";
        my $memberHP = $member->{hp} || 0;
        my $memberOnline = $member->{online} ? "Yes" : "No";
        
        message "[PartySetup] - " . $member->{name} . " | Map: $memberMap | HP: $memberHP | Online: $memberOnline\n", "info";
    }
    message "[PartySetup] ========================\n", "info";
    
    foreach my $memberName (@partyMembers) {
        $memberName =~ s/^\s+|\s+$//g; # trim whitespace
        
        message "[PartySetup] Checking for: '$memberName'\n", "info";
        
        # Find member in party
        my $found = 0;
        foreach my $id (@partyUsersID) {
            next unless $id;
            my $member = $char->{party}{users}{$id};
            next unless $member;
            
            if ($member->{name} eq $memberName) {
                $found = 1;
                
                # Check if online
                unless ($member->{online}) {
                    message "[PartySetup] WARNING: $memberName is OFFLINE!\n", "warning";
                    $allPresent = 0;
                    last;
                }
                
                # Check if alive
                if ($member->{hp} == 0) {
                    message "[PartySetup] WARNING: $memberName is DEAD!\n", "warning";
                    $allAlive = 0;
                }
                
                # Check if on same map
                my $memberMap = $member->{map} || "";
                # Remove .gat extension if present
                $memberMap =~ s/\.gat$//;
                my $currentMap = $field->baseName;
                
                if ($memberMap && $memberMap ne $currentMap) {
                    message "[PartySetup] WARNING: $memberName is on different map: $memberMap (need: $currentMap)\n", "warning";
                    $allPresent = 0;
                }
                
                last;
            }
        }
        
        unless ($found) {
            message "[PartySetup] WARNING: $memberName not found in party!\n", "warning";
            $allPresent = 0;
        }
    }
    
    if ($allPresent && $allAlive) {
        message "[PartySetup] All party members present and alive! Proceeding...\n", "success";
        Commands::run("p Autostorage");
        $setupState = "waiting_storage";
        $stateStartTime = time;
    } else {
        message "[PartySetup] Party check failed. Please fix issues and type 'start' again.\n", "error";
        $setupState = "idle";
    }
}

sub setGatherPoint {
    my $gatherMap = $config{partySetup_gatherMap} || "moc_fild07";
    my $gatherX = $config{partySetup_gatherX} || 200;
    my $gatherY = $config{partySetup_gatherY} || 200;
    
    message "[PartySetup] Setting gather point: $gatherMap ($gatherX, $gatherY)\n", "info";
    
    Commands::run("conf lockMap $gatherMap");
    Commands::run("conf lockMap_x $gatherX");
    Commands::run("conf lockMap_y $gatherY");
}

sub arrivedAtGatherPoint {
    my $gatherMap = $config{partySetup_gatherMap} || "moc_fild07";
    my $gatherX = $config{partySetup_gatherX} || 200;
    my $gatherY = $config{partySetup_gatherY} || 200;
    my $tolerance = 5;
    
    return 0 unless $field->baseName eq $gatherMap;
    
    my $dist = distance({x => $char->{pos_to}{x}, y => $char->{pos_to}{y}}, 
                       {x => $gatherX, y => $gatherY});
    
    if ($dist <= $tolerance) {
        # Clear lockMap to stop "calculating route" spam
        message "[PartySetup] Arrived! Clearing lockMap to stop routing.\n", "info";
        Commands::run("conf lockMap");
        Commands::run("conf lockMap_x");
        Commands::run("conf lockMap_y");
        return 1;
    }
    
    return 0;
}

sub checkPartyArrived {
    my @partyMembers = split(/,\s*/, $config{partySetup_members});
    my $gatherMap = $config{partySetup_gatherMap} || "moc_fild07";
    my $gatherX = $config{partySetup_gatherX} || 200;
    my $gatherY = $config{partySetup_gatherY} || 200;
    my $maxDistance = 15;
    
    # Refresh party info
    Commands::run("c \@refresh");
    
    my $allArrived = 1;
    
    message "[PartySetup] === Checking Party Arrival ===\n", "info";
    
    foreach my $memberName (@partyMembers) {
        $memberName =~ s/^\s+|\s+$//g;
        
        my $found = 0;
        
        # First check party list to see if they're on same map
        foreach my $id (@partyUsersID) {
            next unless $id;
            my $member = $char->{party}{users}{$id};
            next unless $member;
            
            if ($member->{name} eq $memberName) {
                my $memberMap = $member->{map} || "";
                $memberMap =~ s/\.gat$//;
                
                if ($memberMap ne $field->baseName) {
                    message "[PartySetup] $memberName still on different map: $memberMap\n", "info";
                    $allArrived = 0;
                    $found = 1;
                    last;
                }
            }
        }
        
        next if $found; # Already know they're not here
        
        # Now check players list for distance
        $found = 0;
        foreach my $id (@playersID) {
            next unless $id;
            my $player = $players{$id};
            next unless $player;
            
            if ($player->{name} eq $memberName) {
                $found = 1;
                
                my $dist = distance($player->{pos_to}, {x => $gatherX, y => $gatherY});
                
                if ($dist > $maxDistance) {
                    message "[PartySetup] Waiting for $memberName (distance: " . sprintf("%.1f", $dist) . ")\n", "info";
                    $allArrived = 0;
                } else {
                    message "[PartySetup] $memberName is here! (distance: " . sprintf("%.1f", $dist) . ")\n", "info";
                }
                
                last;
            }
        }
        
        unless ($found) {
            message "[PartySetup] Can't see $memberName nearby yet...\n", "info";
            $allArrived = 0;
        }
    }
    
    message "[PartySetup] ==========================\n", "info";
    
    return $allArrived;
}

sub enterDungeon {
    my $dungeonMap = $config{partySetup_dungeonMap} || "moc_pryd01";
    my $dungeonX = $config{partySetup_dungeonX} || 100;
    my $dungeonY = $config{partySetup_dungeonY} || 100;
    
    message "[PartySetup] Entering dungeon: $dungeonMap ($dungeonX, $dungeonY)\n", "success";
    
    Commands::run("conf lockMap $dungeonMap");
    Commands::run("conf lockMap_x $dungeonX");
    Commands::run("conf lockMap_y $dungeonY");
    Commands::run("conf route_randomWalk 1");
    
    # Reset state
    $setupState = "idle";
    
    message "[PartySetup] Setup complete! Good hunting!\n", "success";
}

1;