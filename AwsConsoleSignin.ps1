<#
.SYNOPSIS
    Self-service AWS Console sign-in for external users, via Cognito email OTP.

.DESCRIPTION
    What it does, in order:
      1. Prompts the user for their email.
      2. Checks whether they exist in the Cognito User Pool; if not, signs them
         up and walks them through email confirmation.
      3. Starts an email-OTP sign-in and prompts for the code from their inbox.
      4. Exchanges the resulting Cognito token for temporary AWS credentials
         via the Identity Pool (mapped to the pre-existing PowerUser role).
      5. Trades those credentials for an AWS Console federation sign-in URL
         and prints it. The user opens it in a browser and is signed in.

    All Cognito calls are unsigned (public), which is the intended pattern for
    a User Pool app client with no secret. The user does NOT need AWS CLI or
    IAM credentials on their machine.

.REQUIREMENTS
    - PowerShell 5.1+ (Windows) or PowerShell 7+ (macOS / Linux)
    - Internet access to *.amazonaws.com and signin.aws.amazon.com
    - No AWS modules or credentials required — script uses raw HTTPS calls.
    - AWS CLI is required only when -CliProfile is supplied.

.PARAMETER CliProfile
    Optional AWS CLI profile name. When supplied, the temporary Cognito
    credentials are also written to this profile for CLI use until they expire.
    The default behavior remains console sign-in only.

.NOTES
    Ship a copy of this file to users with the CONFIG values pre-filled for
    your deployment.
#>

[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z0-9_-]+$')]
    [string]$CliProfile = ''
)

# --------------------------------------------------------------------------- #
# CONFIG — replace these five values for your deployment before distributing. #
# --------------------------------------------------------------------------- #
$Region           = 'ap-southeast-2'
$UserPoolId       = 'ap-southeast-2_VHZyDcAOY'
$AppClientId      = '5r191kap6c9ueg109ile1kfqja'
$IdentityPoolId   = 'ap-southeast-2:569a1f8e-2d4b-4bd7-8922-28a48f3421bd'
$IssuerUrl        = 'https://ngis.com/'   # cosmetic; shown in AWS sign-in logs
# --------------------------------------------------------------------------- #

$ConsoleUrl        = 'https://console.aws.amazon.com/'
$FederationUrl     = 'https://signin.aws.amazon.com/federation'
$CognitoIdpUrl     = "https://cognito-idp.$Region.amazonaws.com/"
$CognitoIdentityUrl = "https://cognito-identity.$Region.amazonaws.com/"

# Force TLS 1.2 for older Windows PowerShell (5.1); no-op on PS 7.
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }


function Read-NonEmpty {
    param([string]$Prompt)
    $value = (Read-Host -Prompt $Prompt).Trim()
    if ([string]::IsNullOrWhiteSpace($value)) {
        Write-Host 'No input given, exiting.' -ForegroundColor Red
        exit 1
    }
    return $value
}


# Cognito Identity Provider and Cognito Identity are AWS "JSON 1.1" services:
# HTTP POST, Content-Type application/x-amz-json-1.1, and a target header
# naming the operation. No SigV4 signing needed for these operations because
# our app client has no secret.
function Invoke-CognitoIdp {
    param(
        [Parameter(Mandatory)][string]$Target,   # e.g. 'AWSCognitoIdentityProviderService.SignUp'
        [Parameter(Mandatory)][hashtable]$Body
    )
    $headers = @{
        'X-Amz-Target' = $Target
        'Content-Type' = 'application/x-amz-json-1.1'
    }
    return Invoke-RestMethod -Uri $CognitoIdpUrl -Method Post -Headers $headers `
        -Body ($Body | ConvertTo-Json -Depth 10 -Compress)
}

function Invoke-CognitoIdentity {
    param(
        [Parameter(Mandatory)][string]$Target,   # e.g. 'AWSCognitoIdentityService.GetId'
        [Parameter(Mandatory)][hashtable]$Body
    )
    $headers = @{
        'X-Amz-Target' = $Target
        'Content-Type' = 'application/x-amz-json-1.1'
    }
    return Invoke-RestMethod -Uri $CognitoIdentityUrl -Method Post -Headers $headers `
        -Body ($Body | ConvertTo-Json -Depth 10 -Compress)
}


