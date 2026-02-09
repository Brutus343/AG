package aiClearHelper;
use strict;
use Plugins;
use AI;

Plugins::register('aiClearHelper', 'Allows ai clear from macros');

Commands::register(
    ['aiclear', 'Clear AI queue', \&cmdClear]
);

sub cmdClear {
    AI::clear();
    Log::message("AI queue cleared!\n");
}

1;