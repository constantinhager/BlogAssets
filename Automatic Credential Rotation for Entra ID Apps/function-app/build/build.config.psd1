@{
	General = @{
		# Is this Function App deployed to a Flex COnsumption plan?
		# If so, Managed Dependencies cannot be used and must be* disabled!
		# *The build script will handle that for you, if setting this to $true
		FlexConsumption = $true
	}

    TimerTrigger     = @{
        # Default Schedule for timed executions (NCRONTAB, UTC)
        Schedule          = '0 0 5 * * *'

        # Different Schedules for specific timed endpoints
        ScheduleOverrides = @{
            # Every day at 05:00 UTC
            'Invoke-AppCredentialCheck'        = '0 0 5 * * *'
            # Every 15 minutes: renew the rows an admin set to Renewable
            'Invoke-AppCredentialRenewalQueue' = '0 */15 * * * *'
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
            # Read-only report
            'Get-AppCredentialReport' = @('get')
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
}
