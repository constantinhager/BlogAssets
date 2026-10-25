function Send-SrMail {
	<#
	.SYNOPSIS
		Sends a mail with Microsoft Graph as the rotation app, in the home tenant.

	.DESCRIPTION
		Sends a mail from SR_MAIL_SENDER to SR_MAIL_RECIPIENTS with POST /users/{sender}/sendMail.
		Like every Graph call, it uses the token of the rotation app (exchanged from the managed identity).

		The rotation app does NOT get the Graph permission Mail.Send in Entra ID - that would allow it
		to send as every mailbox in every consenting tenant. Instead, Exchange Online RBAC for Applications
		grants the role 'Application Mail.Send' to the app's service principal in the home tenant, scoped
		to the one sender mailbox (see scripts/Set-SecretRotationMailScope.ps1).

	.PARAMETER Subject
		The subject.

	.PARAMETER Html
		The HTML body.

	.PARAMETER Config
		The configuration (Get-SrConfig).

	.EXAMPLE
		PS C:\> Send-SrMail -Subject 'Test' -Html '<p>Hello</p>' -Config (Get-SrConfig)

		Sends a test mail.
	#>
	[CmdletBinding()]
	param (
		[Parameter(Mandatory = $true)]
		[string]
		$Subject,

		[Parameter(Mandatory = $true)]
		[string]
		$Html,

		[Parameter(Mandatory = $true)]
		$Config
	)

	$recipients = foreach ($address in $Config.MailRecipients) {
		@{ emailAddress = @{ address = $address } }
	}
	$body = @{
		message         = @{
			subject      = $Subject
			body         = @{ contentType = 'HTML'; content = $Html }
			toRecipients = @($recipients)
		}
		saveToSentItems = $false
	}
	$uri = 'https://graph.microsoft.com/v1.0/users/{0}/sendMail' -f [uri]::EscapeDataString($Config.MailSender)
	$null = Invoke-SrRestRequest -Method POST -Uri $uri -Body $body
}
