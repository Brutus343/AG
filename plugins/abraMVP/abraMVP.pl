package abraMVP;

use strict;
use Plugins;
use Log qw(message);
use AI;
use Globals;
use Network;
use Commands;

# Register the plugin so OpenKore recognizes it
Plugins::register("abraMVP", "Methodical MVP Spawner", \&on_unload);

my $hooks = Plugins::addHooks(
    ['AI_pre',           \&main_loop],       # Runs every frame to check state
    ['packet_skill_use', \&on_skill_use],    # Detects what Abracadabra actually did
    ['packet_privMsg',   \&on_privMsg]       # Handles bot-to-bot communication
);

# --- CONFIGURATION ---
my $target_monster_name = "Poring"; # The mob used as the 'base' for the MVP
my $slave_bot_name      = "SlaveBotName"; 
my $gemstone_name       = "Yellow Gemstone";
my $min_gemstones       = 50;

# --- STATES ---
# 0: Idle/Checking Supplies
# 1: Waiting for Mob Spawn (Slave to use Dead Branch)
# 2: Targeting & Casting Abracadabra
# 3: Class Change Detected (Pause & Prepare)
# 4: MVP Spawned (Broadcast & Stop)
my $currentState = 0;

sub on_unload {
    Plugins::delHooks($hooks);
}

# --- SECTION 1: THE MAIN LOGIC LOOP ---
# This runs constantly. It decides what the bot should be doing based on current conditions.
sub main_loop {
    return if !$net || $net->getState() != Network::IN_GAME;

    if ($currentState == 0) {
        # Check if we have enough gemstones to even start a run
        my $gem_count = inventory->count($gemstone_name);
        if ($gem_count < $min_gemstones) {
            message "[Abra] Low on Gemstones ($gem_count). Waiting for resupply...\n", "info";
            return;
        }
        message "[Abra] Supplies OK. Starting spawn sequence.\n", "success";
        $currentState = 1;

    } elsif ($currentState == 1) {
        # Signal the slave bot to use a Dead Branch
        # We use a PM so it doesn't clutter public chat
        Commands::run("pm \"$slave_bot_name\" spawn_now");
        message "[Abra] Signal sent to $slave_bot_name. Waiting for target...\n", "info";
        $currentState = 2;

    } elsif ($currentState == 2) {
        # Search for the target monster to start casting on
        my $target = find_target_by_name($target_monster_name);
        if ($target) {
            # Logic: If we see the target, cast Abracadabra
            # 'lvl 10' is usually required for the Class Change effect
            Commands::run("is Abracadabra $target->{ID} 10");
        }
    }
    
    # Check for MVPs every loop regardless of state
    check_for_mvps();
}

# --- SECTION 2: SKILL RECOGNITION ---
# This watches the data packets coming from the server.
# When Abracadabra is used, the server tells us which 'sub-skill' triggered.
sub on_skill_use {
    my ($self, $args) = @_;
    
    # Skill ID 395 is the internal ID for 'Class Change' (Hocus Pocus effect)
    # Check your server's skill_db.yml/txt if this differs.
    if ($args->{skillID} == 395) {
        message "[Abra] !!! CLASS CHANGE DETECTED !!! pausing spam...\n", "warning";
        $currentState = 3;
        AI::clear; # Stops the bot from immediately casting again and killing the MVP
    }
}

# --- SECTION 3: MVP DETECTION & BROADCAST ---
# This scans the surrounding area for any monster marked as an MVP in the bot's tables.
sub check_for_mvps {
    foreach my $monster (@{$monstersList->getItems()}) {
        if ($monster->isMVP && $currentState != 4) {
            message "[Abra] MVP DETECTED: $monster->{name}!\n", "success";
            Commands::run("p MVP $monster->{name} HAS ARRIVED! KILL IT NOW!");
            $currentState = 4; # Lock state so we don't spam the party
            AI::clear;
        }
    }
}

# --- SECTION 4: HELPER FUNCTIONS ---
sub find_target_by_name {
    my $name = shift;
    foreach my $mob (@{$monstersList->getItems()}) {
        return $mob if ($mob->{name} =~ /$name/i && !$mob->isDead);
    }
    return undef;
}

# This handles receiving confirmation from the slave bot if needed
sub on_privMsg {
    my ($self, $args) = @_;
    if ($args->{msg} eq "spawn_done") {
        message "[Abra] Slave confirms Dead Branch used.\n";
    }
}

1;