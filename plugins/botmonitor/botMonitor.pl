############################
# botMonitor Plugin for OpenKore
# Tracks performance metrics and generates diagnostic reports
# Created 2025
############################

package botMonitor;

use strict;
use warnings;
use Time::HiRes qw(time);
use POSIX qw(strftime);

use Globals;
use Log qw(message warning error);
use Misc;
use Utils;
use Commands;
use AI;

Plugins::register('botMonitor', 'Performance monitoring and diagnostics', \&onUnload);

my $hooks = Plugins::addHooks(
	['start3', \&onStart, undef],
	['packet/skills_list', \&onSkillsList, undef],
	['packet/actor_display', \&onActorDisplay, undef],
	['packet/skill_use', \&onSkillUse, undef],
	['packet_pre/attack_range', \&onAttackRange, undef],
	['AI_pre', \&onAIPre, undef],
	['target_died', \&onTargetDied, undef],
	['base_level', \&onBaseLevel, undef],
	['expGain', \&onExpGain, undef],
	['packet/teleport', \&onTeleport, undef],
	['log', \&onLog, undef],
	['packet/map_changed', \&onMapChange, undef],
);

message "botMonitor plugin loaded successfully\n", "success";

# Performance tracking variables
my %stats = (
	session_start => time,
	skills_used => {},
	skills_per_minute => {},
	last_skill_time => {},
	skill_delays => {},
	ai_cycle_times => [],
	last_ai_time => time,
	attacks => 0,
	kills => 0,
	deaths => 0,
	exp_gained => 0,
	base_exp_per_hour => 0,
	monsters_seen => {},
	current_target => undef,
	target_start_time => undef,
	time_to_kill => [],
	idle_time => 0,
	last_action_time => time,
	dps_samples => [],
	total_damage => 0,
	damage_timestamps => [],
	last_damage_time => time,
	teleports => 0,
	movement_time => 0,
	combat_time => 0,
	map_times => {},
	current_map => undef,
	map_enter_time => time,
	idle_start_time => undef,
	aiclear_count => 0,
	last_pos => undef,
	last_pos_time => time,
);

# Skill ID to name mapping for skills not in skills_lut
my %custom_skill_names = (
	266 => 'Investigate',
	# Add more custom mappings here if needed
);

my $last_report_time = time;
my $report_interval = 300; # Generate report every 5 minutes
my $last_idle_debug_time = 0; # Throttle idle debug messages

# Commands
my $chooks = Commands::register(
	['botmon', 'Display bot monitoring stats', \&commandBotMon],
	['botreport', 'Generate detailed performance report', \&commandBotReport],
	['botreset', 'Reset monitoring statistics', \&commandBotReset]
);

sub onUnload {
	Commands::unregister($chooks);
	Plugins::delHooks($hooks);
}

sub onStart {
	message "botMonitor: Session started, tracking performance...\n", "success";
	$stats{session_start} = time;
	
	# Initialize current map
	if ($field) {
		$stats{current_map} = $field->baseName;
		$stats{map_enter_time} = time;
	}
}

sub onSkillsList {
	# Could track available skills here if needed
}

sub onActorDisplay {
	my (undef, $args) = @_;
	
	# Track monsters entering range
	if (defined $args->{type} && $args->{type} == 1005) { # Monster
		my $ID = $args->{ID};
		$stats{monsters_seen}{$ID} = time unless exists $stats{monsters_seen}{$ID};
	}
}

sub onMapChange {
	my (undef, $args) = @_;
	
	return unless $field;
	
	my $current_time = time;
	my $old_map = $stats{current_map};
	my $new_map = $field->baseName;
	
	# Calculate time spent on old map
	if (defined $old_map) {
		my $time_spent = $current_time - $stats{map_enter_time};
		$stats{map_times}{$old_map} = 0 unless exists $stats{map_times}{$old_map};
		$stats{map_times}{$old_map} += $time_spent;
	}
	
	# Update to new map
	$stats{current_map} = $new_map;
	$stats{map_enter_time} = $current_time;
}

