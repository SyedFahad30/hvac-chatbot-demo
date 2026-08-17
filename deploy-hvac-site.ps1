<#
.SYNOPSIS
  deploy-hvac-site.ps1 - Hosts the HVAC demo site (index.html, dashboard.html,
  hvac-chat-widget.js) publicly over HTTPS via CloudFront + a private S3
  bucket, same pattern as deploy-site.ps1 for Lake America.

.USAGE
  1. Add to config-hvac.env:  SITE_BUCKET=some-globally-unique-name
  2. Run:  .\deploy-hvac-site.ps1
#>

$ErrorActionPreference = "Continue"

if (-not (Test-Path ".\config-hvac.env")) {
    Write-Host "Missing config-hvac.env." -ForegroundColor Red
    exit 1
}

$config = @{}
Get-Content ".\config-hvac.env" | ForEach-Object {
    $line = $_.Trim()
    if ($line -and -not $line.StartsWith("#") -and $line.Contains("=")) {
        $parts = $line.Split("=", 2)
        $config[$parts[0].Trim()] = $parts[1].Trim()
    }
}

$Region     = $config["AWS_REGION"]
$Profile    = $config["AWS_PROFILE"]
$SiteBucket = $config["SITE_BUCKET"]

if (-not $SiteBucket) {
    Write-Host "Add a line to config-hvac.env first: SITE_BUCKET=some-globally-unique-name" -ForegroundColor Red
    exit 1
}

$AwsArgs = @("--region", $Region)
if ($Profile) { $AwsArgs += @("--profile", $Profile) }

function Test-AwsSuccess {
    param([string[]]$CmdArgs)
    & aws @CmdArgs @AwsArgs *> $null
    return ($LASTEXITCODE -eq 0)
}

