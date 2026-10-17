#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
	Smoke tests for the DevOps dev container image. They run INSIDE the image:

	docker run --rm --user vscode -v "$PWD/image:/image:ro" <image> pwsh -NoProfile -File /image/tests/Invoke-ImageTest.ps1

	The expected tool versions are read from the *_VERSION ARGs of the Dockerfile,
	so the Dockerfile stays the only place where a version is written down.
#>

BeforeDiscovery {
	$dockerfile = Join-Path $PSScriptRoot '..' 'Dockerfile'
	$expected = @{}
	foreach ($line in Select-String -Path $dockerfile -Pattern '^ARG (\w+)_VERSION=(\S+)$') {
		$expected[$line.Matches[0].Groups[1].Value] = $line.Matches[0].Groups[2].Value
	}

	$tools = @(
		@{ Name = 'PowerShell'; Expected = $expected.POWERSHELL; Command = { $PSVersionTable.PSVersion.ToString() } }
		@{ Name = 'Terraform'; Expected = $expected.TERRAFORM; Command = { (terraform version -json | ConvertFrom-Json).terraform_version } }
		@{ Name = 'TFLint'; Expected = $expected.TFLINT; Command = { tflint --version } }
		@{ Name = 'Azure CLI'; Expected = $expected.AZURE_CLI; Command = { (az version --output json | ConvertFrom-Json).'azure-cli' } }
		@{ Name = 'Ansible'; Expected = $expected.ANSIBLE; Command = { ansible-community --version } }
		@{ Name = 'ansible-lint'; Expected = $expected.ANSIBLE_LINT; Command = { ansible-lint --version } }
		@{ Name = 'kubectl'; Expected = $expected.KUBECTL; Command = { (kubectl version --client --output json | ConvertFrom-Json).clientVersion.gitVersion } }
		@{ Name = 'Helm'; Expected = $expected.HELM; Command = { helm version --short } }
		@{ Name = 'GitHub CLI'; Expected = $expected.GH; Command = { gh --version } }
	)

	# Must match image/scripts/install-modules.ps1
	$modules = @(
		@{ Name = 'Pester'; Version = '5.7.1' }
		@{ Name = 'PSScriptAnalyzer'; Version = '1.24.0' }
		@{ Name = 'PSFramework'; Version = $null }
		@{ Name = 'powershell-yaml'; Version = $null }
		@{ Name = 'Az.Accounts'; Version = $null }
		@{ Name = 'Az.Resources'; Version = $null }
		@{ Name = 'Az.ContainerRegistry'; Version = $null }
		@{ Name = 'Microsoft.Graph.Authentication'; Version = $null }
	)
	$pinnedModules = @($modules | Where-Object { $_.Version })
}

Describe 'Tools' {
	It '<Name> has a version ARG in the Dockerfile' -ForEach $tools {
		$Expected | Should -Not -BeNullOrEmpty -Because "the Dockerfile needs an ARG for $Name"
	}

	It '<Name> is installed in version <Expected>' -ForEach $tools {
		$output = & $Command 2>&1 | Out-String
		$output | Should -Match ([regex]::Escape($Expected))
	}
}

Describe 'PowerShell modules' {
	It '<Name> is available' -ForEach $modules {
		$module = Get-Module -ListAvailable -Name $Name | Sort-Object Version -Descending | Select-Object -First 1
		$module | Should -Not -BeNullOrEmpty
		Write-Host "      $Name $($module.Version)"
	}

	It '<Name> is pinned to <Version>' -ForEach $pinnedModules {
		$versions = Get-Module -ListAvailable -Name $Name | ForEach-Object { $_.Version.ToString() }
		$versions | Should -Contain $Version
	}
}

Describe 'Container user' {
	It 'runs as vscode' {
		id -un | Should -Be 'vscode'
	}

	It 'can write to the Terraform plugin cache' {
		$env:TF_PLUGIN_CACHE_DIR | Should -Be '/home/vscode/.terraform.d/plugin-cache'
		$probe = Join-Path $env:TF_PLUGIN_CACHE_DIR 'write-test'
		{ Set-Content -Path $probe -Value 'ok'; Remove-Item -Path $probe } | Should -Not -Throw
	}
}