sub onSkillUse {
	my (undef, $args) = @_;
	
	return unless $args->{sourceID} eq $accountID;
	
	my $skillID = $args->{skillID};
	my $skillName;
	
	# Try custom mapping first, then skills_lut, then fall back to Unknown
	if (exists $custom_skill_names{$skillID}) {
		$skillName = $custom_skill_names{$skillID};
	} elsif (exists $char->{skills_lut}{$skillID}) {
		$skillName = $char->{skills_lut}{$skillID};
	} else {
		$skillName = "Unknown($skillID)";
	}
	
	my $current_time = time;
	
	# Track skill usage
	$stats{skills_used}{$skillName}++;
	
	# Track delay between skill uses
	if (exists $stats{last_skill_time}{$skillName}) {
		my $delay = $current_time - $stats{last_skill_time}{$skillName};
		push @{$stats{skill_delays}{$skillName}}, $delay;
		
		# Keep only last 20 delays for averaging
		if (scalar @{$stats{skill_delays}{$skillName}} > 20) {
			shift @{$stats{skill_delays}{$skillName}};
		}
	}
	
	$stats{last_skill_time}{$skillName} = $current_time;
	$stats{last_action_time} = $current_time;
}

sub onAttackRange {
	$stats{attacks}++;
	$stats{last_action_time} = time;
}

sub onAIPre {
	my $current_time = time;
	my $cycle_time = $current_time - $stats{last_ai_time};
	
	push @{$stats{ai_cycle_times}}, $cycle_time;
	
	# Keep only last 100 cycles
	if (scalar @{$stats{ai_cycle_times}} > 100) {
		shift @{$stats{ai_cycle_times}};
	}
	
	$stats{last_ai_time} = $current_time;
	
	# Track map changes via field check (more reliable than packet)
	if ($field && $field->baseName) {
		my $current_map_name = $field->baseName;
		
		# Initialize if not set
		if (!defined $stats{current_map}) {
			$stats{current_map} = $current_map_name;
			$stats{map_enter_time} = $current_time;
			if ($config{bm_debug}) {
				message "botMonitor: Initialized map tracking on $current_map_name\n";
			}
		}
		# Detect map change
		elsif ($stats{current_map} ne $current_map_name) {
			# Calculate time spent on old map
			my $time_spent = $current_time - $stats{map_enter_time};
			$stats{map_times}{$stats{current_map}} = 0 unless exists $stats{map_times}{$stats{current_map}};
			$stats{map_times}{$stats{current_map}} += $time_spent;
			
			if ($config{bm_debug}) {
				message sprintf("botMonitor: Map change %s -> %s (spent %s)\n", 
					$stats{current_map}, $current_map_name, formatDuration($time_spent));
			}
			
			# Update to new map
			$stats{current_map} = $current_map_name;
			$stats{map_enter_time} = $current_time;
		}
	}
	
	# Track actual position for stuck detection
	if (!exists $stats{last_pos} || !defined $stats{last_pos}) {
		if ($char && $char->{pos_to} && defined $char->{pos_to}{x} && defined $char->{pos_to}{y}) {
			$stats{last_pos} = {x => $char->{pos_to}{x}, y => $char->{pos_to}{y}};
			$stats{last_pos_time} = $current_time;
		}
	}
	
	# Calculate idle time (truly doing nothing - not moving, not in combat)
	# Only count as idle if: no skills for 5+ seconds AND not ACTUALLY moving AND no target
	my $action_gap = $current_time - $stats{last_action_time};
	
	# Check if position actually changed (detect stuck routing)
	my $pos_changed = 0;
	if (defined $stats{last_pos} && $char && $char->{pos_to} && 
	    defined $char->{pos_to}{x} && defined $char->{pos_to}{y} &&
	    defined $stats{last_pos}{x} && defined $stats{last_pos}{y}) {
		if ($stats{last_pos}{x} != $char->{pos_to}{x} || $stats{last_pos}{y} != $char->{pos_to}{y}) {
			$pos_changed = 1;
			$stats{last_pos} = {x => $char->{pos_to}{x}, y => $char->{pos_to}{y}};
			$stats{last_pos_time} = $current_time;
		}
	}
	
	# Time since last actual position change
	my $stuck_time = $current_time - $stats{last_pos_time};
	
	if ($action_gap > 5) {
		# Check AI state
		my $ai_action = AI::action;
		my $is_routing = (defined $ai_action && $ai_action eq 'route');
		my $has_target = ($char->{target} || AI::findAction('attack'));
		
		# Bot is stuck if: routing for 10+ seconds but position hasn't changed
		my $is_stuck = ($is_routing && $stuck_time > 10);
		
		# Throttled debug (once per second)
		if ($config{bm_debug} && ($current_time - $last_idle_debug_time > 1.0)) {
			message sprintf("[botMonitor] action_gap: %.1fs, ai: %s, stuck_time: %.1fs, has_target: %s, stuck: %s\n",
				$action_gap,
				(defined $ai_action ? $ai_action : "none"),
				$stuck_time,
				($has_target ? "YES" : "NO"),
				($is_stuck ? "YES" : "NO"));
			$last_idle_debug_time = $current_time;
		}
		
		# Count as idle if: no target AND (not moving OR stuck in route)
		if (!$has_target && (!$is_routing || $is_stuck)) {
			$stats{idle_time} += $cycle_time;
			
			# Track continuous idle time for auto-aiclear
			if (!defined $stats{idle_start_time}) {
				$stats{idle_start_time} = $current_time;
				message "[botMonitor] Started tracking idle time\n" if $config{bm_debug};
			}
			
			# Check if idle timeout threshold reached
			my $idle_threshold = $config{bm_aiClearTimeout};
			$idle_threshold = 60 unless defined $idle_threshold; # Default to 60 if not set
			$idle_threshold = cleanConfigValue($idle_threshold, 60, 'int');
			
			my $idle_duration = $current_time - $stats{idle_start_time};
			
			# Show idle duration every 5 seconds when debugging
			if ($config{bm_debug} && ($current_time - $last_idle_debug_time > 5.0)) {
				message sprintf("[botMonitor] Idle duration: %.1f / %d seconds (threshold from config: %s)\n", 
					$idle_duration, $idle_threshold, 
					(defined $config{bm_aiClearTimeout} ? $config{bm_aiClearTimeout} : "not set"));
				$last_idle_debug_time = $current_time;
			}
			
			if ($idle_duration >= $idle_threshold) {
				message sprintf("[botMonitor] Bot idle for %.1f seconds, executing AI clear!\n", $idle_duration), "warning";
				
				# Clear AI queue
				AI::clear();
				
				# Also try calling aiclear command if it exists
				Commands::run("aiclear");
				
				$stats{aiclear_count}++;
				$stats{idle_start_time} = undef; # Reset idle timer
			}
		} else {
			# No longer idle (has target or actually moving)
			if (defined $stats{idle_start_time}) {
				message "[botMonitor] No longer idle (target found or moving), resetting timer\n" if $config{bm_debug};
			}
			$stats{idle_start_time} = undef;
		}
	} else {
		# Skill/action detected - but DON'T reset idle timer
		# Idle timer only resets on actual movement or targeting
	}
	
	# Auto-report every interval
	if ($config{bm_autoReport} && ($current_time - $last_report_time > $report_interval)) {
		generateReport();
		$last_report_time = $current_time;
	}
}

