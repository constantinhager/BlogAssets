@{
	General = @{
		# Is this Function App deployed to a Flex COnsumption plan?
		# If so, Managed Dependencies cannot be used and must be* disabled!
		# *The build script will handle that for you, if setting this to $true
		FlexConsumption = $true
	}

    TimerTrigger     = @{
        # Default Schedule for timed executions
        Schedule          = '0 5 * * * *'

        # Different Schedules for specific timed endpoints
        ScheduleOverrides = @{
            # 'Update-Whatever' = '0 5 12 * * *'
        }
    }

    HttpTrigger      = @{
        <#
		AuthLevels:
		https://learn.microsoft.com/en-us/azure/azure-functions/functions-bindings-http-webhook-trigger?tabs=python-v2%2Cisolated-process%2Cnodejs-v4%2Cfunctionsv2&pivots=programming-language-csharp#http-auth

		anonymous: No Token needed (combine with Identity Provider for Entra ID auth without also needing a token)
		function: (default) Require a function-endpoint-specific token with the request
		admin: Require a Function-App-global admin token (master key) for the request
		#>
        AuthLevel          = 'function'
        AuthLevelOverrides = @{
            # 'Set-Foo' = 'anonymous'
        }
        Methods            = @('get', 'post')
        MethodOverrides    = @{
            # 'Set-Foo' = 'delete'
        }
    }

    EventGridTrigger = @{
        <#
		AuthLevels:
		https://learn.microsoft.com/en-us/azure/azure-functions/functions-bindings-http-webhook-trigger?tabs=python-v2%2Cisolated-process%2Cnodejs-v4%2Cfunctionsv2&pivots=programming-language-csharp#http-auth

		anonymous: No Token needed (combine with Identity Provider for Entra ID auth without also needing a token)
		function: (default) Require a function-endpoint-specific token with the request
		admin: Require a Function-App-global admin token (master key) for the request
		#>
        AuthLevel          = 'function'
        AuthLevelOverrides = @{
            # 'Set-Foo' = 'anonymous'
        }
        Methods            = @('get', 'post')
        MethodOverrides    = @{
            # 'Set-Foo' = 'delete'
        }
    }

    BlobTrigger      = @{
        <#
		Functions under <name>/functions/blobTrigger become blob-triggered endpoints.
		The command may declare -InputBlob ([byte[]]), -BlobName ([string]) and/or -TriggerMetadata.
		Its output is pushed to the SQL output binding, if one is configured.
		#>

        # Container/path pattern. {name} = blob name
        Path                = 'incoming/{name}'
        PathOverrides       = @{
            # 'Import-Foo' = 'foo/{name}'
        }

        # Prefix of the connection settings (identity-based: DataStorage__blobServiceUri + DataStorage__queueServiceUri)
        Connection          = 'DataStorage'
        ConnectionOverrides = @{ }

        # EventGrid: required on Flex Consumption. LogsAndContainerScan: classic polling trigger (not on Flex)
        Source              = 'EventGrid'

        # Azure SQL output binding. Set CommandText to '' to disable.
        SqlOutput           = @{
            Name                    = 'SqlOutput'
            CommandText             = 'dbo.ImportedRecord'
            ConnectionStringSetting = 'SqlConnectionString'
        }
        SqlOutputOverrides  = @{
            # 'Import-Foo' = @{ Name = 'SqlOutput'; CommandText = 'dbo.Foo'; ConnectionStringSetting = 'SqlConnectionString' }
        }
    }
}
