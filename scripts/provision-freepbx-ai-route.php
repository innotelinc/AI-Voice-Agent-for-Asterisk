#!/usr/bin/env php
<?php

declare(strict_types=1);

function stderr(string $message): void {
    fwrite(STDERR, $message . PHP_EOL);
}

function usage(): void {
    $msg = <<<TXT
Usage: scripts/provision-freepbx-ai-route.php [options]

Idempotently create or update a FreePBX Custom Destination plus a Misc Application
that routes into an AI dialplan target such as from-ai-agent,s,1.

Options:
  --check                         Verify only; do not change FreePBX state
  --target TARGET                 Dialplan target (default: from-ai-agent,s,1)
  --route-extension EXT           Misc Application extension/feature code (default: 7000)
  --route-description TEXT        Misc Application description (default: AI Agent Entry)
  --custom-dest-description TEXT  Custom Destination description (default: AI Agent Entry)
  --notes TEXT                    Notes stored on the Custom Destination
  --help                          Show this help
TXT;
    echo $msg . PHP_EOL;
}

$opts = getopt('', [
    'check',
    'target:',
    'route-extension:',
    'route-description:',
    'custom-dest-description:',
    'notes:',
    'help',
]);

if (isset($opts['help'])) {
    usage();
    exit(0);
}

$check = isset($opts['check']);
$target = $opts['target'] ?? 'from-ai-agent,s,1';
$routeExtension = $opts['route-extension'] ?? '7000';
$routeDescription = $opts['route-description'] ?? 'AI Agent Entry';
$customDestDescription = $opts['custom-dest-description'] ?? $routeDescription;
$notes = $opts['notes'] ?? 'Provisioned by Asterisk AI Voice Agent installer';

if (!preg_match('/^[0-9*#A-D]+$/i', $routeExtension)) {
    stderr('Invalid --route-extension. Use digits or Asterisk feature-code characters only.');
    exit(2);
}
if (trim($target) === '' || substr_count($target, ',') < 2) {
    stderr('Invalid --target. Expected a dialplan destination like from-ai-agent,s,1.');
    exit(2);
}

$bootstrap = '/etc/freepbx.conf';
if (!is_file($bootstrap)) {
    stderr('FreePBX bootstrap not found at /etc/freepbx.conf');
    exit(2);
}

require_once $bootstrap;
require_once '/var/www/html/admin/modules/miscapps/functions.inc.php';

if (!class_exists('FreePBX')) {
    stderr('FreePBX bootstrap loaded but class FreePBX is unavailable.');
    exit(2);
}
if (!function_exists('miscapps_list') || !function_exists('miscapps_add') || !function_exists('miscapps_edit')) {
    stderr('Required FreePBX miscapps functions are unavailable. Is the module installed?');
    exit(2);
}
if (!method_exists(FreePBX::Customappsreg(), 'getAllCustomDests')) {
    stderr('Required FreePBX customappsreg module is unavailable. Is the module installed?');
    exit(2);
}

$customapps = FreePBX::Customappsreg();
$allDests = $customapps->getAllCustomDests();
$existingDest = null;
foreach ($allDests as $dest) {
    if (($dest['target'] ?? '') === $target || ($dest['description'] ?? '') === $customDestDescription) {
        $existingDest = $dest;
        break;
    }
}

$customDestAction = 'unchanged';
$destId = null;

if ($check) {
    if ($existingDest === null) {
        stderr('Custom Destination not found for requested target/description.');
        exit(1);
    }
    $destId = (int) $existingDest['destid'];
} else {
    $_REQUEST = [
        'display' => 'customdests',
        'view' => 'form',
        'destid' => $existingDest['destid'] ?? '',
        'target' => $target,
        'description' => $customDestDescription,
        'notes' => $notes,
        'destret' => 0,
        'action' => $existingDest ? 'edit' : 'add',
    ];
    $customapps->doConfigPageInit('customdests');
    $customDestAction = $existingDest ? 'updated' : 'created';

    $allDests = $customapps->getAllCustomDests();
    foreach ($allDests as $dest) {
        if (($dest['target'] ?? '') === $target && ($dest['description'] ?? '') === $customDestDescription) {
            $existingDest = $dest;
            break;
        }
    }
    if ($existingDest === null) {
        stderr('Custom Destination upsert did not produce a resolvable destination.');
        exit(1);
    }
    $destId = (int) $existingDest['destid'];
}

$miscDest = sprintf('customdests,dest-%d,1', $destId);
$miscApps = miscapps_list(true) ?? [];
$existingMisc = null;
foreach ($miscApps as $row) {
    if (($row['ext'] ?? '') === $routeExtension || ($row['description'] ?? '') === $routeDescription) {
        $existingMisc = $row;
        break;
    }
}

$miscAction = 'unchanged';
if ($check) {
    if ($existingMisc === null) {
        stderr('Misc Application not found for requested extension/description.');
        exit(1);
    }
    if (($existingMisc['dest'] ?? '') !== $miscDest) {
        stderr('Misc Application exists but points to a different destination.');
        exit(1);
    }
} else {
    if ($existingMisc === null) {
        miscapps_add($routeDescription, $routeExtension, $miscDest);
        $miscAction = 'created';
    } else {
        miscapps_edit((int)$existingMisc['miscapps_id'], $routeDescription, $routeExtension, $miscDest, true);
        $miscAction = 'updated';
    }
}

$result = [
    'target' => $target,
    'custom_destination' => [
        'description' => $customDestDescription,
        'destid' => $destId,
        'dialplan_target' => $miscDest,
        'action' => $customDestAction,
    ],
    'misc_application' => [
        'description' => $routeDescription,
        'extension' => $routeExtension,
        'dest' => $miscDest,
        'action' => $miscAction,
    ],
    'mode' => $check ? 'check' : 'apply',
];

echo json_encode($result, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . PHP_EOL;