sub onTargetDied {
	my (undef, $args) = @_;
	
	$stats{kills}++;
	
	# Track time to kill if we were tracking this target
	if ($stats{current_target} && $stats{target_start_time}) {
		my $ttk = time - $stats{target_start_time};
		push @{$stats{time_to_kill}}, $ttk;
		
		# Keep only last 20
		if (scalar @{$stats{time_to_kill}} > 20) {
			shift @{$stats{time_to_kill}};
		}
	}
	
	$stats{current_target} = undef;
	$stats{target_start_time} = undef;
}

sub onBaseLevel {
	# Could track level ups
}

sub onExpGain {
	my (undef, $args) = @_;
	$stats{exp_gained} += $args->{amount} if $args->{amount};
}

sub onTeleport {
	$stats{teleports}++;
	$stats{last_action_time} = time; # Teleporting is an action
}

sub onLog {
	my (undef, $args) = @_;
	
	# Parse damage from messages like: "You use Investigate (Lv: 5) on Monster Sleeper (2) (Dmg: 9391) (Delay: 256ms)"
	if ($args->{message} =~ /\(Dmg:\s*(\d+)\)/) {
		my $damage = $1;
		my $current_time = time;
		
		$stats{total_damage} += $damage;
		push @{$stats{damage_timestamps}}, {time => $current_time, damage => $damage};
		
		# Keep only last 100 damage instances for DPS calculation
		if (scalar @{$stats{damage_timestamps}} > 100) {
			shift @{$stats{damage_timestamps}};
		}
		
		$stats{last_damage_time} = $current_time;
	}
	
	# Reset idle timer on Healer plugin messages
	if ($args->{message} =~ /^Healer: Please wait/) {
		if (defined $stats{idle_start_time}) {
			message "[botMonitor] Healer active, resetting idle timer\n" if $config{bm_debug};
			$stats{idle_start_time} = undef;
		}
	}
}

