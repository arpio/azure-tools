<?php
// ==========================================================
// Arpio LAMP Stack Demo — Hello World (v3)
//
// NOW WITH: userData reading from IMDS!
// Key Vault + Storage Account + Blob-hosted Arpio logo!
// After Arpio recovery to eastus2, this page
// dynamically updates to show the new region, subscription,
// and all resource endpoints including userData translation.
// ==========================================================

// --- Read userData from IMDS (≈ AWS EC2 user data) ---
$userData = [];
$ch = curl_init();
curl_setopt($ch, CURLOPT_URL, 'http://169.254.169.254/metadata/instance/compute/userData?api-version=2021-01-01&format=text');
curl_setopt($ch, CURLOPT_HTTPHEADER, ['Metadata: true']);
curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
curl_setopt($ch, CURLOPT_CONNECTTIMEOUT, 2);
curl_setopt($ch, CURLOPT_TIMEOUT, 5);
$userDataB64 = curl_exec($ch);
curl_close($ch);

if ($userDataB64) {
    $userDataJson = base64_decode($userDataB64);
    $userData = json_decode($userDataJson, true) ?: [];
}

// Extract values from userData (Arpio-translated during recovery)
$storageBlobEndpoint = $userData['storageBlobEndpoint'] ?? 'N/A';
$kvNameFromUserData = $userData['keyVaultName'] ?? 'N/A';
$dbServerFromUserData = $userData['sqlServerFqdn'] ?? 'N/A';
$dbNameFromUserData = $userData['sqlDatabaseName'] ?? 'N/A';

// Use blob endpoint directly from userData (Arpio translates full URLs)
$storageUrl = $storageBlobEndpoint;

// --- Azure Instance Metadata Service (IMDS) ---
// Same IP as AWS EC2 metadata (169.254.169.254) but needs a header.
$metadata = [];
$ch = curl_init();
curl_setopt($ch, CURLOPT_URL, 'http://169.254.169.254/metadata/instance?api-version=2021-02-01');
curl_setopt($ch, CURLOPT_HTTPHEADER, ['Metadata: true']);
curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
curl_setopt($ch, CURLOPT_CONNECTTIMEOUT, 2);
curl_setopt($ch, CURLOPT_TIMEOUT, 5);
$response = curl_exec($ch);
curl_close($ch);
if ($response) {
    $metadata = json_decode($response, true);
}

$region     = $metadata['compute']['location'] ?? 'Unknown';
$vmName     = $metadata['compute']['name'] ?? 'Unknown';
$vmSize     = $metadata['compute']['vmSize'] ?? 'Unknown';
$subId      = $metadata['compute']['subscriptionId'] ?? 'Unknown';
$rgName     = $metadata['compute']['resourceGroupName'] ?? 'Unknown';
$privateIp  = $metadata['network']['interface'][0]['ipv4']['ipAddress'][0]['privateIpAddress'] ?? 'Unknown';
$publicIp   = $metadata['network']['interface'][0]['ipv4']['ipAddress'][0]['publicIpAddress'] ?? 'Unknown';
$osType     = $metadata['compute']['osType'] ?? 'Unknown';
$imageSku   = $metadata['compute']['storageProfile']['imageReference']['sku'] ?? 'Unknown';

// --- Read config from files (fallback only - deploy script writes these) ---
function readConf($f, $d = 'N/A') {
    $p = "/etc/arpio-lamp/{$f}";
    $val = file_exists($p) ? trim(file_get_contents($p)) : '';
    // Return default if file doesn't exist, is empty, or contains PLACEHOLDER
    return ($val && $val !== 'PLACEHOLDER') ? $val : $d;
}

// Use userData for SQL Server (Arpio DOES translate this correctly)
$dbServer    = ($dbServerFromUserData !== 'N/A') ? $dbServerFromUserData : readConf('db-server.txt');
$dbName      = ($dbNameFromUserData !== 'N/A') ? $dbNameFromUserData : readConf('db-name.txt');

// Get SQL credentials from config files (deploy script writes these)
// These credentials are backed up with the VM disk and remain the same
// Arpio uses the SQL Server tag to set the same password on the recovered DB
$dbUser = readConf('db-user.txt', 'sqladmin');
$dbPass = readConf('db-pass.txt');

// For display: try to get Key Vault name from userData or discovery for info card
$kvName = ($kvNameFromUserData !== 'N/A') ? $kvNameFromUserData : readConf('keyvault-name.txt');