# Cognito errors come back as HTTP 400 with a JSON body containing
# __type (e.g. 'UserNotFoundException') and message. Invoke-RestMethod
# throws a WebException; this helper unwraps the body cleanly.
function Get-CognitoErrorInfo {
    param($ErrorRecord)
    try {
        $resp = $ErrorRecord.Exception.Response
        if ($null -eq $resp) { return $null }

        # PowerShell 7+
        if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
            $json = $ErrorRecord.ErrorDetails.Message | ConvertFrom-Json
        }
        else {
            # PowerShell 5.1
            $stream = $resp.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($stream)
            $json = $reader.ReadToEnd() | ConvertFrom-Json
        }

        $codeRaw = if ($json.__type) { $json.__type } else { '' }
        # __type is sometimes prefixed like 'com.amazon.coral.service#UserNotFoundException'
        $code = $codeRaw -split '#' | Select-Object -Last 1

        return [pscustomobject]@{
            Code    = $code
            Message = $json.message
        }
    } catch {
        return $null
    }
}


function Get-ErrorMessage {
    # PS 5.1-compatible replacement for ($info.Message ?? $err.Exception.Message)
    param($Info, $ErrorRecord)
    if ($Info -and $Info.Message) { return $Info.Message }
    return $ErrorRecord.Exception.Message
}


function Test-UserExists {
    param([string]$Email)
    try {
        # ForgotPassword distinguishes UserNotFoundException from other errors
        # cleanly, without any side effect the user actually sees (email is
        # only sent if the account is confirmed & has a verified attribute).
        Invoke-CognitoIdp -Target 'AWSCognitoIdentityProviderService.ForgotPassword' -Body @{
            ClientId = $AppClientId
            Username = $Email
        } | Out-Null
        return $true
    } catch {
        $info = Get-CognitoErrorInfo $_
        if ($info -and $info.Code -eq 'UserNotFoundException') { return $false }
        # If the pool has PreventUserExistenceErrors on, unknown users get a
        # generic response — treat that as "maybe exists" and let SignUp be
        # the source of truth (it's idempotent about existing users).
        return $true
    }
}


function Invoke-SignUp {
    param([string]$Email)

    # SignUp requires a Password field even for passwordless pools. Generate
    # a strong random one the user will never see or use — sign-in always
    # routes through EMAIL_OTP.
    $throwaway = -join ((48..57) + (65..90) + (97..122) + (33,35,36,37,38,42) |
        Get-Random -Count 24 | ForEach-Object { [char]$_ })

    Write-Host ""
    Write-Host "Creating account for $Email..."
    try {
        Invoke-CognitoIdp -Target 'AWSCognitoIdentityProviderService.SignUp' -Body @{
            ClientId       = $AppClientId
            Username       = $Email
            Password       = $throwaway
            UserAttributes = @(@{ Name = 'email'; Value = $Email })
        } | Out-Null
    } catch {
        $info = Get-CognitoErrorInfo $_
        if ($info -and $info.Code -eq 'UsernameExistsException') {
            Write-Host 'Account already exists - proceeding to sign-in.'
            return
        }
        Write-Host ("Sign-up failed: {0}" -f (Get-ErrorMessage $info $_)) -ForegroundColor Red
        exit 1
    }

    Write-Host "A confirmation code has been sent to $Email."
    $code = Read-NonEmpty -Prompt 'Enter the confirmation code from your email'

    try {
        Invoke-CognitoIdp -Target 'AWSCognitoIdentityProviderService.ConfirmSignUp' -Body @{
            ClientId         = $AppClientId
            Username         = $Email
            ConfirmationCode = $code
        } | Out-Null
        Write-Host "Account confirmed."
        Write-Host ""
    } catch {
        $info = Get-CognitoErrorInfo $_
        Write-Host ("Could not confirm account: {0}" -f (Get-ErrorMessage $info $_)) -ForegroundColor Red
        exit 1
    }
}


function Invoke-SignIn {
    param([string]$Email)

    Write-Host "Sending sign-in code to $Email..."
    try {
        $start = Invoke-CognitoIdp -Target 'AWSCognitoIdentityProviderService.InitiateAuth' -Body @{
            ClientId       = $AppClientId
            AuthFlow       = 'USER_AUTH'
            AuthParameters = @{
                USERNAME            = $Email
                PREFERRED_CHALLENGE = 'EMAIL_OTP'
            }
        }
    } catch {
        $info = Get-CognitoErrorInfo $_
        Write-Host ("Could not start sign-in: {0}" -f (Get-ErrorMessage $info $_)) -ForegroundColor Red
        exit 1
    }

    if ($start.ChallengeName -ne 'EMAIL_OTP' -or -not $start.Session) {
        Write-Host 'Unexpected response from Cognito - no EMAIL_OTP challenge issued.' -ForegroundColor Red
        exit 1
    }

    $otp = Read-NonEmpty -Prompt 'Enter the 6-digit code from your email'

    try {
        $result = Invoke-CognitoIdp -Target 'AWSCognitoIdentityProviderService.RespondToAuthChallenge' -Body @{
            ClientId           = $AppClientId
            ChallengeName      = 'EMAIL_OTP'
            Session            = $start.Session
            ChallengeResponses = @{
                USERNAME       = $Email
                EMAIL_OTP_CODE = $otp
            }
        }
    } catch {
        $info = Get-CognitoErrorInfo $_
        Write-Host ("Code rejected: {0}" -f (Get-ErrorMessage $info $_)) -ForegroundColor Red
        exit 1
    }

    $idToken = $result.AuthenticationResult.IdToken
    if (-not $idToken) {
        Write-Host 'Sign-in succeeded but no ID token returned - check pool config.' -ForegroundColor Red
        exit 1
    }
    return $idToken
}