sub commandBotMon {
	my (undef, $args) = @_;
	
	my $session_time = time - $stats{session_start};
	my $hours = $session_time / 3600;
	
	message "========== Bot Monitor - Quick Stats ==========\n", "list";
	message sprintf("Session Time: %s\n", formatDuration($session_time)), "list";
	message sprintf("Kills: %d (%.1f/hour)\n", $stats{kills}, $stats{kills} / $hours), "list";
	message sprintf("Attacks: %d\n", $stats{attacks}), "list";
	
	if (keys %{$stats{skills_used}}) {
		message "\nSkills Used:\n", "list";
		foreach my $skill (sort { $stats{skills_used}{$b} <=> $stats{skills_used}{$a} } keys %{$stats{skills_used}}) {
			my $count = $stats{skills_used}{$skill};
			my $per_min = ($count / $session_time) * 60;
			message sprintf("  %s: %d times (%.1f/min)\n", $skill, $count, $per_min), "list";
		}
	}
	
	if (@{$stats{ai_cycle_times}}) {
		my $avg_cycle = average(@{$stats{ai_cycle_times}});
		message sprintf("\nAvg AI Cycle: %.3f seconds\n", $avg_cycle), "list";
	}
	
	message "===============================================\n", "list";
	message "Use 'botreport' for detailed analysis\n", "list";
}

sub commandBotReport {
	generateReport();
}

sub commandBotReset {
	message "Resetting bot monitor statistics...\n", "success";
	
	%stats = (
		session_start => time,
		skills_used => {},
		skills_per_minute => {},
		last_skill_time => {},
		skill_delays => {},
		ai_cycle_times => [],
		last_ai_time => time,
		attacks => 0,
		kills => 0,
		deaths => 0,
		exp_gained => 0,
		base_exp_per_hour => 0,
		monsters_seen => {},
		current_target => undef,
		target_start_time => undef,
		time_to_kill => [],
		idle_time => 0,
		last_action_time => time,
		dps_samples => [],
		total_damage => 0,
		damage_timestamps => [],
		last_damage_time => time,
		teleports => 0,
		movement_time => 0,
		combat_time => 0,
		map_times => {},
		current_map => ($field ? $field->baseName : undef),
		map_enter_time => time,
		idle_start_time => undef,
		aiclear_count => 0,
		last_pos => undef,
		last_pos_time => time,
	);
	
	$last_report_time = time;
	message "Statistics reset successfully\n", "success";
}

