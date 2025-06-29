using namespace System.Net

function Invoke-ExecOnboardTenant {
    <#
    .FUNCTIONALITY
        Entrypoint
    .ROLE
        Tenant.Administration.ReadWrite
    #>
    param($Request, $TriggerMetadata)

    $APIName = $Request.Params.CIPPEndpoint
    $Headers = $Request.Headers
    Write-LogMessage -headers $Headers -API $APIName -message 'Accessed this API' -Sev 'Debug'

    # Interact with query parameters or the body of the request.
    $Id = $Request.Body.id
    if ($Id) {
        try {
            $OnboardTable = Get-CIPPTable -TableName 'TenantOnboarding'

            if ($Request.Body.Cancel -eq $true) {
                $TenantOnboarding = Get-CIPPAzDataTableEntity @OnboardTable -Filter "RowKey eq '$Id'"
                if ($TenantOnboarding) {
                    Remove-AzDataTableEntity -Force @OnboardTable -Entity $TenantOnboarding
                    $Results = @{'Results' = 'Onboarding job canceled' }
                    $StatusCode = [HttpStatusCode]::OK
                } else {
                    $Results = 'Onboarding job not found'
                    $StatusCode = [HttpStatusCode]::NotFound
                }
            } else {
                $TenMinutesAgo = (Get-Date).AddMinutes(-10).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
                $TenantOnboarding = Get-CIPPAzDataTableEntity @OnboardTable -Filter "RowKey eq '$Id' and Timestamp ge datetime'$TenMinutesAgo'"
                if (!$TenantOnboarding -or [bool]$Request.Body.Retry) {
                    $OnboardingSteps = [PSCustomObject]@{
                        'Step1' = @{
                            'Status'  = 'pending'
                            'Title'   = 'Step 1: GDAP Invite'
                            'Message' = 'Waiting for onboarding job to start'
                        }
                        'Step2' = @{
                            'Status'  = 'pending'
                            'Title'   = 'Step 2: GDAP Role Test'
                            'Message' = 'Waiting for Step 1'
                        }
                        'Step3' = @{
                            'Status'  = 'pending'
                            'Title'   = 'Step 3: GDAP Group Mapping'
                            'Message' = 'Waiting for Step 2'
                        }
                        'Step4' = @{
                            'Status'  = 'pending'
                            'Title'   = 'Step 4: CPV Refresh'
                            'Message' = 'Waiting for Step 3'
                        }
                        'Step5' = @{
                            'Status'  = 'pending'
                            'Title'   = 'Step 5: Graph API Test'
                            'Message' = 'Waiting for Step 4'
                        }
                    }
                    $TenantOnboarding = [PSCustomObject]@{
                        PartitionKey    = 'Onboarding'
                        RowKey          = [string]$Id
                        CustomerId      = ''
                        Status          = 'queued'
                        OnboardingSteps = [string](ConvertTo-Json -InputObject $OnboardingSteps -Compress)
                        Relationship    = ''
                        Logs            = ''
                        Exception       = ''
                    }
                    Add-CIPPAzDataTableEntity @OnboardTable -Entity $TenantOnboarding -Force -ErrorAction Stop

                    $Item = [pscustomobject]@{
                        FunctionName               = 'ExecOnboardTenantQueue'
                        id                         = $Id
                        Roles                      = $Request.Body.gdapRoles
                        AddMissingGroups           = $Request.Body.addMissingGroups
                        IgnoreMissingRoles         = $Request.Body.ignoreMissingRoles
                        AutoMapRoles               = $Request.Body.autoMapRoles
                        StandardsExcludeAllTenants = $Request.Body.standardsExcludeAllTenants
                    }

                    $InputObject = @{
                        OrchestratorName = 'OnboardingOrchestrator'
                        Batch            = @($Item)
                    }
                    $InstanceId = Start-NewOrchestration -FunctionName 'CIPPOrchestrator' -InputObject ($InputObject | ConvertTo-Json -Depth 5 -Compress)
                    Write-LogMessage -headers $Headers -API $APIName -message "Onboarding job $Id started" -Sev 'Info' -LogData @{ 'InstanceId' = $InstanceId }
                }

                $Steps = $TenantOnboarding.OnboardingSteps | ConvertFrom-Json
                $OnboardingSteps = foreach ($Step in $Steps.PSObject.Properties.Name) { $Steps.$Step }
                $Relationship = try { $TenantOnboarding.Relationship | ConvertFrom-Json -ErrorAction Stop } catch { @{} }
                $Logs = try { $TenantOnboarding.Logs | ConvertFrom-Json -ErrorAction Stop } catch { @{} }
                $TenantOnboarding.OnboardingSteps = $OnboardingSteps
                $TenantOnboarding.Relationship = $Relationship
                $TenantOnboarding.Logs = $Logs
                $Results = $TenantOnboarding
                $StatusCode = [HttpStatusCode]::OK
            }
        } catch {
            $ErrorMsg = Get-NormalizedError -message $($_.Exception.Message)
            $Results = "Function Error: $($_.InvocationInfo.ScriptLineNumber) - $ErrorMsg"
            $StatusCode = [HttpStatusCode]::BadRequest
        }
    } else {
        $StatusCode = [HttpStatusCode]::NotFound
        $Results = 'Relationship not found'
    }
    # Associate values to output bindings by calling 'Push-OutputBinding'.
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = $StatusCode
            Body       = $Results
        })

}