function Get-AwsCredentials {
    param([string]$IdToken)

    $provider = "cognito-idp.$Region.amazonaws.com/$UserPoolId"

    $idResp = Invoke-CognitoIdentity -Target 'AWSCognitoIdentityService.GetId' -Body @{
        IdentityPoolId = $IdentityPoolId
        Logins         = @{ $provider = $IdToken }
    }
    $identityId = $idResp.IdentityId

    $credsResp = Invoke-CognitoIdentity -Target 'AWSCognitoIdentityService.GetCredentialsForIdentity' -Body @{
        IdentityId = $identityId
        Logins     = @{ $provider = $IdToken }
    }
    return $credsResp.Credentials
}


function Set-AwsCliProfile {
    param(
        [Parameter(Mandatory)][string]$ProfileName,
        [Parameter(Mandatory)]$AwsSession
    )

    if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
        Write-Host 'AWS CLI is required when -CliProfile is supplied.' -ForegroundColor Red
        exit 1
    }

    & aws configure set aws_access_key_id $AwsSession.AccessKeyId --profile $ProfileName
    if ($LASTEXITCODE -ne 0) { Write-Host 'Could not configure the AWS CLI access key.' -ForegroundColor Red; exit 1 }
    & aws configure set aws_secret_access_key $AwsSession.SecretKey --profile $ProfileName
    if ($LASTEXITCODE -ne 0) { Write-Host 'Could not configure the AWS CLI secret key.' -ForegroundColor Red; exit 1 }
    & aws configure set aws_session_token $AwsSession.SessionToken --profile $ProfileName
    if ($LASTEXITCODE -ne 0) { Write-Host 'Could not configure the AWS CLI session token.' -ForegroundColor Red; exit 1 }
    & aws configure set region $Region --profile $ProfileName
    if ($LASTEXITCODE -ne 0) { Write-Host 'Could not configure the AWS CLI region.' -ForegroundColor Red; exit 1 }

    Write-Host "Temporary AWS CLI profile '$ProfileName' configured."
    if ($AwsSession.Expiration) {
        Write-Host "Credentials expire at $($AwsSession.Expiration)."
    }
}


function Get-ConsoleUrl {
    param($AwsSession)

    $sessionPayload = @{
        sessionId    = $AwsSession.AccessKeyId
        sessionKey   = $AwsSession.SecretKey
        sessionToken = $AwsSession.SessionToken
    } | ConvertTo-Json -Compress

    # getSigninToken uses GET with query params - use Invoke-RestMethod and
    # let it URL-encode the JSON payload for us via -Body on a GET.
    $tokenResp = Invoke-RestMethod -Uri $FederationUrl -Method Get -Body @{
        Action  = 'getSigninToken'
        Session = $sessionPayload
    }
    $signinToken = $tokenResp.SigninToken

    # Build the login URL - manually encode Issuer/Destination for safety.
    $issuerEnc = [uri]::EscapeDataString($IssuerUrl)
    $destEnc   = [uri]::EscapeDataString($ConsoleUrl)

    return "$FederationUrl`?Action=login&Issuer=$issuerEnc&Destination=$destEnc&SigninToken=$signinToken"
}


# --------------------------------- main ---------------------------------- #

Write-Host 'AWS Console self-service sign-in'
Write-Host ('-' * 32)

$email = (Read-NonEmpty -Prompt 'Email address').ToLower()

if (-not (Test-UserExists -Email $email)) {
    Invoke-SignUp -Email $email
}

$idToken = Invoke-SignIn -Email $email
$creds   = Get-AwsCredentials -IdToken $idToken

if ($CliProfile) {
    Set-AwsCliProfile -ProfileName $CliProfile -AwsSession $creds
}

$url     = Get-ConsoleUrl -AwsSession $creds

Write-Host ""
Write-Host 'Sign-in URL (valid for ~15 minutes):'
Write-Host ""
Write-Host $url
Write-Host ""

$openNow = (Read-Host -Prompt 'Open in your default browser now? [Y/n]').Trim().ToLower()
if ($openNow -eq '' -or $openNow -eq 'y' -or $openNow -eq 'yes') {
    Start-Process $url
}