sub generateReport {
	my $session_time = time - $stats{session_start};
	my $hours = $session_time / 3600;
	my $minutes = $session_time / 60;
	
	my $report = "\n";
	$report .= "=" x 70 . "\n";
	$report .= "BOT PERFORMANCE REPORT - " . strftime("%Y-%m-%d %H:%M:%S", localtime()) . "\n";
	$report .= "=" x 70 . "\n\n";
	
	# Session Overview
	$report .= "SESSION OVERVIEW:\n";
	$report .= "-" x 70 . "\n";
	$report .= sprintf("Duration: %s\n", formatDuration($session_time));
	$report .= sprintf("Character: %s (Level %d)\n", $char->{name}, $char->{lv}) if $char;
	$report .= sprintf("Map: %s\n", $field->baseName) if $field;
	$report .= "\n";
	
	# Combat Stats
	$report .= "COMBAT PERFORMANCE:\n";
	$report .= "-" x 70 . "\n";
	$report .= sprintf("Kills: %d (%.1f/hour)\n", $stats{kills}, $stats{kills} / $hours);
	
	# Calculate DPS
	if ($stats{total_damage} > 0 && $session_time > 0) {
		my $dps = $stats{total_damage} / $session_time;
		$report .= sprintf("Damage Per Second: %.1f (Total: %s damage)\n", $dps, commify($stats{total_damage}));
		
		# Calculate recent DPS (last 60 seconds)
		if (@{$stats{damage_timestamps}} > 0) {
			my $recent_cutoff = time - 60;
			my $recent_damage = 0;
			my $recent_count = 0;
			foreach my $dmg (@{$stats{damage_timestamps}}) {
				if ($dmg->{time} >= $recent_cutoff) {
					$recent_damage += $dmg->{damage};
					$recent_count++;
				}
			}
			if ($recent_count > 0) {
				my $recent_time = time - $stats{damage_timestamps}[0]{time};
				$recent_time = 1 if $recent_time < 1; # Avoid division by zero
				my $recent_dps = $recent_damage / $recent_time;
				$report .= sprintf("Recent DPS (last %d hits): %.1f\n", $recent_count, $recent_dps);
			}
		}
	}
	
	$report .= sprintf("Deaths: %d\n", $stats{deaths});
	$report .= sprintf("Teleports: %d (%.1f/hour)\n", $stats{teleports}, $stats{teleports} / $hours) if $stats{teleports} > 0;
	
	if ($stats{aiclear_count} > 0) {
		$report .= sprintf("AI Clears (auto-unstuck): %d\n", $stats{aiclear_count});
	}
	
	if (@{$stats{time_to_kill}} > 0) {
		my $avg_ttk = average(@{$stats{time_to_kill}});
		$report .= sprintf("Avg Time to Kill: %.1f seconds\n", $avg_ttk);
	}
	$report .= "\n";
	
	# Map Time Breakdown
	if ($config{bm_debug}) {
		$report .= "DEBUG INFO:\n";
		$report .= "  current_map = " . (defined $stats{current_map} ? $stats{current_map} : "UNDEF") . "\n";
		$report .= "  map_enter_time = " . (defined $stats{map_enter_time} ? $stats{map_enter_time} : "UNDEF") . "\n";
		$report .= "  map_times keys = " . (keys %{$stats{map_times}} ? join(", ", keys %{$stats{map_times}}) : "EMPTY") . "\n";
		$report .= "  field defined = " . (defined $field ? "YES" : "NO") . "\n";
		if (defined $field) {
			$report .= "  field->baseName = " . (defined $field->baseName ? $field->baseName : "UNDEF") . "\n";
		}
		$report .= "\n";
	}
	
	my %display_map_times = %{$stats{map_times}}; # Copy for display
	
	# Add current map time
	if (defined $stats{current_map} && defined $stats{map_enter_time}) {
		my $current_map_time = time - $stats{map_enter_time};
		$display_map_times{$stats{current_map}} = 0 unless exists $display_map_times{$stats{current_map}};
		$display_map_times{$stats{current_map}} += $current_map_time;
		
		if ($config{bm_debug}) {
			$report .= "  Added current map time: $current_map_time seconds\n";
			$report .= "  display_map_times{$stats{current_map}} = " . $display_map_times{$stats{current_map}} . "\n";
		}
	} elsif ($config{bm_debug}) {
		$report .= "  FAILED to add current map time\n";
		$report .= "  Reason: current_map=" . (defined $stats{current_map} ? "defined" : "UNDEF");
		$report .= ", map_enter_time=" . (defined $stats{map_enter_time} ? "defined" : "UNDEF") . "\n";
	}
	
	if ($config{bm_debug}) {
		$report .= "  display_map_times keys after = " . (keys %display_map_times ? join(", ", keys %display_map_times) : "EMPTY") . "\n";
		$report .= "\n";
	}
	
	if (keys %display_map_times) {
		$report .= "MAP TIME BREAKDOWN:\n";
		$report .= "-" x 70 . "\n";
		
		# Sort by time spent (most to least)
		my @sorted_maps = sort { $display_map_times{$b} <=> $display_map_times{$a} } keys %display_map_times;
		
		foreach my $map (@sorted_maps) {
			my $map_time = $display_map_times{$map};
			my $percentage = ($map_time / $session_time) * 100;
			$report .= sprintf("%-30s %12s (%5.1f%%)\n", 
				$map, 
				formatDuration($map_time), 
				$percentage);
		}
		
		$report .= "\n";
	} elsif ($config{bm_debug}) {
		$report .= "MAP TIME BREAKDOWN: No data collected\n\n";
	}
	
	# Skill Usage Analysis
	if (keys %{$stats{skills_used}}) {
		$report .= "SKILL USAGE ANALYSIS:\n";
		$report .= "-" x 70 . "\n";
		$report .= sprintf("%-30s %10s %12s %12s\n", "Skill", "Count", "Per Minute", "Avg Delay");
		$report .= "-" x 70 . "\n";
		
		foreach my $skill (sort { $stats{skills_used}{$b} <=> $stats{skills_used}{$a} } keys %{$stats{skills_used}}) {
			my $count = $stats{skills_used}{$skill};
			my $per_min = ($count / $minutes);
			
			my $avg_delay = "N/A";
			if (exists $stats{skill_delays}{$skill} && @{$stats{skill_delays}{$skill}} > 0) {
				$avg_delay = sprintf("%.2fs", average(@{$stats{skill_delays}{$skill}}));
			}
			
			$report .= sprintf("%-30s %10d %12.1f %12s\n", $skill, $count, $per_min, $avg_delay);
		}
		$report .= "\n";
	}
	
	# AI Performance
	if (@{$stats{ai_cycle_times}} > 0) {
		my $avg_cycle = average(@{$stats{ai_cycle_times}});
		my $min_cycle = min(@{$stats{ai_cycle_times}});
		my $max_cycle = max(@{$stats{ai_cycle_times}});
		
		$report .= "AI PERFORMANCE:\n";
		$report .= "-" x 70 . "\n";
		$report .= sprintf("Avg AI Cycle Time: %.3f seconds\n", $avg_cycle);
		$report .= sprintf("Min/Max Cycle: %.3f / %.3f seconds\n", $min_cycle, $max_cycle);
		$report .= sprintf("Idle Time: %s (%.1f%% of session)\n", 
			formatDuration($stats{idle_time}), 
			($stats{idle_time} / $session_time) * 100);
		$report .= "\n";
	}
	
	$report .= "=" x 70 . "\n";
	$report .= "To share this report for analysis, copy everything above\n";
	$report .= "Config: bm_autoReport 1  (auto-generate reports every 5 min)\n";
	$report .= "=" x 70 . "\n\n";
	
	message $report, "list";
	
	# Also save to file
	if ($config{bm_saveReports}) {
		my $filename = "botmon_" . strftime("%Y%m%d_%H%M%S", localtime()) . ".txt";
		if (open my $fh, '>', $filename) {
			print $fh $report;
			close $fh;
			message "Report saved to: $filename\n", "success";
		}
	}
}

