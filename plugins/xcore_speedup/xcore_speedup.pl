package xcore_speedup;

use strict;
use Plugins;
use Globals;
use Log qw(message debug);
use AI;

Plugins::register("xcore_speedup", "XCore2 Brute Sync", \&on_unload);

my $hooks = Plugins::addHooks(
    ['main_loop_pre', \&force_injection],
    ['packet_send',    \&muffle_outbound],
);

my $injected = 0;

sub force_injection {
    # If we are connected but haven't injected yet
    if ($net && $net->{serverType} && !$injected) {
        my $recv = $net->{recvPacketParser};
        return if !$recv;

        # FORCE PACKET DEFINITIONS (The missing XCore pieces)
        $recv->{packet_lut}{'0AC4'} = 'account_server_info';
        $recv->{packet_list}{'0AC4'} = [undef, 'v', [qw(len)]]; 
        
        # Ensure the bot doesn't crash on standard sync
        $recv->{packet_lut}{'0072'} = 'received_sync' if !$recv->{packet_lut}{'0072'};

        message "[XCore] SUCCESS: Handlers forced into active connection.\n", "success";
        $injected = 1;
    }
    
    # Reset injection flag if we disconnect
    if (!$net || !$net->{serverType}) {
        $injected = 0;
    }
}

sub muffle_outbound {
    my (undef, $args) = @_;
    my $switch = unpack('v', $args->{data});
    if ($switch == 0x0369 || $switch == 0x083C || $switch == 0x07E4) {
        $args->{return} = 1; 
        message "[XCore] Muffled anti-cheat packet: " . sprintf("0x%04X", $switch) . "\n", "info";
    }
}

sub on_unload {
    Plugins::delHooks($hooks);
}

1;