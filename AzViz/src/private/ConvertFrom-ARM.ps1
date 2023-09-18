function ConvertFrom-ARM {
    [CmdletBinding()]
    param (
        [string[]] $Targets,
        [string] $TargetType = 'Azure Resource Group',
        [int] $CategoryDepth = 1,
        [string] $Subscription,
        [string[]] $ExcludeTypes
    )
    
    begin {
        $rank = @{
            "Microsoft.Network/publicIPAddresses"     = 1
            "Microsoft.Network/loadBalancers"         = 2
            "Microsoft.Network/virtualNetworks"       = 3 
            "Microsoft.Network/networkSecurityGroups" = 4
            "Microsoft.Network/networkInterfaces"     = 5
            "Microsoft.Compute/virtualMachines"       = 6
        }

        $Excluded_ARMObjects = $(
            "Microsoft.Network/virtualNetworks*",
            "Microsoft.Network/virtualNetworks/subnets*",
            "Microsoft.Network/networkSecurityGroups*"
        ) 
        
        if($ExcludeTypes){
            $Excluded_ARMObjects += $ExcludeTypes
        }

        # $scriptblock = [scriptblock]::Create($Excluded_ARMObjects.ForEach({'$_.type -NotLike "{0}"' -f $_}) -join ' -and ')
        # $scriptblock = [scriptblock]::Create($Excluded_ARMObjects.ForEach({'$_.fromcateg -NotLike "{0}" -and $_.tocateg -NotLike "{0}"' -f $_}) -join ' -and ')
        $scriptblock = [scriptblock]::Create( $Excluded_ARMObjects.ForEach( { '$_.fromcateg -NotLike "{0}" -and $_.tocateg -NotLike "{0}"' -f $_ }) -join ' -and ' )
    }
    
    process {

        # $Targets | ForEach-Object -ThrottleLimit 10 -Parallel {
        #     Import-Module Az.Resources
        #     $TargetType = $using:TargetType
        #     $CategoryDepth = $using:CategoryDepth
        #     $Target = $_
        #     $Rank = $using:Rank
        #     $scriptblock = [scriptblock]::Create($using:condition)
        #set-AzContext -Subscription $Subscription
        #$SubscriptionID = Get-AzSubscription -SubscriptionName $Subscription | Select-Object -ExpandProperty Id
        
        Foreach($Target in $Targets){
            
            $temp_armtemplate = New-TemporaryFile
            $resources = @()
            # $temp_armtemplate = (Join-Path ([System.IO.Path]::GetTempPath()) "armtemplate.json")
                
            #region obtaining-arm-template
            switch ($TargetType) {
                'Azure Resource Group' { 
                    Write-CustomHost "Exporting ARM template of Azure resource group: `'$Target`'" -Indentation 1 -color Green
                    try {
                        $template = (Export-AzResourceGroup -ResourceGroupName $Target -SkipAllParameterization -Force -Path $temp_armtemplate -WarningAction SilentlyContinue -Verbose:$false).Path
                        $arm = Get-Content -Path $template | ConvertFrom-Json
                        $resources = $arm.Resources | Where-Object $scriptblock
                    } catch {
                        $queryResult = Search-AzGraph -Query "Resources | where resourceGroup == `'$Target`' and subscriptionId == `'$SubscriptionID`'"
                        # Extract the "id" property from the query result
                        $idList = $queryResult | ForEach-Object { $_.id }
                        $idList = $idList -split "`r`n"
                        # Define the batch size
                        $batchSize = 199
                        # Calculate the number of batches
                        $numBatches = [Math]::Ceiling($idList.Count / $batchSize)
                        # Loop through the batches
                        for ($i = 0; $i -lt $numBatches; $i++) {
                            # Get a slice of $idList for the current batch
                            $startIndex = $i * $batchSize
                            $endIndex = ($i + 1) * $batchSize - 1
                            $batch = $idList[$startIndex..$endIndex]
                        
                            # Filter out resource IDs that do not belong to the specified resource group
                            $filteredBatch = $batch | Where-Object { $_ -like "/subscriptions/$subscriptionid/resourceGroups/$Target/*" }
                        
                            # Check if there are any valid resource IDs in the batch
                            if ($filteredBatch.Count -gt 0) {
                                $templateVariableName = if ($i -eq 0) { "template" } else { "template$i" }
                                $templatePath = (Export-AzResourceGroup -ResourceGroupName $Target -Resource $filteredBatch -SkipAllParameterization -Force -Path $temp_armtemplate -WarningAction SilentlyContinue -Verbose:$false).Path
                        
                                # Assign the template path to the variable with a dynamic name
                                Set-Variable -Name $templateVariableName -Value $templatePath
                                $arm = Get-Content -Path $templatePath | ConvertFrom-Json
                                $resources += $arm.Resources | Where-Object $scriptblock
                                Write-CustomHost "Total resources found: $($resources.count)"  -Indentation 2 -color Green
                            }
                        }
                    }

                }
                'File' { 
                    Write-CustomHost "Accessing ARM template from local file: `'$Target`'" -Indentation 2 -color Green
                    $template = $Target
                    $arm = Get-Content -Path $template | ConvertFrom-Json
                    $resources = $arm.Resources | Where-Object $scriptblock
                }
                'Url' {
                    Write-CustomHost "Downloading ARM template from URL: `'$Target`'" -Indentation 2 -color Green
                    # $Target = 'https://raw.githubusercontent.com/Azure/azure-quickstart-templates/master/101-vm-simple-linux/azuredeploy.json'
                    $template = $temp_armtemplate
                    Invoke-WebRequest -Uri  $Target -OutFile $template  -Verbose:$false
                    $arm = Get-Content -Path $template | ConvertFrom-Json
                    $resources = $arm.Resources | Where-Object $scriptblock
                    # todo test-path the downloaded file
                }
            }

            Write-CustomHost "Processing the ARM template to extract resources" -Indentation 2 -color Green

            

            if ($resources) {
                Write-CustomHost "Total resources found: $($resources.count)"  -Indentation 2 -color Green
                Write-CustomHost "Cleaning up temporary ARM template file at: $template"  -Indentation 2 -color Green
                Remove-Item $template -Force
            }
            else {
                Write-CustomHost "Total resources/sub-resources found: $($resources.count)"  -Indentation 2 -color Green
                Write-CustomHost "Skipping ${TargetType}: `"$Target`" as no resources were found."  -Indentation 2 -color Green
                continue        
            }
            #endregion obtaining-arm-template

            #region parsing-arm-template-and-finding-resource-dependencies
            $data = @()
            # $excluded_types = @("scheduledqueryrules","containers","solutions","modules","savedSearches")            
            $data += $resources |
            Where-Object { $_.type.tostring().split("/").count -le $($CategoryDepth + 1) } |
            ForEach-Object {
                $dependson = $null
                if ($_.dependson) {
                    $dependson = $_.DependsOn #| ForEach-Object { $_.ToString().split("parameters('")[1].split("')")[0]}
                    foreach ($dependency in $dependson) {                            
                        $r = $rank["$($_.type.ToString())"]
                        [PSCustomObject]@{
                            fromcateg   = $_.type.ToString() #.split('/')[-1]
                            from        = $_.name.ToString() #.split('/')[-1] #.split("parameters('")[1].split("')")[0]
                            to          = $dependency.tostring().replace("[resourceId(", "").replace(")]", "").Split(",")[1].replace("'", "").trim() # -join '/' #.split('/')[-1]
                            tocateg     = $dependency.tostring().replace("[resourceId(", "").replace(")]", "").Split(",")[0].replace("'", "").trim().Split("/")[0..1] -join '/' #.split('/')[-1]
                            isdependent = $true
                            rank        = if ($r) { $r }else { 9999 }
                        }
                    }
                }
                else {
                    $r = $rank["$($_.type.ToString())"]
                    [PSCustomObject]@{
                        fromcateg   = $_.type.ToString() #.split('/')[-1]
                        from        = $_.name.ToString() #.split("parameters('")[1].split("')")[0]
                        to          = ''
                        tocateg     = ''
                        isdependent = $false
                        rank        = if ($r) { $r }else { 9999 }
                    }
                }
            } | 
            Sort-Object Rank
            #endregion parsing-arm-template-and-finding-resource-associations

            [PSCustomObject]@{
                Type      = $TargetType
                Name      = $Target
                Resources = $data | Where-Object $scriptblock
            }

        }

    }
    
    end {
        
    }
}