# Helper functions
sub average {
	return 0 unless @_;
	my $sum = 0;
	$sum += $_ for @_;
	return $sum / scalar(@_);
}

sub min {
	return undef unless @_;
	my $min = shift;
	$min = $_ < $min ? $_ : $min for @_;
	return $min;
}

sub max {
	return undef unless @_;
	my $max = shift;
	$max = $_ > $max ? $_ : $max for @_;
	return $max;
}

sub formatDuration {
	my $seconds = shift;
	my $hours = int($seconds / 3600);
	my $mins = int(($seconds % 3600) / 60);
	my $secs = int($seconds % 60);
	
	return sprintf("%02d:%02d:%02d", $hours, $mins, $secs);
}

sub commify {
	my $num = shift;
	$num = int($num);
	1 while $num =~ s/^(-?\d+)(\d{3})/$1,$2/;
	return $num;
}

sub cleanConfigValue {
	my ($value, $default, $type) = @_;
	
	return $default unless defined $value;
	
	# Strip comments (everything after #)
	$value =~ s/#.*$//;
	
	# Trim whitespace
	$value =~ s/^\s+|\s+$//g;
	
	# Return default if empty after cleaning
	return $default if $value eq '';
	
	# Validate type
	if ($type eq 'int') {
		return $value =~ /^-?\d+$/ ? int($value) : $default;
	} elsif ($type eq 'float') {
		return $value =~ /^-?\d+\.?\d*$/ ? $value : $default;
	}
	
	return $value;
}

return 1;