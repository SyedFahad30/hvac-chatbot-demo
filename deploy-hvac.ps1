<#
.SYNOPSIS
  deploy-hvac.ps1 - Provisions the full backend for the Clermont Air & Heat
  (HVAC) chat + missed-call demo, entirely separate from the Lake America
  resources. Same pattern as deploy.ps1.

  Resources created:
    - IAM role + policy for the Lambda
    - S3 bucket (new-job intake workbook)
    - DynamoDB table (conversation storage, keyed by session ID for web,
      by phone number for SMS)
    - Lambda function (Python 3.12), packaged with openpyxl
    - API Gateway HTTP API with routes for the widget, dashboard, and the
      two Twilio webhooks (/voice, /sms)

.USAGE
  1. Copy config-hvac.env.example to config-hvac.env, then edit it.
  2. Run:  .\deploy-hvac.ps1
#>

$ErrorActionPreference = "Continue"

if (-not (Test-Path ".\config-hvac.env")) {
    Write-Host "Missing config-hvac.env. Run: Copy-Item config-hvac.env.example config-hvac.env, then edit it." -ForegroundColor Red
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

$Region       = $config["AWS_REGION"]
$Profile      = $config["AWS_PROFILE"]
$FunctionName = $config["FUNCTION_NAME"]
$RoleName     = $config["ROLE_NAME"]
$TableName    = $config["TABLE_NAME"]
$ApiName      = $config["API_NAME"]
$AnthropicKey = $config["ANTHROPIC_API_KEY"]
$Bucket       = $config["S3_BUCKET"]
$S3Key        = $config["S3_KEY"]
$AllowedOrigin = $config["ALLOWED_ORIGIN"]
$TwilioSid    = $config["TWILIO_ACCOUNT_SID"]
$TwilioToken  = $config["TWILIO_AUTH_TOKEN"]
$TwilioNumber = $config["TWILIO_PHONE_NUMBER"]

$AwsArgs = @("--region", $Region)
if ($Profile) { $AwsArgs += @("--profile", $Profile) }

function Test-AwsSuccess {
    param([string[]]$CmdArgs)
    & aws @CmdArgs @AwsArgs *> $null
    return ($LASTEXITCODE -eq 0)
}

Write-Host "== Checking AWS CLI identity ==" -ForegroundColor Cyan
$identity = & aws sts get-caller-identity @AwsArgs | ConvertFrom-Json
$AccountId = $identity.Account
Write-Host "Deploying to account $AccountId in $Region"

# ------------------------------------------------------------------
# 1. IAM ROLE
# ------------------------------------------------------------------
Write-Host "== Creating IAM role ($RoleName) ==" -ForegroundColor Cyan
$roleExists = Test-AwsSuccess -CmdArgs @("iam", "get-role", "--role-name", $RoleName)
if ($roleExists) {
    Write-Host "Role already exists, skipping creation."
} else {
    & aws iam create-role --role-name $RoleName `
        --assume-role-policy-document file://hvac-iam-trust-policy.json @AwsArgs | Out-Null
    Write-Host "Waiting for IAM role to propagate..."
    Start-Sleep -Seconds 10
}

$policyContent = Get-Content ".\hvac-iam-permissions-policy.json" -Raw
$resolvedPolicy = $policyContent -replace "REPLACE_WITH_BUCKET_NAME", $Bucket
$resolvedPolicyPath = "$env:TEMP\hvac-iam-permissions-policy.resolved.json"
Set-Content -Path $resolvedPolicyPath -Value $resolvedPolicy -NoNewline

& aws iam put-role-policy --role-name $RoleName `
    --policy-name "$RoleName-inline-policy" `
    --policy-document "file://$resolvedPolicyPath" @AwsArgs

$RoleArn = (& aws iam get-role --role-name $RoleName --query 'Role.Arn' --output text @AwsArgs)
Write-Host "Role ARN: $RoleArn"

# ------------------------------------------------------------------
# 2. S3 BUCKET (new-job intake workbook)
# ------------------------------------------------------------------
Write-Host "== Creating S3 bucket ($Bucket) ==" -ForegroundColor Cyan
$bucketExists = Test-AwsSuccess -CmdArgs @("s3api", "head-bucket", "--bucket", $Bucket)
if ($bucketExists) {
    Write-Host "Bucket already exists, skipping creation."
} else {
    if ($Region -eq "us-east-1") {
        & aws s3api create-bucket --bucket $Bucket @AwsArgs | Out-Null
    } else {
        & aws s3api create-bucket --bucket $Bucket `
            --create-bucket-configuration LocationConstraint=$Region @AwsArgs | Out-Null
    }
    & aws s3api put-public-access-block --bucket $Bucket @AwsArgs `
        --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
    Write-Host "Bucket created (private)."
}

# ------------------------------------------------------------------
# 3. DYNAMODB TABLE
# ------------------------------------------------------------------
Write-Host "== Creating DynamoDB table ($TableName) ==" -ForegroundColor Cyan
$tableExists = Test-AwsSuccess -CmdArgs @("dynamodb", "describe-table", "--table-name", $TableName)
if ($tableExists) {
    Write-Host "Table already exists, skipping creation."
} else {
    & aws dynamodb create-table --table-name $TableName `
        --attribute-definitions AttributeName=sessionId,AttributeType=S `
        --key-schema AttributeName=sessionId,KeyType=HASH `
        --billing-mode PAY_PER_REQUEST @AwsArgs | Out-Null
    & aws dynamodb wait table-exists --table-name $TableName @AwsArgs
    & aws dynamodb update-time-to-live --table-name $TableName `
        --time-to-live-specification "Enabled=true, AttributeName=ttl" @AwsArgs | Out-Null
}

# ------------------------------------------------------------------
# 4. LAMBDA FUNCTION (packaged with openpyxl)
# ------------------------------------------------------------------
Write-Host "== Packaging Lambda (with openpyxl dependency) ==" -ForegroundColor Cyan
if (Test-Path ".\hvac-build") { Remove-Item ".\hvac-build" -Recurse -Force }
if (Test-Path ".\hvac-function.zip") { Remove-Item ".\hvac-function.zip" -Force }
New-Item -ItemType Directory -Path ".\hvac-build" | Out-Null

pip install openpyxl -t hvac-build --quiet --disable-pip-version-check
Copy-Item ".\hvac-lambda_function.py" ".\hvac-build\lambda_function.py"
Compress-Archive -Path ".\hvac-build\*" -DestinationPath ".\hvac-function.zip"

Write-Host "== Deploying Lambda function ($FunctionName) ==" -ForegroundColor Cyan
# NOTE: AWS CLI's shorthand syntax (--environment Variables={K=V,...}) breaks
# when any value is an empty string (e.g. TWILIO_* fields left blank until
# you have an account) — the shorthand parser errors with "Expected: ',',
# received: 'EOF'" partway through. Writing the environment as real JSON to
# a file and passing --environment file://... sidesteps that parser entirely
# and handles empty strings correctly.
$envVarsObj = @{
    Variables = @{
        ANTHROPIC_API_KEY   = $AnthropicKey
        DYNAMODB_TABLE      = $TableName
        S3_BUCKET           = $Bucket
        S3_KEY              = $S3Key
        ALLOWED_ORIGIN      = $AllowedOrigin
        TWILIO_ACCOUNT_SID  = $TwilioSid
        TWILIO_AUTH_TOKEN   = $TwilioToken
        TWILIO_PHONE_NUMBER = $TwilioNumber
    }
}
$envVarsPath = "$env:TEMP\hvac-lambda-env.json"
($envVarsObj | ConvertTo-Json -Compress) | Set-Content -Path $envVarsPath -NoNewline

$functionExists = Test-AwsSuccess -CmdArgs @("lambda", "get-function", "--function-name", $FunctionName)
if ($functionExists) {
    & aws lambda update-function-code --function-name $FunctionName `
        --zip-file fileb://hvac-function.zip @AwsArgs | Out-Null
    & aws lambda wait function-updated --function-name $FunctionName @AwsArgs
    & aws lambda update-function-configuration --function-name $FunctionName `
        --environment "file://$envVarsPath" --timeout 30 @AwsArgs | Out-Null
} else {
    & aws lambda create-function --function-name $FunctionName `
        --runtime python3.12 `
        --role $RoleArn `
        --handler lambda_function.lambda_handler `
        --zip-file fileb://hvac-function.zip `
        --timeout 30 `
        --memory-size 256 `
        --environment "file://$envVarsPath" @AwsArgs | Out-Null
}
& aws lambda wait function-active --function-name $FunctionName @AwsArgs

