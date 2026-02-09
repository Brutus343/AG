package greatNatureProcessor;

use strict;
use Plugins;
use Settings;
use Log qw(message warning error);
use Globals qw($char);
use Commands;
use Utils;

Plugins::register('greatNatureProcessor', 'Auto-process Great Nature when storage reaches threshold', \&unload);

my $commands = Commands::register(
    ['gncheck', 'Check Great Nature and switch if needed', \&commandCheck],
    ['gnstatus', 'Show current status', \&commandStatus]
);

my $processingMode = 0;

message "[greatNatureProcessor] Plugin loaded!\n", "success";
message "[greatNatureProcessor] Commands: 'gncheck' to check/switch, 'gnstatus' for info\n", "success";

sub unload {
    Commands::unregister($commands);
    message "[greatNatureProcessor] Plugin unloaded.\n";
}

sub commandStatus {
    message "=== Great Nature Status ===\n", "info";
    message "Char exists: " . (defined $char ? "YES" : "NO") . "\n", "info";
    
    if ($char) {
        message "Char ID: " . ($char->{charID} || "0") . "\n", "info";
        message "Char Name: " . ($char->{name} || "unknown") . "\n", "info";
    }
    
    # Check different storage access methods
    message "\n--- Storage Debug ---\n", "info";
    message "Storage via \@::storage: " . scalar(@::storage) . " items\n", "info";
    message "Storage via \%::storage hash exists: " . (%::storage ? "YES" : "NO") . "\n", "info";
    
    if (%::storage) {
        message "Storage keys: " . join(", ", keys %::storage) . "\n", "info";
        if ($::storage{items}) {
            message "storage{items} exists, count: " . scalar(@{$::storage{items}}) . "\n", "info";
        }
    }
    
    # Try char->storage
    if ($char && $char->{storage}) {
        message "Char has storage object!\n", "info";
    }
    
    my $count = getStorageAmount(7939);
    message "Great Nature count: $count\n", "info";
    message "Processing mode: " . ($processingMode ? "YES (on merchant)" : "NO (farming)") . "\n", "info";
    message "==========================\n", "info";
}

sub commandCheck {
    message "[greatNatureProcessor] Running check...\n", "info";
    
    unless ($char) {
        error "[greatNatureProcessor] No character loaded!\n";
        return;
    }
    
    my $charIndex = $char->{charID} || 0;
    my $greatNatureCount = getStorageAmount(7939);
    
    message "[greatNatureProcessor] Char $charIndex has $greatNatureCount Great Nature in storage\n", "info";
    
    # Char 0: Farmer - Check if we need to switch to merchant
    if ($charIndex == 0 && !$processingMode) {
        if ($greatNatureCount >= 25000) {
            message "[greatNatureProcessor] >= 25000! Switching to merchant...\n", "success";
            $processingMode = 1;
            
            Commands::run("conf oreDowngrade 1");
            sleep(1);
            Commands::run("relog 1");
        } else {
            message "[greatNatureProcessor] Only $greatNatureCount/25000 - keep farming!\n", "info";
        }
    }
    
    # Char 1: Merchant - Check if storage is empty
    elsif ($charIndex == 1 && $processingMode) {
        if ($greatNatureCount == 0) {
            message "[greatNatureProcessor] Storage empty! Switching back to farmer...\n", "success";
            $processingMode = 0;
            
            Commands::run("conf oreDowngrade 0");
            sleep(1);
            Commands::run("relog 0");
        } else {
            message "[greatNatureProcessor] Still processing... $greatNatureCount remaining\n", "info";
        }
    }
    
    # Edge cases
    elsif ($charIndex == 1 && !$processingMode) {
        warning "[greatNatureProcessor] On merchant but not in processing mode! Run 'gncheck' on char 0 first.\n";
    }
}

sub getStorageAmount {
    my ($itemID) = @_;
    my $count = 0;
    
    # Try multiple methods to access storage
    
    # Method 1: @::storage
    foreach my $item (@::storage) {
        next unless $item;
        if ($item->{nameID} == $itemID) {
            $count += $item->{amount};
        }
    }
    
    # Method 2: %::storage{items}
    if (!$count && %::storage && $::storage{items}) {
        foreach my $item (@{$::storage{items}}) {
            next unless $item;
            if ($item->{nameID} == $itemID) {
                $count += $item->{amount};
            }
        }
    }
    
    return $count;
}

1;