// Fallback to file-based config if userData doesn't have blob endpoint
if ($storageUrl === 'N/A') {
    $storageUrl = readConf('storage-url.txt');
}

// Extract storage account name from blob endpoint URL for display
// Format: https://<accountname>.blob.core.windows.net/
$storageName = 'N/A';
if ($storageUrl !== 'N/A' && preg_match('#https://([^.]+)\.blob\.core\.windows\.net#', $storageUrl, $matches)) {
    $storageName = $matches[1];
}

// --- Logo URL from Blob Storage ---
// Format: https://<account>.blob.core.windows.net/<container>/<blob>
// AWS:    https://<bucket>.s3.amazonaws.com/<key>
$logoUrl = ($storageUrl && $storageUrl !== 'N/A')
    ? rtrim($storageUrl, '/') . '/assets/arpio-logo.svg'
    : '';

// --- Database connection ---
$dbOk = false;
$dbErr = '';
$dbSrv = '';

if ($dbServer && $dbServer !== 'N/A') {
    try {
        $conn = new PDO(
            "sqlsrv:server=tcp:{$dbServer},1433;Database={$dbName};Encrypt=yes;TrustServerCertificate=no",
            $dbUser, $dbPass
        );
        $conn->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
        $dbOk = true;

        $conn->exec("IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'app_info')
            CREATE TABLE app_info (
                id INT IDENTITY(1,1) PRIMARY KEY,
                info_key NVARCHAR(100),
                info_value NVARCHAR(500),
                updated_at DATETIME2 DEFAULT GETUTCDATE()
            )");

        $s = $conn->prepare("MERGE app_info AS t
            USING (SELECT :k AS info_key, :v AS info_value) AS s
            ON t.info_key = s.info_key
            WHEN MATCHED THEN UPDATE SET info_value = s.info_value, updated_at = GETUTCDATE()
            WHEN NOT MATCHED THEN INSERT (info_key, info_value) VALUES (s.info_key, s.info_value);");
        $s->execute([':k' => 'last_visit_region', ':v' => $region]);
        $s->execute([':k' => 'last_visit_time',   ':v' => gmdate('Y-m-d H:i:s')]);

        $r = $conn->query("SELECT @@SERVERNAME AS sn")->fetch(PDO::FETCH_ASSOC);
        $dbSrv = $r['sn'] ?? '';
    } catch (PDOException $e) {
        $dbErr = $e->getMessage();
    }
}

// --- Environment detection ---
$isPrimary = (stripos($region, 'eastus2') !== false);
$envLabel  = $isPrimary ? 'PRIMARY' : 'RECOVERY';
$bgColor1  = $isPrimary ? '#0078d4' : '#e74c3c';
$bgColor2  = $isPrimary ? '#00bcf2' : '#c0392b';
$envBadgeBg = $isPrimary ? 'rgba(40,167,69,0.9)' : 'rgba(231,76,60,0.9)';
?>
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Arpio LAMP Stack Demo — <?= $envLabel ?> — <?= strtoupper($region) ?></title>
    <style>
        *{margin:0;padding:0;box-sizing:border-box}
        body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;background:#f0f2f5;color:#333}
        .header{background:linear-gradient(135deg,<?=$bgColor1?>,<?=$bgColor2?>);color:#fff;padding:2rem;text-align:center}
        .header-logo{height:50px;margin-bottom:1rem;filter:brightness(0) invert(1)}
        .header h1{font-size:1.8rem;margin-bottom:.5rem}
        .region-badge{display:inline-block;padding:.5rem 1.5rem;border-radius:25px;font-size:1.3rem;font-weight:bold;margin-top:.5rem;border:2px solid rgba(255,255,255,.5);background:rgba(255,255,255,.15)}
        .env-badge{display:inline-block;padding:.3rem 1rem;border-radius:15px;font-size:.9rem;font-weight:bold;margin-top:.5rem;background:<?=$envBadgeBg?>}
        .container{max-width:900px;margin:2rem auto;padding:0 1rem}
        .card{background:#fff;border-radius:8px;box-shadow:0 2px 4px rgba(0,0,0,.1);margin-bottom:1.5rem;overflow:hidden}
        .card-header{background:#f8f9fa;padding:1rem 1.5rem;border-bottom:1px solid #e9ecef;font-weight:600;font-size:1.1rem;display:flex;align-items:center;gap:.5rem}
        .card-body{padding:1.5rem}
        .info-row{display:flex;padding:.6rem 0;border-bottom:1px solid #f0f0f0}
        .info-row:last-child{border-bottom:none}
        .info-label{font-weight:600;width:220px;color:#555;flex-shrink:0}
        .info-value{color:#333;word-break:break-all}
        .mono{font-family:'Courier New',monospace;font-size:.9rem}
        .ok{color:#28a745;font-weight:600}
        .err{color:#dc3545;font-weight:600}
        .aws{background:#fff3cd;padding:.3rem .6rem;border-radius:4px;font-size:.78rem;color:#856404;margin-left:.4rem;display:inline-block;white-space:nowrap}
        .summary{background:#e3f2fd;padding:1rem 1.5rem;border-radius:8px;text-align:center;margin-bottom:1.5rem}
        .summary strong{font-size:2rem;color:#0078d4}
        .logo-preview{display:block;margin:.5rem 0;max-width:200px}
        .footer{text-align:center;padding:2rem;color:#888;font-size:.9rem}
    </style>
</head>
<body>
    <div class="header">
        <?php if($logoUrl):?><img src="<?=htmlspecialchars($logoUrl)?>" alt="Arpio" class="header-logo" onerror="this.style.display='none'"><?php endif;?>
        <h1>LAMP Stack Demo on Azure</h1>
        <p>Hello World! This page dynamically detects its environment.</p>
        <div class="region-badge">&#128205; <?=strtoupper($region)?></div><br>
        <div class="env-badge"><?=$envLabel?> ENVIRONMENT</div>
    </div>

    <div class="container">
        <div class="summary">
            <strong>10</strong> Arpio-protected Azure resource types powering this app<br>
            <small>VM · VNet · NSG · NIC · Public IP · Application Gateway · Load Balancer · SQL Server/DB · Key Vault · Storage Account</small>
        </div>

        <!-- Compute -->
        <div class="card">
            <div class="card-header">&#128187; Compute — Virtual Machine <span class="aws">≈ EC2</span></div>
            <div class="card-body">
                <div class="info-row"><span class="info-label">VM Name</span><span class="info-value"><?=htmlspecialchars($vmName)?></span></div>
                <div class="info-row"><span class="info-label">Region</span><span class="info-value"><?=htmlspecialchars($region)?></span></div>
                <div class="info-row"><span class="info-label">VM Size</span><span class="info-value"><?=htmlspecialchars($vmSize)?> <span class="aws">≈ t3.small</span></span></div>
                <div class="info-row"><span class="info-label">Subscription ID</span><span class="info-value mono"><?=htmlspecialchars($subId)?> <span class="aws">≈ AWS Account ID</span></span></div>
                <div class="info-row"><span class="info-label">Resource Group</span><span class="info-value"><?=htmlspecialchars($rgName)?> <span class="aws">≈ CFN Stack</span></span></div>
                <div class="info-row"><span class="info-label">Private IP</span><span class="info-value mono"><?=htmlspecialchars($privateIp)?></span></div>
                <div class="info-row"><span class="info-label">Public IP</span><span class="info-value mono"><?=htmlspecialchars($publicIp)?></span></div>
                <div class="info-row"><span class="info-label">OS</span><span class="info-value"><?=htmlspecialchars("$osType — Ubuntu $imageSku")?></span></div>
            </div>
        </div>

        <!-- Network -->
        <div class="card">
            <div class="card-header">&#127760; Network — Virtual Network <span class="aws">≈ VPC</span></div>
            <div class="card-body">
                <?php
                // Derive network resource names from the resource group name
                // RG is typically "<prefix>-rg", so strip "-rg" to get the prefix
                $netPrefix = ($rgName && $rgName !== 'Unknown') ? preg_replace('/-rg$/', '', $rgName) : 'LampApp';
                ?>
                <div class="info-row"><span class="info-label">VNet</span><span class="info-value"><?=htmlspecialchars($netPrefix)?>-vnet (10.0.0.0/16)</span></div>
                <div class="info-row"><span class="info-label">Subnet</span><span class="info-value"><?=htmlspecialchars($netPrefix)?>-subnet (10.0.1.0/24)</span></div>
                <div class="info-row"><span class="info-label">NSG</span><span class="info-value"><?=htmlspecialchars($netPrefix)?>-nsg <span class="aws">≈ Security Group</span></span></div>
                <div class="info-row"><span class="info-label">Service Endpoints</span><span class="info-value">KeyVault, Storage <span class="aws">≈ VPC Endpoints</span></span></div>
            </div>
        </div>

        <!-- Database -->
        <div class="card">
            <div class="card-header">&#128451; Database — Azure SQL <span class="aws">≈ RDS SQL Server</span></div>
            <div class="card-body">
                <div class="info-row"><span class="info-label">Status</span><span class="info-value <?=$dbOk?'ok':'err'?>"><?=$dbOk?'&#10004; Connected':'&#10008; Disconnected'?></span></div>
                <div class="info-row"><span class="info-label">SQL Server FQDN</span><span class="info-value mono"><?=htmlspecialchars($dbServer)?> <span class="aws">≈ RDS Endpoint</span></span></div>
                <div class="info-row"><span class="info-label">Database</span><span class="info-value"><?=htmlspecialchars($dbName)?></span></div>
                <?php if($dbSrv):?><div class="info-row"><span class="info-label">Server Name</span><span class="info-value mono"><?=htmlspecialchars($dbSrv)?></span></div><?php endif;?>
                <?php if($dbErr):?><div class="info-row"><span class="info-label">Error</span><span class="info-value err" style="font-size:.85rem"><?=htmlspecialchars($dbErr)?></span></div><?php endif;?>
            </div>
        </div>

        <!-- Key Vault -->
        <div class="card">
            <div class="card-header">&#128272; Security — Key Vault <span class="aws">≈ Secrets Manager + KMS</span></div>
            <div class="card-body">
                <div class="info-row"><span class="info-label">Key Vault Name</span><span class="info-value mono"><?=htmlspecialchars($kvName)?></span></div>
                <div class="info-row"><span class="info-label">Stored Secrets</span><span class="info-value">sql-admin-username, sql-admin-password, sql-server-fqdn, sql-database-name, storage-blob-url</span></div>
                <div class="info-row"><span class="info-label">VM Access</span><span class="info-value">System-Assigned Managed Identity <span class="aws">≈ EC2 Instance Profile</span></span></div>
            </div>
        </div>

        <!-- Storage + Logo -->
        <div class="card">
            <div class="card-header">&#128230; Storage — Blob Storage <span class="aws">≈ S3</span></div>
            <div class="card-body">
                <div class="info-row"><span class="info-label">Storage Account</span><span class="info-value mono"><?=htmlspecialchars($storageName)?></span></div>
                <div class="info-row"><span class="info-label">Blob Endpoint</span><span class="info-value mono"><?=htmlspecialchars($storageUrl)?></span></div>
                <div class="info-row"><span class="info-label">Container</span><span class="info-value">assets <span class="aws">≈ S3 Bucket</span></span></div>
                <div class="info-row">
                    <span class="info-label">Logo Blob</span>
                    <span class="info-value">
                        <?php if($logoUrl):?>
                            <a href="<?=htmlspecialchars($logoUrl)?>" target="_blank">arpio-logo.svg</a>
                            <span class="aws">≈ s3://assets/arpio-logo.svg</span>
                        <?php else:?>
                            <span class="err">Not configured</span>
                        <?php endif;?>
                    </span>
                </div>
                <?php if($logoUrl):?>
                <div class="info-row">
                    <span class="info-label">Logo Preview</span>
                    <span class="info-value">
                        <img src="<?=htmlspecialchars($logoUrl)?>" alt="Arpio Logo from Blob" class="logo-preview"
                             onerror="this.parentElement.innerHTML='<span class=err>Failed to load from blob storage</span>'">
                    </span>
                </div>
                <?php endif;?>
            </div>
        </div>


        <!-- VM userData Configuration (Arpio-translated) -->
        <div class="card">
            <div class="card-header">&#128220; VM User Data — Configuration Source <span class="aws">≈ EC2 User Data</span></div>
            <div class="card-body">
                <div class="info-row"><span class="info-label">Source</span><span class="info-value">IMDS compute/userData endpoint</span></div>
                <div class="info-row"><span class="info-label">Translation</span><span class="info-value">Arpio translates FQDNs and endpoint URLs during recovery</span></div>
                <div class="info-row"><span class="info-label">SQL Server FQDN</span><span class="info-value mono"><?=htmlspecialchars($userData["sqlServerFqdn"] ?? "N/A")?></span></div>
                <div class="info-row"><span class="info-label">SQL Database Name</span><span class="info-value"><?=htmlspecialchars($userData["sqlDatabaseName"] ?? "N/A")?></span></div>
                <div class="info-row"><span class="info-label">Key Vault Name</span><span class="info-value mono"><?=htmlspecialchars($userData["keyVaultName"] ?? "N/A")?></span></div>
                <div class="info-row"><span class="info-label">Storage Blob Endpoint</span><span class="info-value mono"><?=htmlspecialchars($userData["storageBlobEndpoint"] ?? "N/A")?></span></div>
                <div class="info-row"><span class="info-label">Storage Account Name (extracted)</span><span class="info-value mono"><?=htmlspecialchars($storageName)?></span></div>
            </div>
        </div>

        <!-- Application Gateway -->
        <div class="card">
            <div class="card-header">&#128268; Application Gateway — Layer 7 Load Balancer <span class="aws">≈ Application Load Balancer (ALB)</span></div>
            <div class="card-body">
                <?php
                // Try to get Application Gateway info from Azure Resource Management API
                $agInfo = 'Deployed';
                $agIp = 'Check deployment outputs';
                try {
                    // Could query ARM API here with managed identity
                    // For now, just show it's deployed
                } catch (Exception $e) {}
                ?>
                <div class="info-row"><span class="info-label">Status</span><span class="info-value ok">&#10004; <?=htmlspecialchars($agInfo)?></span></div>
                <div class="info-row"><span class="info-label">SKU</span><span class="info-value">Standard_v2</span></div>
                <div class="info-row"><span class="info-label">Frontend IP</span><span class="info-value mono"><?=htmlspecialchars($agIp)?></span></div>
                <div class="info-row"><span class="info-label">Backend Pool</span><span class="info-value">VM Private IP</span></div>
                <div class="info-row"><span class="info-label">Protocol</span><span class="info-value">HTTP (Port 80)</span></div>
                <div class="info-row"><span class="info-label">Network Sandbox</span><span class="info-value">Supports inbound traffic via App Gateway</span></div>
            </div>
        </div>

        <!-- Load Balancer -->
        <div class="card">
            <div class="card-header">&#9878; Load Balancer — Layer 4 Load Balancer <span class="aws">≈ Network Load Balancer (NLB)</span></div>
            <div class="card-body">
                <?php
                // Try to get Load Balancer info from Azure Resource Management API
                $lbInfo = 'Deployed';
                $lbIp = 'Check deployment outputs';
                try {
                    // Could query ARM API here with managed identity
                    // For now, just show it's deployed
                } catch (Exception $e) {}
                ?>
                <div class="info-row"><span class="info-label">Status</span><span class="info-value ok">&#10004; <?=htmlspecialchars($lbInfo)?></span></div>
                <div class="info-row"><span class="info-label">SKU</span><span class="info-value">Standard</span></div>
                <div class="info-row"><span class="info-label">Frontend IP</span><span class="info-value mono"><?=htmlspecialchars($lbIp)?></span></div>
                <div class="info-row"><span class="info-label">Backend Pool</span><span class="info-value">VM NIC</span></div>
                <div class="info-row"><span class="info-label">Protocol</span><span class="info-value">TCP (Port 80)</span></div>
                <div class="info-row"><span class="info-label">Network Sandbox</span><span class="info-value">Uses DNAT rules for inbound traffic</span></div>
            </div>
        </div>


        <!-- Application Gateway -->
        <div class="card">
            <div class="card-header">&#128268; Application Gateway — Layer 7 Load Balancer <span class="aws">≈ Application Load Balancer (ALB)</span></div>
            <div class="card-body">
                <?php
                // Read from config file
                if (file_exists("/etc/arpio-lamp/lb-config.json")) {
                    $lbConfigData = json_decode(file_get_contents("/etc/arpio-lamp/lb-config.json"), true) ?: [];
                    $agwId = $lbConfigData["appGatewayId"] ?? "N/A";
                    $agwName = $lbConfigData["appGatewayName"] ?? "N/A";
                    $agwIp = $lbConfigData["appGatewayPublicIp"] ?? "N/A";
                } else {
                    $agwId = "N/A";
                    $agwName = $netPrefix . "-appgw";
                    $agwIp = "N/A";
                }
                ?>
                <div class="info-row"><span class="info-label">Status</span><span class="info-value ok">&#10004; Deployed</span></div>
                <div class="info-row"><span class="info-label">Resource ID</span><span class="info-value mono" style="font-size:0.75rem"><?=htmlspecialchars($agwId)?></span></div>
                <div class="info-row"><span class="info-label">Name</span><span class="info-value"><?=htmlspecialchars($agwName)?></span></div>
                <div class="info-row"><span class="info-label">Public IP</span><span class="info-value mono"><?=htmlspecialchars($agwIp)?></span></div>
                <div class="info-row"><span class="info-label">SKU</span><span class="info-value">Standard_v2 (Layer 7)</span></div>
                <div class="info-row"><span class="info-label">Tier</span><span class="info-value">Standard_v2</span></div>
                <div class="info-row"><span class="info-label">Protocol</span><span class="info-value">HTTP (Port 80)</span></div>
                <div class="info-row"><span class="info-label">Backend Target</span><span class="info-value">VM at <?=htmlspecialchars($privateIp)?></span></div>
                <div class="info-row"><span class="info-label">Network Sandbox</span><span class="info-value ok">&#10004; Supports inbound traffic when Network Sandbox is enabled</span></div>
            </div>
        </div>

        <!-- Load Balancer -->
        <div class="card">
            <div class="card-header">&#9878; Load Balancer — Layer 4 Load Balancer <span class="aws">≈ Network Load Balancer (NLB)</span></div>
            <div class="card-body">
                <?php
                // Read from config file
                if (file_exists("/etc/arpio-lamp/lb-config.json")) {
                    $lbConfigData = json_decode(file_get_contents("/etc/arpio-lamp/lb-config.json"), true) ?: [];
                    $lbId = $lbConfigData["loadBalancerId"] ?? "N/A";
                    $lbName = $lbConfigData["loadBalancerName"] ?? "N/A";
                    $lbIp = $lbConfigData["loadBalancerPublicIp"] ?? "N/A";
                } else {
                    $lbId = "N/A";
                    $lbName = $netPrefix . "-lb";
                    $lbIp = "N/A";
                }
                ?>
                <div class="info-row"><span class="info-label">Status</span><span class="info-value ok">&#10004; Deployed</span></div>
                <div class="info-row"><span class="info-label">Resource ID</span><span class="info-value mono" style="font-size:0.75rem"><?=htmlspecialchars($lbId)?></span></div>
                <div class="info-row"><span class="info-label">Name</span><span class="info-value"><?=htmlspecialchars($lbName)?></span></div>
                <div class="info-row"><span class="info-label">Public IP</span><span class="info-value mono"><?=htmlspecialchars($lbIp)?></span></div>
                <div class="info-row"><span class="info-label">SKU</span><span class="info-value">Standard (Layer 4)</span></div>
                <div class="info-row"><span class="info-label">Tier</span><span class="info-value">Regional</span></div>
                <div class="info-row"><span class="info-label">Protocol</span><span class="info-value">TCP (Port 80)</span></div>
                <div class="info-row"><span class="info-label">Backend Target</span><span class="info-value">VM NIC at <?=htmlspecialchars($privateIp)?></span></div>
                <div class="info-row"><span class="info-label">Distribution Mode</span><span class="info-value">5-tuple hash (src IP, src port, dst IP, dst port, protocol)</span></div>
                <div class="info-row"><span class="info-label">Network Sandbox</span><span class="info-value ok">&#10004; Uses DNAT rules for inbound traffic when Network Sandbox is enabled</span></div>
            </div>
        </div>

        <!-- Web Server -->
        <div class="card">
            <div class="card-header">&#127758; Web Server</div>
            <div class="card-body">
                <div class="info-row"><span class="info-label">Server</span><span class="info-value">Apache/2 on Ubuntu</span></div>
                <div class="info-row"><span class="info-label">PHP Version</span><span class="info-value"><?=phpversion()?></span></div>
                <div class="info-row"><span class="info-label">Server Time (UTC)</span><span class="info-value"><?=gmdate('Y-m-d H:i:s T')?></span></div>
                <div class="info-row"><span class="info-label">Hostname</span><span class="info-value mono"><?=gethostname()?></span></div>
            </div>
        </div>
    </div>

    <div class="footer">
        Arpio &bull; LAMP Stack Demo on Azure &bull; <?=$envLabel?> in <strong><?=strtoupper($region)?></strong><br>
        After Arpio recovery → <strong>eastus2</strong>, different Subscription ID, new resource endpoints.<br>
        <small>The logo above is served from Azure Blob Storage (≈ S3) — it should also recover!</small>
    </div>

    <script>setTimeout(()=>location.reload(),30000);</script>
</body>
</html>
