package mvpHunter;

use strict;
use Plugins;
use Settings;
use Log qw(message warning error);
use Globals qw($bus $char %config);
use Commands;

Plugins::register('mvpHunter', 'Automatic MVP hunting coordinator', \&onUnload);

my $hooks = Plugins::addHooks(
    ['bus_received', \&onBusMessage]
);

my $currentTarget = undef;  # Currently hunting MVP
my @huntQueue = ();          # Queue of MVPs waiting to be hunted

sub onUnload {
    Plugins::delHooks($hooks);
    message "[mvpHunter] Plugin unloaded.\n";
}

sub onBusMessage {
    my (undef, $args) = @_;
    my $msg = $args->{message};
    
    # Parse MVP spawn message: "   >>> ALERT: "BossName" is UP at map_name!"
    if ($msg =~ />>> ALERT: "(.+?)" is UP at (.+?)!/) {
        my $mvpName = $1;
        my $mapName = $2;
        handleMVPSpawn($mvpName, $mapName);
    }
    # Parse MVP death message: "   [!!!] DEAD: "BossName" just died at HH:MM:SS!"
    elsif ($msg =~ /\[!!!\] DEAD: "(.+?)" just died at/) {
        my $mvpName = $1;
        handleMVPDeath($mvpName);
    }
}

sub handleMVPSpawn {
    my ($mvpName, $mapName) = @_;
    
    # Check if this MVP is in our hunt list
    my @huntList = split(/,\s*/, $config{mvpHunter_whitelist} || '');
    
    unless (grep { lc($mvpName) eq lc($_) } @huntList) {
        message "[mvpHunter] Ignoring $mvpName (not in whitelist)\n", "mvpHunter";
        return;
    }
    
    # Check if we're already hunting something
    if ($currentTarget) {
        message "[mvpHunter] Already hunting $currentTarget->{name}. Adding $mvpName to queue.\n", "info";
        
        # Check if this MVP is already in queue to avoid duplicates
        unless (grep { $_->{name} eq $mvpName } @huntQueue) {
            push @huntQueue, { name => $mvpName, map => $mapName };
            
            if ($config{mvpHunter_partyChat}) {
                Commands::run("p $mvpName spawned at $mapName but I'm busy with $currentTarget->{name}. Queued for later.");
            }
        }
        return;
    }
    
    # Set this as current target
    $currentTarget = { name => $mvpName, map => $mapName };
    
    message "[mvpHunter] >>> $mvpName spawned at $mapName! Heading there now...\n", "success";
    
    # Announce in party chat
    if ($config{mvpHunter_partyChat}) {
        Commands::run("p $mvpName just spawned! Setting lockMap to $mapName and going hunting.");
    }
    
    # Set lockMap to the MVP's spawn location
    Commands::run("conf lockMap $mapName");
    
    # Optional: Send bus message to coordinate with other bots
    if ($config{mvpHunter_announce}) {
        $bus->send("mvpHunter", {
            action => "hunting",
            mvp => $mvpName,
            map => $mapName,
            char => $char->{name}
        });
    }
}

sub handleMVPDeath {
    my ($mvpName) = @_;
    
    # Check if this MVP is in our hunt list
    my @huntList = split(/,\s*/, $config{mvpHunter_whitelist} || '');
    
    unless (grep { lc($mvpName) eq lc($_) } @huntList) {
        return;
    }
    
    # Check if this was our current target
    if ($currentTarget && lc($currentTarget->{name}) eq lc($mvpName)) {
        message "[mvpHunter] >>> $mvpName died! Returning to safe town...\n", "success";
        
        # Announce in party chat
        if ($config{mvpHunter_partyChat}) {
            Commands::run("p My target is dead! Returning home.");
        }
        
        # Clear current target
        $currentTarget = undef;
        
        # Clear lockMap
        Commands::run("conf lockMap none");
        
        # Return to safe town
        my $safeTown = $config{mvpHunter_safeTown} || 'morocc';
        Commands::run("move $safeTown");
        
        # Optional: Send bus message
        if ($config{mvpHunter_announce}) {
            $bus->send("mvpHunter", {
                action => "returning",
                mvp => $mvpName,
                char => $char->{name}
            });
        }
        
        # Process queue if there are any waiting
        processQueue();
    }
    # If it was in the queue, remove it
    else {
        @huntQueue = grep { lc($_->{name}) ne lc($mvpName) } @huntQueue;
        message "[mvpHunter] $mvpName died (was in queue). Removed from queue.\n", "info";
    }
}

sub processQueue {
    # Check if there are any MVPs waiting in queue
    if (@huntQueue) {
        my $next = shift @huntQueue;
        message "[mvpHunter] Processing queue: Going after $next->{name} at $next->{map}\n", "info";
        
        # Small delay before starting next hunt
        sleep 2;
        
        # Set as current target and go hunt
        $currentTarget = $next;
        
        # Announce in party chat
        if ($config{mvpHunter_partyChat}) {
            Commands::run("p Next target: $next->{name} at $next->{map}. Moving out!");
        }
        
        Commands::run("conf lockMap $next->{map}");
        
        # Optional: Send bus message
        if ($config{mvpHunter_announce}) {
            $bus->send("mvpHunter", {
                action => "hunting",
                mvp => $next->{name},
                map => $next->{map},
                char => $char->{name}
            });
        }
    } else {
        message "[mvpHunter] Queue empty. Idling in town.\n", "info";
    }
}

1;