$LambdaArn = (& aws lambda get-function --function-name $FunctionName `
    --query 'Configuration.FunctionArn' --output text @AwsArgs)
Write-Host "Lambda ARN: $LambdaArn"

# ------------------------------------------------------------------
# 5. API GATEWAY (HTTP API) + ROUTE + LAMBDA PERMISSION
# ------------------------------------------------------------------
Write-Host "== Creating API Gateway HTTP API ($ApiName) ==" -ForegroundColor Cyan
$existingApiId = (& aws apigatewayv2 get-apis @AwsArgs `
    --query "Items[?Name=='$ApiName'].ApiId" --output text)

if ($existingApiId -and $existingApiId -ne "None") {
    $ApiId = $existingApiId
    Write-Host "API already exists ($ApiId), reusing."
} else {
    $corsConfig = "AllowOrigins=$AllowedOrigin,AllowMethods=GET,POST,OPTIONS,AllowHeaders=content-type"
    # --target creates a catch-all $default route to this Lambda. Twilio's
    # /voice and /sms POSTs, the widget's POST /, and the dashboard's GET /
    # are all distinguished INSIDE the Lambda by rawPath, not by separate
    # API Gateway routes - simpler than managing multiple routes/integrations.
    $ApiId = (& aws apigatewayv2 create-api --name $ApiName `
        --protocol-type HTTP --target $LambdaArn `
        --cors-configuration $corsConfig @AwsArgs `
        --query 'ApiId' --output text)
}
Write-Host "API ID: $ApiId"

try {
    & aws lambda add-permission --function-name $FunctionName `
        --statement-id "apigw-invoke-$ApiId" `
        --action lambda:InvokeFunction `
        --principal apigateway.amazonaws.com `
        --source-arn "arn:aws:execute-api:${Region}:${AccountId}:${ApiId}/*/*" @AwsArgs 2>$null | Out-Null
} catch { }

$ApiEndpoint = "https://$ApiId.execute-api.$Region.amazonaws.com/"

Write-Host ""
Write-Host "==================================================================" -ForegroundColor Green
Write-Host " HVAC DEPLOYMENT COMPLETE"
Write-Host "=================================================================="
Write-Host " API endpoint: $ApiEndpoint"
Write-Host " Intake workbook: s3://$Bucket/$S3Key"
Write-Host ""
if (-not $TwilioSid) {
    Write-Host " Twilio is NOT configured yet - /voice and /sms will no-op safely."
    Write-Host " See README-hvac.md for how to set up a Twilio number and point"
    Write-Host " its webhooks at:"
    Write-Host "   Voice webhook: ${ApiEndpoint}voice"
    Write-Host "   SMS webhook:   ${ApiEndpoint}sms"
} else {
    Write-Host " Twilio webhooks to configure in the Twilio console:"
    Write-Host "   Voice webhook: ${ApiEndpoint}voice"
    Write-Host "   SMS webhook:   ${ApiEndpoint}sms"
}
Write-Host ""
Write-Host " NEXT STEPS:"
Write-Host " 1. Point the widget at your live endpoint:"
Write-Host "      .\update-hvac-widget-endpoint.ps1 -Endpoint `"$ApiEndpoint`""
Write-Host " 2. Test the chat directly:"
Write-Host "      Invoke-RestMethod -Uri `"$ApiEndpoint`" -Method Post -ContentType 'application/json' -Body '{\"messages\":[{\"role\":\"user\",\"content\":\"My AC stopped working\"}]}'"
Write-Host "=================================================================="
