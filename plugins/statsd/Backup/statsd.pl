package statsd;

use strict;
use warnings;
use Plugins;
use Globals qw($char %config %monsters);
use Log qw(message error warning);
use Time::HiRes qw(time);
use Net::Dogstatsd;

# Plugin registration
Plugins::register('statsd', 'OpenKore StatsD KPH plugin', \&onUnload, \&onUnload);

# Configuration
my $statsd_host = $config{statsd_host} || '127.0.0.1';
my $statsd_port = $config{statsd_port} || '8125';
my $statsd_prefix = $config{statsd_prefix} || 'openkore_';

# StatsD client
my $statsd_client;

# Hook registration
my $hooks = Plugins::addHooks(
    ['item_gathered', \&onItemGathered],
	['target_died', \&onTargetDied, undef],
);

# Lazy initialization of StatsD client
sub get_statsd_client {
	return $statsd_client if $statsd_client;

	eval {
		$statsd_client = Net::Dogstatsd->new(
			host    => $statsd_host,
			port    => $statsd_port,
		);
		message "[statsd] StatsD client initialized (${statsd_host}:${statsd_port})\n", "system";
	};
	if ($@) {
		error "[statsd] Failed to initialize StatsD client: $@\n";
		return undef;
	}

	return $statsd_client;
}

sub onTargetDied {
    return unless $config{statsd};

    my (undef, $args) = @_;
    my $monster = $args->{monster};

    return unless $monster && get_statsd_client();

    my $char_name    = sanitize_tag($char->{name}      || 'unknown');
    my $monster_name = sanitize_tag($monster->{name}   || 'unknown');
    my @tags         = ("character:${char_name}", "monster:${monster_name}");
    
    eval {
        # Kills Per Hour Counter
        get_statsd_client()->increment(
            name => $statsd_prefix . "mon_kill",
            tags => \@tags,
        );
        message sprintf("[statsd] Kill metric sent: %s killed %s\n",
            $char_name, $monster_name), "system" if $config{statsd_debug};
    };
    if ($@) {
        error "[statsd] Failed to send kill metrics: $@\n";
    }
} 

sub onItemGathered {
    return unless $config{statsd};
    my (undef, $args) = @_;
    return unless get_statsd_client();
    
    my $char_name = sanitize_tag($char->{name} || 'unknown');
    my $item_name = 'unknown';
    my $amount = 1;
    
    if (ref($args) eq 'HASH') {
        if (exists $args->{item} && !ref($args->{item})) {
            $item_name = sanitize_tag($args->{item} || 'unknown');
            $amount = $args->{amount} || 1;
			message "[statsd debug] Got item from hash: $item_name (amount: $amount)\n", "system";
        }
    }

    return if $item_name eq 'unknown';

    my @tags = ("character:${char_name}", "item:${item_name}");
    eval {
        get_statsd_client()->increment(
            name  => $statsd_prefix . "item_looted",
            value => $amount,
            tags  => \@tags,
        );
    };

    if ($@) {
        error "[statsd] Failed to send loot metrics: $@\n";
    }
}


sub onUnload {
	Plugins::delHooks($hooks);
	undef $statsd_client;
	message "[statsd] Plugin unloaded\n", "system" if $config{statsd_debug};
}

# Metric tag can only contain letters, numbers, underscores, and hyphens
sub sanitize_tag {
	my ($name) = @_;
	$name =~ s/[^a-zA-Z0-9_-]/_/g;
	return lc($name);
}

1;