Write-Host "== Creating site bucket ($SiteBucket) ==" -ForegroundColor Cyan
$bucketExists = Test-AwsSuccess -CmdArgs @("s3api", "head-bucket", "--bucket", $SiteBucket)
if ($bucketExists) {
    Write-Host "Bucket already exists, skipping creation."
} else {
    if ($Region -eq "us-east-1") {
        & aws s3api create-bucket --bucket $SiteBucket @AwsArgs | Out-Null
    } else {
        & aws s3api create-bucket --bucket $SiteBucket `
            --create-bucket-configuration LocationConstraint=$Region @AwsArgs | Out-Null
    }
    & aws s3api put-public-access-block --bucket $SiteBucket @AwsArgs `
        --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
}

Write-Host "== Uploading site files ==" -ForegroundColor Cyan
Copy-Item ".\hvac-live-site.html" ".\index.html" -Force
& aws s3 cp ".\index.html" "s3://$SiteBucket/index.html" @AwsArgs --content-type "text/html" | Out-Null
& aws s3 cp ".\hvac-chat-widget.js" "s3://$SiteBucket/hvac-chat-widget.js" @AwsArgs --content-type "application/javascript" | Out-Null
if (Test-Path ".\hvac-dashboard.html") {
    & aws s3 cp ".\hvac-dashboard.html" "s3://$SiteBucket/dashboard.html" @AwsArgs --content-type "text/html" | Out-Null
}

Write-Host "== Creating CloudFront Origin Access Control ==" -ForegroundColor Cyan
$oacName = "$SiteBucket-oac"
$existingOac = (& aws cloudfront list-origin-access-controls `
    --query "OriginAccessControlList.Items[?Name=='$oacName'].Id" --output text)

if ($existingOac -and $existingOac -ne "None") {
    $OacId = $existingOac
    Write-Host "OAC already exists ($OacId), reusing."
} else {
    $oacConfig = @{
        Name = $oacName
        OriginAccessControlOriginType = "s3"
        SigningBehavior = "always"
        SigningProtocol = "sigv4"
    } | ConvertTo-Json -Compress
    $oacConfigPath = "$env:TEMP\hvac-oac-config.json"
    Set-Content -Path $oacConfigPath -Value $oacConfig -NoNewline
    $OacId = (& aws cloudfront create-origin-access-control `
        --origin-access-control-config "file://$oacConfigPath" `
        --query "OriginAccessControl.Id" --output text)
}
Write-Host "OAC ID: $OacId"

Write-Host "== Creating CloudFront distribution ==" -ForegroundColor Cyan
$bucketDomain = "$SiteBucket.s3.$Region.amazonaws.com"
$existingDist = (& aws cloudfront list-distributions `
    --query "DistributionList.Items[?Comment=='$SiteBucket'].Id" --output text)

if ($existingDist -and $existingDist -ne "None") {
    $DistId = $existingDist
    Write-Host "Distribution already exists ($DistId), reusing."
} else {
    $callerRef = [guid]::NewGuid().ToString()
    $distConfig = @{
        CallerReference   = $callerRef
        Comment           = $SiteBucket
        Enabled           = $true
        DefaultRootObject = "index.html"
        Origins = @{
            Quantity = 1
            Items = @(
                @{
                    Id                    = "s3-origin"
                    DomainName            = $bucketDomain
                    OriginAccessControlId = $OacId
                    S3OriginConfig        = @{ OriginAccessIdentity = "" }
                }
            )
        }
        DefaultCacheBehavior = @{
            TargetOriginId       = "s3-origin"
            ViewerProtocolPolicy = "redirect-to-https"
            AllowedMethods = @{
                Quantity = 2
                Items    = @("GET", "HEAD")
            }
            CachePolicyId = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
        }
    } | ConvertTo-Json -Depth 10 -Compress
    $distConfigPath = "$env:TEMP\hvac-dist-config.json"
    Set-Content -Path $distConfigPath -Value $distConfig -NoNewline

    $createResult = & aws cloudfront create-distribution `
        --distribution-config "file://$distConfigPath" | ConvertFrom-Json
    $DistId = $createResult.Distribution.Id
}

$distInfo = & aws cloudfront get-distribution --id $DistId | ConvertFrom-Json
$DistDomain = $distInfo.Distribution.DomainName
$DistArn = $distInfo.Distribution.ARN

Write-Host "Distribution ID: $DistId"
Write-Host "Distribution domain: https://$DistDomain"

Write-Host "== Updating S3 bucket policy for CloudFront access ==" -ForegroundColor Cyan
$bucketPolicy = @{
    Version = "2012-10-17"
    Statement = @(
        @{
            Sid       = "AllowCloudFrontServicePrincipal"
            Effect    = "Allow"
            Principal = @{ Service = "cloudfront.amazonaws.com" }
            Action    = "s3:GetObject"
            Resource  = "arn:aws:s3:::$SiteBucket/*"
            Condition = @{ StringEquals = @{ "AWS:SourceArn" = $DistArn } }
        }
    )
} | ConvertTo-Json -Depth 10 -Compress
$bucketPolicyPath = "$env:TEMP\hvac-site-bucket-policy.json"
Set-Content -Path $bucketPolicyPath -Value $bucketPolicy -NoNewline
& aws s3api put-bucket-policy --bucket $SiteBucket --policy "file://$bucketPolicyPath" @AwsArgs

Write-Host ""
Write-Host "==================================================================" -ForegroundColor Green
Write-Host " HVAC SITE DEPLOYED"
Write-Host "=================================================================="
Write-Host " Public URL:      https://$DistDomain"
Write-Host " Dashboard URL:   https://$DistDomain/dashboard.html"
Write-Host ""
Write-Host " Give CloudFront 5-15 minutes on first deploy before it's reachable."
Write-Host ""
Write-Host " IMPORTANT NEXT STEP - lock down CORS to this real domain:"
Write-Host "   1. Update in config-hvac.env:  ALLOWED_ORIGIN=https://$DistDomain"
Write-Host "   2. Run .\deploy-hvac.ps1 again"
Write-Host "=================================================================="
